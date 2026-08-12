import ActivityKit
import AVFoundation
import Foundation

/// Flash-opens from the keyboard, starts the microphone, then returns to the host app.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    @Published var isArmed = false
    @Published var statusText = "Listening…"
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var isBusy = false
    @Published var transcript = ""

    private let recorder = MicRecorder()
    private var requestID = ""
    private var hostBundleID = ""
    private var keyboardStack = false
    private var activity: Activity<DictationAttributes>?
    private var observer: UnsafeRawPointer?
    private var transcribeTask: Task<Void, Never>?
    private var leaseExpiryTask: Task<Void, Never>?
    private var leaseHeartbeatTask: Task<Void, Never>?
    private var meteringTask: Task<Void, Never>?
    private var keepaliveEligible = false

    private init() {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        observer = UnsafeRawPointer(pointer)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        recorder.onSessionUnavailable = {
            Task { @MainActor in DictationController.shared.sessionBecameUnavailable() }
        }
        CFNotificationCenterAddObserver(
            center,
            pointer,
            { _, _, _, _, _ in
                Task { @MainActor in
                    _ = DictationBridge.take()
                    HandoffDiagnostics.record("app.command.toggle.received")
                    DictationController.shared.toggleMic()
                }
            },
            DictationBridge.toggleName,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            pointer,
            { _, _, _, _, _ in
                Task { @MainActor in
                    _ = DictationBridge.take()
                    HandoffDiagnostics.record("app.command.cancel.received")
                    DictationController.shared.discard()
                }
            },
            DictationBridge.cancelName,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            pointer,
            { _, _, _, _, _ in
                Task { @MainActor in
                    _ = DictationBridge.take()
                    HandoffDiagnostics.record("app.command.stop.received")
                    DictationController.shared.send()
                }
            },
            DictationBridge.stopName,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            pointer,
            { _, _, _, _, _ in
                Task { @MainActor in
                    _ = DictationBridge.take()
                    HandoffDiagnostics.record("app.command.start.received")
                    DictationController.shared.startLeasedTake()
                }
            },
            DictationBridge.startName,
            nil,
            .deliverImmediately
        )
    }

    func becomeActive() {
        restoreIfNeeded()
        let command = DictationBridge.take()
        if command == .start {
            startLeasedTake()
            return
        }
        if command == .cancel {
            discard()
            return
        }
        guard isArmed, !isBusy else {
            return
        }
        switch command {
        case .stop:
            send()
        case .toggle:
            toggleMic()
        case .start, .cancel:
            break
        case nil:
            break
        }
    }

    func restoreIfNeeded() {
        if !requestID.isEmpty {
            isArmed = true
            return
        }
        let payload = DictationHandoff.read()
        let existing = Activity<DictationAttributes>.activities.first
        if let lease = DictationHandoff.readLease() {
            activity = existing
            scheduleLeaseExpiration(lease)
            HandoffDiagnostics.record("app.lease.restored", detail: lease.sessionID)
            return
        }
        if let payload, payload.status == .pending {
            let age = DictationHandoff.pendingAge() ?? .infinity
            HandoffDiagnostics.record("app.pending.observed", detail: "\(payload.id) age=\(age)")
            if age > 12 {
                DictationHandoff.write(.init(
                    id: payload.id,
                    status: .failed,
                    text: "",
                    error: "The recording request expired. Tap the keyboard mic to try again.",
                    hostBundleID: payload.hostBundleID
                ))
                HandoffDiagnostics.record("app.pending.expired", detail: payload.id)
            }
            return
        }
        if let payload, isLive(payload.status), recorder.isRecording || recorder.canResume {
            requestID = payload.id
            hostBundleID = payload.hostBundleID
            activity = existing
            isArmed = true
            isRecording = recorder.isRecording
            isPaused = payload.status == .paused
            statusText = payload.status == .paused ? "Paused" : "Listening…"
            return
        }
        if let payload, isLive(payload.status) {
            DictationHandoff.write(.init(
                id: payload.id,
                status: .failed,
                text: "",
                error: "The previous recording ended unexpectedly. Tap the keyboard mic to try again.",
                hostBundleID: payload.hostBundleID
            ))
            HandoffDiagnostics.record("app.orphanedSession.failed", detail: payload.id)
            return
        }
        if let existing {
            HandoffDiagnostics.record("app.orphanedActivity.ended", detail: "\(existing.id)")
            endLiveActivity()
        }
    }

    func arm(id: String, hostBundleID: String, keyboardStack: Bool) {
        guard let payload = DictationHandoff.read(), payload.id == id,
              payload.status == .pending, (DictationHandoff.pendingAge() ?? .infinity) <= 12 else {
            HandoffDiagnostics.record("app.deeplink.rejected", detail: id)
            return
        }
        if recorder.isRecording || recorder.canResume {
            isArmed = true
            HostReturn.bounceBack(keyboardStack: keyboardStack, hostBundleID: hostBundleID)
            return
        }
        leaseExpiryTask?.cancel()
        leaseHeartbeatTask?.cancel()
        DictationHandoff.clearLease()
        let host = [hostBundleID, AppGroupStore.lastHostBundleID].first { !$0.isEmpty }
            ?? ""
        requestID = id
        self.hostBundleID = host
        self.keyboardStack = keyboardStack
        AppGroupStore.lastHostBundleID = host
        isArmed = true
        isBusy = false
        isPaused = false
        transcript = ""
        statusText = "Listening…"
        write(.pending, text: "", error: "")
        beginRecording(bounce: true, retryByForeground: false)
    }

    func toggleMic() {
        restoreIfNeeded()
        guard !isBusy else { return }
        if recorder.isRecording {
            recorder.pause()
            isRecording = false
            isPaused = true
            statusText = "Paused"
            write(.paused, text: "", error: "")
            updateLiveActivity(recording: false, label: "Paused")
            return
        }
        if recorder.canResume {
            do {
                try recorder.resume()
                isRecording = true
                isPaused = false
                statusText = "Listening…"
                write(.recording, text: "", error: "")
                updateLiveActivity(recording: true, label: "Listening")
            } catch {
                statusText = error.localizedDescription
            }
            return
        }
        startFreshTake()
    }

    func send() {
        restoreIfNeeded()
        HandoffDiagnostics.record("app.stop.requested", detail: requestID)
        guard !isBusy else { return }
        guard recorder.isRecording || recorder.canResume else {
            statusText = "Nothing to send"
            return
        }
        transcribeTask?.cancel()
        let url: URL
        do {
            url = try recorder.stopKeepingInputActive()
        } catch {
            HandoffDiagnostics.record("app.audio.stopFailed", detail: error.localizedDescription)
            statusText = error.localizedDescription
            isRecording = false
            write(.failed, text: "", error: error.localizedDescription)
            isArmed = false
            clearLease()
            endLiveActivity()
            requestID = ""
            return
        }
        let audioBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        HandoffDiagnostics.record("app.audio.stopped", detail: "\(requestID) bytes=\(audioBytes)")
        HandoffDiagnostics.record(
            "app.audio.idle",
            detail: "\(requestID) segment=closed buffers=discarded inputGraph=active"
        )
        stopMetering()
        isRecording = false
        isPaused = false
        isBusy = true
        statusText = "Transcribing…"
        write(.transcribing, text: "", error: "")
        updateLiveActivity(recording: false, label: "Transcribing")
        let key = AppGroupStore.apiKey
        let language = AppGroupStore.languageCode
        let id = requestID
        HandoffDiagnostics.record("app.transcription.started", detail: id)
        transcribeTask = Task {
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let text = try await ElevenLabsBatch.transcribe(
                    audioURL: url,
                    apiKey: key,
                    language: language
                )
                await MainActor.run {
                    guard self.requestID == id else { return }
                    self.transcript = text
                    self.isBusy = false
                    self.statusText = "Inserted — check Messages"
                    self.write(.done, text: text, error: "")
                    HandoffDiagnostics.record(
                        "app.transcription.succeeded",
                        detail: "\(id) characters=\(text.count)"
                    )
                    if self.keepaliveEligible {
                        self.publishLease(completedRequestID: id)
                    } else {
                        HandoffDiagnostics.record("app.lease.skipped", detail: "\(id) audioSessionUnavailable")
                        self.endLiveActivity()
                    }
                    self.isArmed = false
                    self.requestID = ""
                }
            } catch {
                await MainActor.run {
                    guard self.requestID == id else { return }
                    self.isBusy = false
                    self.isArmed = false
                    self.statusText = error.localizedDescription
                    self.write(.failed, text: "", error: error.localizedDescription)
                    HandoffDiagnostics.record("app.transcription.failed", detail: "\(id) \(error.localizedDescription)")
                    self.clearLease()
                    self.endLiveActivity()
                    self.requestID = ""
                }
            }
        }
    }

    func discard() {
        stopMetering()
        recorder.cancel()
        if !requestID.isEmpty {
            write(.cancelled, text: "", error: "")
        }
        transcribeTask?.cancel()
        transcribeTask = nil
        requestID = ""
        isArmed = false
        isRecording = false
        isPaused = false
        isBusy = false
        transcript = ""
        clearLease()
        endLiveActivity()
    }

    private func startFreshTake() {
        clearLease()
        let id = UUID().uuidString
        requestID = id
        isArmed = true
        isBusy = false
        isPaused = false
        transcript = ""
        write(.pending, text: "", error: "")
        beginRecording(bounce: false, retryByForeground: false)
    }

    private func startLeasedTake() {
        guard let lease = DictationHandoff.readLease(),
              let payload = DictationHandoff.read(),
              payload.status == .pending,
              (DictationHandoff.pendingAge() ?? .infinity) <= 12,
              !isBusy, !recorder.isRecording, !recorder.canResume else {
            HandoffDiagnostics.record("app.lease.startRejected")
            return
        }
        leaseExpiryTask?.cancel()
        leaseExpiryTask = nil
        leaseHeartbeatTask?.cancel()
        leaseHeartbeatTask = nil
        DictationHandoff.clearLease()
        requestID = payload.id
        hostBundleID = payload.hostBundleID.isEmpty ? lease.hostBundleID : payload.hostBundleID
        keyboardStack = true
        isArmed = true
        isBusy = false
        isPaused = false
        transcript = ""
        statusText = "Listening…"
        HandoffDiagnostics.record("app.lease.startAccepted", detail: payload.id)
        beginRecording(bounce: false, retryByForeground: true)
    }

    private func beginRecording(bounce: Bool, retryByForeground: Bool) {
        HandoffDiagnostics.record("app.recording.starting", detail: requestID)
        do {
            try recorder.start()
        } catch {
            HandoffDiagnostics.record("app.recording.failed", detail: error.localizedDescription)
            statusText = error.localizedDescription
            isRecording = false
            if retryByForeground {
                HandoffDiagnostics.record("app.lease.startNeedsForeground", detail: requestID)
                isArmed = false
                clearLease()
                requestID = ""
                return
            }
            write(.failed, text: "", error: error.localizedDescription)
            isArmed = false
            clearLease()
            endLiveActivity()
            requestID = ""
            return
        }
        isRecording = true
        keepaliveEligible = true
        startMetering()
        HandoffDiagnostics.record("app.recording.started", detail: requestID)
        isPaused = false
        statusText = "Listening…"
        if activity == nil {
            startLiveActivity(recording: true, label: "Listening")
        } else {
            updateLiveActivity(recording: true, label: "Listening")
        }
        write(.recording, text: "", error: "")
        if bounce {
            HostReturn.bounceBack(keyboardStack: keyboardStack, hostBundleID: hostBundleID)
        }
    }

    private func publishLease(completedRequestID: String) {
        let lease = DictationHandoff.Lease(
            sessionID: completedRequestID,
            hostBundleID: hostBundleID,
            expiresAt: .now.addingTimeInterval(DictationHandoff.leaseDuration),
            heartbeatAt: .now
        )
        DictationHandoff.writeLease(lease)
        HandoffDiagnostics.record(
            "app.lease.ready",
            detail: "\(lease.sessionID) expires=\(lease.expiresAt.timeIntervalSince1970) segment=idle inputGraph=active privacyIndicator=on"
        )
        updateLiveActivity(recording: false, label: "Ready")
        scheduleLeaseExpiration(lease)
    }

    private func scheduleLeaseExpiration(_ lease: DictationHandoff.Lease) {
        leaseExpiryTask?.cancel()
        leaseHeartbeatTask?.cancel()
        leaseHeartbeatTask = Task {
            var refreshed = lease
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, refreshed.expiresAt > .now else { return }
                refreshed.heartbeatAt = .now
                DictationHandoff.writeLease(refreshed)
            }
        }
        leaseExpiryTask = Task { [weak self] in
            let delay = max(0, lease.expiresAt.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  DictationHandoff.readLease()?.sessionID == lease.sessionID else { return }
            DictationHandoff.clearLease()
            self?.recorder.deactivateSession()
            AppGroupStore.microphoneLevel = 0
            self?.endLiveActivity()
            HandoffDiagnostics.record("app.lease.expired", detail: lease.sessionID)
        }
    }

    private func clearLease() {
        leaseExpiryTask?.cancel()
        leaseExpiryTask = nil
        leaseHeartbeatTask?.cancel()
        leaseHeartbeatTask = nil
        DictationHandoff.clearLease()
        recorder.deactivateSession()
        keepaliveEligible = false
        AppGroupStore.microphoneLevel = 0
    }

    private func startMetering() {
        meteringTask?.cancel()
        meteringTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                AppGroupStore.microphoneLevel = self.recorder.meterLevel()
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func stopMetering() {
        meteringTask?.cancel()
        meteringTask = nil
        AppGroupStore.microphoneLevel = 0
    }

    private func sessionBecameUnavailable() {
        HandoffDiagnostics.record("app.audio.sessionUnavailable", detail: requestID)
        stopMetering()
        keepaliveEligible = false
        if isBusy, transcribeTask != nil, !requestID.isEmpty {
            leaseExpiryTask?.cancel()
            leaseExpiryTask = nil
            leaseHeartbeatTask?.cancel()
            leaseHeartbeatTask = nil
            DictationHandoff.clearLease()
            AppGroupStore.microphoneLevel = 0
            HandoffDiagnostics.record("app.transcription.audioSessionLost", detail: requestID)
            return
        }
        if !requestID.isEmpty {
            write(.failed, text: "", error: "Microphone session ended. Try again.")
        }
        requestID = ""
        isArmed = false
        isRecording = false
        isPaused = false
        clearLease()
        endLiveActivity()
    }

    private func isLive(_ status: DictationHandoff.Payload.Status) -> Bool {
        switch status {
        case .pending, .recording, .paused, .transcribing: return true
        case .done, .failed, .cancelled: return false
        }
    }

    private func write(_ status: DictationHandoff.Payload.Status, text: String, error: String) {
        guard !requestID.isEmpty else { return }
        DictationHandoff.write(.init(
            id: requestID,
            status: status,
            text: text,
            error: error,
            hostBundleID: hostBundleID
        ))
    }

    private func startLiveActivity(recording: Bool, label: String) {
        endLiveActivity()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = DictationAttributes(requestID: requestID)
        let state = DictationAttributes.ContentState(
            isRecording: recording,
            startedAt: Date(),
            label: label
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil)
            )
        } catch {
            return
        }
    }

    private func updateLiveActivity(recording: Bool, label: String) {
        guard let activity else { return }
        let state = DictationAttributes.ContentState(
            isRecording: recording,
            startedAt: activity.content.state.startedAt,
            label: label
        )
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    private func endLiveActivity() {
        let current = activity
        activity = nil
        Task {
            if let current {
                await current.end(nil, dismissalPolicy: .immediate)
            }
            for leftover in Activity<DictationAttributes>.activities {
                await leftover.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
