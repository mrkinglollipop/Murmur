import ActivityKit
import AVFoundation
import Foundation
import UIKit

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
    /// Keyboard-initiated take: input graph armed, waiting for swipe-back / hostReady.
    @Published var isAwaitingHostReturn = false

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
    private var listenGateTimeoutTask: Task<Void, Never>?
    private var keepaliveEligible = false
    private var listenGated = false
    private var hostBounceAttempts = 0
    private var pendingHostReady = false
    private var murmurForeground = true
    private var hostPID = 0
    private var learnTask: Task<Void, Never>?
    private var fromActionButton = false

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
        CFNotificationCenterAddObserver(
            center,
            pointer,
            { _, _, _, _, _ in
                Task { @MainActor in
                    _ = DictationBridge.take()
                    HandoffDiagnostics.record("app.command.hostReady.received")
                    DictationController.shared.hostKeyboardReady()
                }
            },
            DictationBridge.hostReadyName,
            nil,
            .deliverImmediately
        )
    }

    /// Home toggle. Does not start a take. Turning off ends the island session.
    func setSessionEnabled(_ on: Bool) {
        if !on {
            discard()
            return
        }
        guard !isArmed else { return }
        isArmed = true
        statusText = "Murmur is on"
        presentLiveActivity(recording: false, label: "On")
        HandoffDiagnostics.record("app.session.enabledIdle")
    }

    /// Action Button / Shortcuts. Records in Murmur; stop copies to the clipboard.
    func startFromActionButton() {
        guard !isRecording, !isBusy, !isAwaitingHostReturn else { return }
        startFreshTake(fromActionButton: true)
        HandoffDiagnostics.record("app.actionButton.start")
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
        if command == .hostReady {
            hostKeyboardReady()
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
        case .start, .cancel, .hostReady:
            break
        case nil:
            break
        }
        tryHostBounce(reason: "becomeActive")
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
            isArmed = true
            statusText = "Murmur is on"
            hostBundleID = lease.hostBundleID
            presentLiveActivity(recording: false, label: "On")
            scheduleLeaseExpiration(lease)
            HandoffDiagnostics.record("app.lease.restored", detail: lease.sessionID)
            return
        }
        if let payload, payload.status == .pending {
            let age = DictationHandoff.pendingAge() ?? .infinity
            HandoffDiagnostics.record("app.pending.observed", detail: "\(payload.id) age=\(age)")
            if age > 12 && AppGroupStore.listenGateRequestID != payload.id {
                DictationHandoff.write(.init(
                    id: payload.id,
                    status: .failed,
                    text: "",
                    error: "The recording request expired. Tap the keyboard mic to try again.",
                    hostBundleID: payload.hostBundleID
                ))
                HandoffDiagnostics.record("app.pending.expired", detail: payload.id)
                return
            }
            if AppGroupStore.listenGateRequestID == payload.id {
                requestID = payload.id
                hostBundleID = payload.hostBundleID
                keyboardStack = true
                listenGated = true
                isAwaitingHostReturn = true
                isArmed = true
                isRecording = false
                statusText = "Murmur is on"
                HandoffDiagnostics.record("app.listenGate.restored", detail: payload.id)
                scheduleListenGateTimeout()
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

    func arm(
        id: String,
        hostBundleID: String,
        hostPID: Int = 0,
        keyboardStack: Bool,
        sourceApplication: String = ""
    ) {
        guard let payload = DictationHandoff.read(), payload.id == id,
              payload.status == .pending, (DictationHandoff.pendingAge() ?? .infinity) <= 12 else {
            HandoffDiagnostics.record("app.deeplink.rejected", detail: id)
            return
        }
        if isArmed, requestID == id {
            if self.hostBundleID.isEmpty,
               let source = HostAppProbe.sanitizeForHost(sourceApplication) {
                self.hostBundleID = source
                if self.hostPID > 1 {
                    HostAppProbe.remember(pid: pid_t(self.hostPID), bundleID: source)
                }
                HandoffDiagnostics.record("app.host.sourceLate", detail: source)
                tryHostBounce(reason: "source-late")
            }
            return
        }
        if recorder.isRecording || recorder.canResume {
            isArmed = true
            return
        }
        leaseExpiryTask?.cancel()
        leaseHeartbeatTask?.cancel()
        DictationHandoff.clearLease()
        var host = hostBundleID
        if host.isEmpty { host = payload.hostBundleID }
        let pid = hostPID > 1 ? hostPID : (payload.hostPID ?? 0)
        let probe = HostAppProbe.frontmostProbe()
        HandoffDiagnostics.record(
            "app.host.frontmostProbe",
            detail: "pid=\(pid) sbs=\(probe.sbs ?? "nil") ws=\(probe.workspace ?? "nil") ok=\(probe.sanitized ?? "nil") src=\(sourceApplication.isEmpty ? "nil" : sourceApplication)"
        )
        if host.isEmpty, pid > 1 {
            host = HostAppProbe.bundleID(forPID: pid_t(pid)) ?? ""
            HandoffDiagnostics.record(
                "app.host.pidResolved",
                detail: "pid=\(pid) host=\(host.isEmpty ? "empty" : host)"
            )
        }
        if host.isEmpty, pid > 1, let learned = HostAppProbe.rememberedBundleID(forPID: pid_t(pid)) {
            host = learned
            HandoffDiagnostics.record("app.host.pidLearned", detail: "pid=\(pid) host=\(host)")
        }
        if host.isEmpty, let source = HostAppProbe.sanitizeForHost(sourceApplication) {
            host = source
            HandoffDiagnostics.record("app.host.sourceApplication", detail: host)
            if pid > 1 { HostAppProbe.remember(pid: pid_t(pid), bundleID: host) }
        }
        if host.isEmpty, let front = probe.sanitized {
            host = front
            HandoffDiagnostics.record("app.host.frontmost", detail: host)
            if pid > 1 { HostAppProbe.remember(pid: pid_t(pid), bundleID: host) }
        }
        requestID = id
        self.hostBundleID = host
        self.hostPID = pid
        self.keyboardStack = keyboardStack
        if host.isEmpty {
            HostAppProbe.forget()
        } else {
            HostAppProbe.remember(host)
        }
        isArmed = true
        isBusy = false
        isPaused = false
        fromActionButton = false
        transcript = ""
        statusText = keyboardStack
            ? "Murmur is on"
            : "Listening…"
        write(.pending, text: "", error: "")
        beginRecording(bounce: true, retryByForeground: false, gateListen: keyboardStack)
    }

    func toggleMic() {
        restoreIfNeeded()
        guard !isBusy else { return }
        if listenGated {
            return
        }
        if recorder.isRecording {
            recorder.pause()
            isRecording = false
            isPaused = true
            statusText = "Paused"
            write(.paused, text: "", error: "")
            presentLiveActivity(recording: false, label: "Paused")
            return
        }
        if recorder.canResume {
            do {
                try recorder.resume()
                isRecording = true
                isPaused = false
                statusText = "Listening…"
                write(.recording, text: "", error: "")
                presentLiveActivity(recording: true, label: "Listening")
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
        presentLiveActivity(recording: false, label: "Transcribing")
        let key = AppGroupStore.apiKey
        let language = AppGroupStore.languageCode
        let id = requestID
        HandoffDiagnostics.record("app.transcription.started", detail: id)
        transcribeTask = Task {
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let raw = try await ElevenLabsBatch.transcribe(
                    audioURL: url,
                    apiKey: key,
                    language: language,
                    noVerbatim: true,
                    keyterms: DictionaryStore.selectKeyterms(from: MurmurStores.dictionary.entries)
                )
                await MainActor.run {
                    guard self.requestID == id else { return }
                    let spoken = TranscriptPostProcessor.applySpokenPasses(raw)
                    let corrected = MurmurStores.dictionary.correct(spoken)
                    let styled = StyleFormatter.apply(
                        corrected,
                        profile: MurmurStores.style.selected,
                        preserveTerms: MurmurStores.dictionary.entries.map(\.term)
                    )
                    let text = MurmurStores.snippets.expand(styled)
                    self.transcript = text
                    self.isBusy = false
                    self.write(.done, text: text, error: "")
                    MurmurStores.history.append(text: text, failed: false)
                    if self.fromActionButton {
                        UIPasteboard.general.string = text
                        self.statusText = "Copied to clipboard"
                    } else {
                        self.statusText = "Inserted"
                    }
                    self.fromActionButton = false
                    HandoffDiagnostics.record(
                        "app.transcription.succeeded",
                        detail: "\(id) characters=\(text.count)"
                    )
                    if self.keepaliveEligible {
                        self.isArmed = true
                        self.statusText = "Murmur is on"
                        self.publishLease(completedRequestID: id)
                    } else {
                        HandoffDiagnostics.record("app.lease.skipped", detail: "\(id) audioSessionUnavailable")
                        self.isArmed = false
                        self.endLiveActivity()
                    }
                    self.requestID = ""
                }
            } catch {
                await MainActor.run {
                    guard self.requestID == id else { return }
                    self.isBusy = false
                    self.isArmed = false
                    self.statusText = error.localizedDescription
                    self.write(.failed, text: "", error: error.localizedDescription)
                    MurmurStores.history.append(text: error.localizedDescription, failed: true)
                    self.fromActionButton = false
                    HandoffDiagnostics.record("app.transcription.failed", detail: "\(id) \(error.localizedDescription)")
                    self.clearLease()
                    self.endLiveActivity()
                    self.requestID = ""
                }
            }
        }
    }

    func discard() {
        clearListenGate()
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
        fromActionButton = false
        clearLease()
        endLiveActivity()
    }

    /// Keyboard reappeared in the originating app — open the segment and start Listening.
    /// Only after Murmur is backgrounded. `applicationState != .active` is not enough
    /// (launch is `.inactive` and was opening the mic on the interstitial).
    func hostKeyboardReady() {
        let gatedID = AppGroupStore.listenGateRequestID
        guard listenGated,
              !requestID.isEmpty,
              gatedID == requestID,
              !recorder.isRecording,
              !isBusy else {
            return
        }
        if murmurForeground {
            pendingHostReady = true
            HandoffDiagnostics.record("app.hostReady.deferred", detail: "foreground \(requestID)")
            return
        }
        pendingHostReady = false
        learnHostFromFrontmost()
        HandoffDiagnostics.record("app.hostReady", detail: requestID)
        openGatedSegment()
    }

    func setForeground(_ on: Bool) {
        let wasForeground = murmurForeground
        murmurForeground = on
        if wasForeground && !on {
            learnHostFromFrontmost()
            scheduleLearnRetries()
            murmurDidResign()
        }
    }

    /// Interstitial control: user picked a host. Remembers the PID so the next
    /// Start with that PID bounces. Does not guess for unknown apps.
    func returnToApp(_ bundleID: String) {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ReturnAppCatalog.isAllowed(id) else { return }
        hostBundleID = id
        if hostPID > 1 {
            HostAppProbe.remember(pid: pid_t(hostPID), bundleID: id)
        }
        HostAppProbe.remember(id)
        HandoffDiagnostics.record("app.return.appButton", detail: "\(id) pid=\(hostPID)")
        hostBounceAttempts = 0
        tryHostBounce(reason: "app-button")
    }

    func returnToMessages() {
        returnToApp(HostReturn.messagesBundle)
    }

    /// User left Murmur (swipe or bounce). If the keyboard already appeared, start capture.
    func murmurDidResign() {
        guard pendingHostReady else { return }
        pendingHostReady = false
        HandoffDiagnostics.record("app.hostReady.flushed", detail: requestID)
        hostKeyboardReady()
    }

    private func learnHostFromFrontmost() {
        guard hostPID > 1 else { return }
        let probe = HostAppProbe.frontmostProbe()
        HandoffDiagnostics.record(
            "app.host.frontmostProbe",
            detail: "pid=\(hostPID) sbs=\(probe.sbs ?? "nil") ws=\(probe.workspace ?? "nil") ok=\(probe.sanitized ?? "nil")"
        )
        if let id = probe.sanitized {
            HostAppProbe.remember(pid: pid_t(hostPID), bundleID: id)
            if hostBundleID.isEmpty { hostBundleID = id }
            HandoffDiagnostics.record("app.host.learned", detail: "pid=\(hostPID) \(id)")
        }
    }

    private func scheduleLearnRetries() {
        learnTask?.cancel()
        let pid = hostPID
        learnTask = Task { @MainActor in
            for delay in [0.35, 0.8, 1.6, 3.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, hostPID == pid, pid > 1 else { return }
                if HostAppProbe.rememberedBundleID(forPID: pid_t(pid)) != nil { return }
                learnHostFromFrontmost()
            }
        }
    }

    private func startFreshTake(fromActionButton action: Bool = false) {
        clearLease()
        clearListenGate()
        let id = UUID().uuidString
        requestID = id
        isArmed = true
        isBusy = false
        isPaused = false
        transcript = ""
        fromActionButton = action
        write(.pending, text: "", error: "")
        beginRecording(bounce: false, retryByForeground: false, gateListen: false)
        if action {
            statusText = "Listening… Stop to copy."
        }
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
        clearListenGate()
        requestID = payload.id
        hostBundleID = payload.hostBundleID.isEmpty ? lease.hostBundleID : payload.hostBundleID
        keyboardStack = true
        isArmed = true
        isBusy = false
        isPaused = false
        fromActionButton = false
        transcript = ""
        statusText = "Listening…"
        HandoffDiagnostics.record("app.lease.startAccepted", detail: payload.id)
        beginRecording(bounce: false, retryByForeground: true, gateListen: false)
    }

    private func beginRecording(bounce _: Bool, retryByForeground: Bool, gateListen: Bool) {
        if gateListen {
            beginGatedRecording()
            return
        }
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
        markListeningLive()
    }

    /// Arm the input graph in Murmur foreground, bounce/swipe, open the file only
    /// after the keyboard signals hostReady.
    private func beginGatedRecording() {
        HandoffDiagnostics.record("app.recording.arming", detail: "\(requestID) listenGated=yes")
        do {
            try recorder.armInputGraph()
        } catch {
            HandoffDiagnostics.record(
                "app.recording.armFailed",
                detail: "\(error.localizedDescription) — degrade to immediate capture"
            )
            // Degrade: mic must start in Murmur if we cannot arm a gated graph.
            HandoffDiagnostics.record("app.listenGate.degrade", detail: requestID)
            beginRecording(bounce: false, retryByForeground: false, gateListen: false)
            return
        }
        listenGated = true
        isAwaitingHostReturn = true
        keepaliveEligible = true
        AppGroupStore.listenGateRequestID = requestID
        isRecording = false
        isPaused = false
        statusText = "Murmur is on"
        write(.pending, text: "", error: "")
        presentLiveActivity(recording: false, label: "On")
        HandoffDiagnostics.record("app.listenGate.armed", detail: requestID)
        scheduleListenGateTimeout()
        hostBounceAttempts = 0
        tryHostBounce(reason: "armed")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            self.tryHostBounce(reason: "armed-delayed")
        }
    }

    /// Bounce only with this take’s probed host. Unknown host → interstitial.
    /// Never invent Messages — that kidnapped Notes (and every other app).
    private func tryHostBounce(reason: String) {
        guard keyboardStack, listenGated, isAwaitingHostReturn else { return }
        guard !hostBundleID.isEmpty else {
            HandoffDiagnostics.record("app.return.skipped", detail: "host=empty reason=\(reason)")
            return
        }
        guard hostBounceAttempts < 2 else { return }
        hostBounceAttempts += 1
        HandoffDiagnostics.record(
            "app.return.try",
            detail: "\(hostBundleID) reason=\(reason) n=\(hostBounceAttempts)"
        )
        HostReturn.bounceBack(keyboardStack: true, hostBundleID: hostBundleID)
    }

    private func openGatedSegment() {
        listenGateTimeoutTask?.cancel()
        listenGateTimeoutTask = nil
        HandoffDiagnostics.record("app.recording.starting", detail: "\(requestID) listenGated=open")
        do {
            try recorder.start()
        } catch {
            HandoffDiagnostics.record(
                "app.recording.failed",
                detail: "\(error.localizedDescription) listenGate=open"
            )
            // Background open failed — degrade note for device AC; fail this take cleanly.
            HandoffDiagnostics.record("app.listenGate.openFailed", detail: requestID)
            statusText = error.localizedDescription
            write(.failed, text: "", error: error.localizedDescription)
            clearListenGate()
            isArmed = false
            clearLease()
            endLiveActivity()
            requestID = ""
            return
        }
        clearListenGate()
        markListeningLive()
        HandoffDiagnostics.record("app.listenGate.opened", detail: requestID)
    }

    private func markListeningLive() {
        isAwaitingHostReturn = false
        isRecording = true
        keepaliveEligible = true
        startMetering()
        HandoffDiagnostics.record("app.recording.started", detail: requestID)
        isPaused = false
        statusText = "Listening…"
        presentLiveActivity(recording: true, label: "Listening")
        write(.recording, text: "", error: "")
    }

    private func scheduleListenGateTimeout() {
        listenGateTimeoutTask?.cancel()
        let id = requestID
        listenGateTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.listenGated,
                      self.requestID == id,
                      !self.recorder.isRecording else { return }
                HandoffDiagnostics.record("app.listenGate.timeout", detail: id)
                self.statusText = "Return timed out. Tap the keyboard mic to try again."
                self.write(
                    .failed,
                    text: "",
                    error: "Return to the app timed out before listening started. Tap the keyboard mic to try again."
                )
                self.clearListenGate()
                self.isArmed = false
                self.requestID = ""
                self.clearLease()
                self.endLiveActivity()
            }
        }
    }

    private func clearListenGate() {
        listenGateTimeoutTask?.cancel()
        listenGateTimeoutTask = nil
        learnTask?.cancel()
        learnTask = nil
        if AppGroupStore.listenGateRequestID == requestID || requestID.isEmpty {
            AppGroupStore.listenGateRequestID = ""
        }
        listenGated = false
        isAwaitingHostReturn = false
        hostBounceAttempts = 0
        pendingHostReady = false
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
        presentLiveActivity(recording: false, label: "On")
        scheduleLeaseExpiration(lease)
    }

    private func scheduleLeaseExpiration(_ lease: DictationHandoff.Lease) {
        leaseExpiryTask?.cancel()
        leaseHeartbeatTask?.cancel()
        leaseHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    guard self.recorder.isInputGraphArmed else {
                        self.clearLease()
                        self.isArmed = false
                        self.endLiveActivity()
                        HandoffDiagnostics.record("app.lease.expired", detail: "graph-dead")
                        return
                    }
                    let next = DictationHandoff.Lease(
                        sessionID: DictationHandoff.readLease()?.sessionID ?? lease.sessionID,
                        hostBundleID: self.hostBundleID.isEmpty ? lease.hostBundleID : self.hostBundleID,
                        expiresAt: .now.addingTimeInterval(DictationHandoff.leaseDuration),
                        heartbeatAt: .now
                    )
                    DictationHandoff.writeLease(next)
                }
            }
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
        clearListenGate()
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

    private func presentLiveActivity(recording: Bool, label: String) {
        if activity == nil {
            activity = Activity<DictationAttributes>.activities.first
        }
        if activity != nil {
            updateLiveActivity(recording: recording, label: label)
            return
        }
        startLiveActivity(recording: recording, label: label)
    }

    private func startLiveActivity(recording: Bool, label: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = DictationAttributes(requestID: requestID.isEmpty ? "lease" : requestID)
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
