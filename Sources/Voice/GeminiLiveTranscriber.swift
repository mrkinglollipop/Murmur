import AVFoundation
import Foundation
import os.log

// MARK: - Streaming transcription session (Gemini 3.5 Transcribe Live WebSocket)

/// Push-to-talk streaming speech-to-text client for Google's
/// `gemini-3.5-transcribe-live` BidiGenerateContent WebSocket.
/// Structurally modeled on `ElevenLabsRealtimeTranscriber`.
final class GeminiLiveTranscriber: NSObject, URLSessionWebSocketDelegate {
    typealias MessageSender = (URLSessionWebSocketTask.Message) async throws -> Void

    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "gemini-streaming")

    private let apiKey: String
    private let language: String
    private let smartMode: Bool
    private let vocabulary: [String]
    private let liveOptions: GeminiLiveOptions
    private let injectedMessageSender: MessageSender?
    private let readinessTimeoutSeconds: TimeInterval
    private let finalizeBudgetOverride: TimeInterval?
    private let now: () -> Date

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private var senderTask: Task<Void, Never>?

    private var frameContinuation: AsyncStream<String>.Continuation?

    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    var onInterim: ((String) -> Void)?

    private let stateLock = NSLock()
    private var committedSegments: [String] = []
    private var latestPartial: String = ""
    private var everHadNonEmptyStreamText = false

    var hasEverHadNonEmptyStreamText: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return everHadNonEmptyStreamText
    }

    func joinedTranscriptSnapshot() -> String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
    }

    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var readyResolved = false
    /// Set once `start()` has begun. With `readyResolved` still false, the
    /// socket has not yet accepted setup, so anything sent now would be wasted.
    private var startInvoked = false

    private var doneContinuation: CheckedContinuation<String, Never>?
    private var doneResolved = false

    private var finalizeRequested = false
    private var finalizeBoundaryArmed = false
    private var finalizeCommittedEventSeen = false
    private var finalizeTurnCompleteSeen = false
    private var tornDown = false
    private var socketClosed = false
    private var streamIntegrityFailed = false
    private var lastFinalizeRequiresBufferedAudioRecovery = false
    private var intentionalSocketShutdown = false

    private var sessionStartTime: Date?
    private var sessionCapReached = false
    private var activityStartSent = false

    static let sessionCapSeconds: TimeInterval = 580

    var requiresBufferedAudioRecovery: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastFinalizeRequiresBufferedAudioRecovery || streamIntegrityFailed || sessionCapReached
    }

    init(
        apiKey: String,
        language: String = "en",
        smartMode: Bool = true,
        vocabulary: [String] = [],
        liveOptions: GeminiLiveOptions = .defaults,
        finalizeBudgetOverride: TimeInterval? = nil,
        readinessTimeoutSeconds: TimeInterval = 5,
        messageSender: MessageSender? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.apiKey = apiKey
        self.language = language
        self.smartMode = smartMode
        self.vocabulary = vocabulary
        self.liveOptions = liveOptions.clamped()
        self.injectedMessageSender = messageSender
        self.readinessTimeoutSeconds = readinessTimeoutSeconds
        self.finalizeBudgetOverride = finalizeBudgetOverride
        self.now = now
        super.init()
    }

    // MARK: - Lifecycle

    func start() async throws {
        vlog("gemini-stream: starting session")
        stateLock.lock()
        startInvoked = true
        streamIntegrityFailed = false
        lastFinalizeRequiresBufferedAudioRecovery = false
        intentionalSocketShutdown = false
        stateLock.unlock()
        resetTranscriptState()

        guard let url = Self.buildSocketURL(apiKey: apiKey) else {
            throw CloudTranscriptionError(provider: .gemini, message: "Failed to build streaming URL")
        }

        // An injected message sender replaces the socket entirely (unit tests):
        // no URLSession is created, so start() never touches the network.
        let task: URLSessionWebSocketTask?
        if injectedMessageSender == nil {
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            let socketTask = session.webSocketTask(with: url)
            self.session = session
            self.task = socketTask
            task = socketTask
        } else {
            task = nil
        }

        // Production writes go straight to the captured task (unaffected by a
        // later teardown clearing `self.task`); with no socket, the injected sender.
        func sendFrame(_ message: URLSessionWebSocketTask.Message) async throws {
            if let task { try await task.send(message) } else { try await sendMessage(message) }
        }
        self.sessionStartTime = now()

        let stream = AsyncStream<String> { continuation in
            self.stateLock.lock()
            self.frameContinuation = continuation
            self.stateLock.unlock()
        }

        receiveLoopTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }

        task?.resume()

        let setupFrame = GeminiLiveOptions.makeSetupMessageJSON(
            language: language,
            smartMode: smartMode,
            vocabulary: vocabulary,
            options: liveOptions
        )
        // The setup send shares the readiness deadline: a stalled connect must
        // not block start() (and the finalize budget behind it) on a send that
        // never returns.
        do {
            try await AsyncDeadline.run(
                seconds: readinessTimeoutSeconds,
                timeoutError: { CloudTranscriptionError(provider: .gemini, message: "Timed out waiting for setupComplete") },
                operation: { [self] in
                    try await sendMessage(.string(setupFrame))
                    try await awaitReady()
                }
            )
        } catch {
            failPendingReady(error)
            throw error
        }

        senderTask = Task { [weak self] in
            guard let self else { return }
            if self.liveOptions.vadMode == .manual, !self.activityStartSent {
                if self.task != nil || self.injectedMessageSender != nil {
                    let startFrame = GeminiLiveOptions.makeActivityStartFrameJSON()
                    do {
                        try await self.sendMessage(.string(startFrame))
                        self.stateLock.lock()
                        self.activityStartSent = true
                        self.stateLock.unlock()
                    } catch {
                        self.markStreamIntegrityFailed()
                    }
                }
            }
            for await frame in stream {
                do {
                    try await sendFrame(.string(frame))
                } catch {
                    self.markStreamIntegrityFailed()
                    let ns = error as NSError
                    vlog("gemini-stream: send failed, stopping sender: \(ns.domain)#\(ns.code)")
                    break
                }
            }
        }

        vlog("gemini-stream: session ready")
    }

    /// Suspends until the ready signal resolves (or returns immediately when it
    /// already did before this call registered).
    private func awaitReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stateLock.lock()
            if readyResolved {
                stateLock.unlock()
                continuation.resume()
                return
            }
            readyContinuation = continuation
            stateLock.unlock()
        }
    }

    /// Fails a still-registered ready waiter so a timed-out start() does not
    /// leave its continuation suspended forever.
    private func failPendingReady(_ error: Error) {
        stateLock.lock()
        let pending = readyResolved ? nil : readyContinuation
        if !readyResolved {
            readyResolved = true
            readyContinuation = nil
        }
        stateLock.unlock()
        pending?.resume(throwing: error)
    }

    func send(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let continuation = frameContinuation
        let capReached = sessionCapReached
        let start = sessionStartTime
        stateLock.unlock()
        if let start, !capReached, Self.sessionCapExceeded(elapsed: now().timeIntervalSince(start)) {
            recordSessionCapReached()
        }
        stateLock.lock()
        let blocked = capReached || sessionCapReached
        stateLock.unlock()
        guard let continuation, !blocked else { return }
        guard let pcmData = convertToPCM16(buffer) else {
            markStreamIntegrityFailed()
            vlogFromAudioTap(.conversionFailure(.gemini, .emptyConversion))
            return
        }
        continuation.yield(GeminiLiveOptions.makeAudioFrameJSON(pcmData: pcmData))
    }

    func finalize(recordingDuration: TimeInterval = 0) async -> String {
        stateLock.lock()
        if tornDown {
            let text = Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
            stateLock.unlock()
            return text
        }
        tornDown = true
        finalizeRequested = true
        finalizeBoundaryArmed = false
        finalizeCommittedEventSeen = false
        finalizeTurnCompleteSeen = false
        let capReached = sessionCapReached
        stateLock.unlock()
        let finalizeStart = Date()
        let waitSeconds = finalizeBudgetOverride
            ?? min(30.0, max(3.0, recordingDuration * 0.25 + 3.0))
        let finalizeDeadline = finalizeStart.addingTimeInterval(waitSeconds)

        stateLock.lock()
        let framesToFinish = frameContinuation
        frameContinuation = nil
        stateLock.unlock()
        framesToFinish?.finish()
        let senderToDrain = senderTask
        do {
            try await AsyncDeadline.run(
                seconds: max(0, finalizeDeadline.timeIntervalSinceNow),
                timeoutError: { CloudTranscriptionError(provider: .gemini, message: "Finalize deadline exceeded while draining audio") },
                operation: { await senderToDrain?.value }
            )
        } catch {
            markStreamIntegrityFailed()
            tearDownSocket()
            stateLock.lock()
            let text = Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
            resetTranscriptState()
            stateLock.unlock()
            return text
        }
        senderTask = nil

        stateLock.lock()
        let closed = socketClosed
        let integrityFailed = streamIntegrityFailed
        let notReady = startInvoked && !readyResolved
        let accumulatedSoFar = Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
        stateLock.unlock()

        if capReached {
            markStreamIntegrityFailed()
            tearDownSocket()
            let capText = Self.capReachedFinalizeText(accumulatedSoFar: accumulatedSoFar)
            vlog("gemini-stream: finalize short-circuit (10min cap), \(capText.count) chars preserved")
            stateLock.lock()
            resetTranscriptState()
            stateLock.unlock()
            return capText
        }

        // Released before setupComplete: the end-of-stream frame would reach the
        // socket ahead of any audio, so skip it and recover from the buffered audio.
        if closed || integrityFailed || notReady {
            if closed || notReady { markStreamIntegrityFailed() }
            tearDownSocket()
            vlog("gemini-stream: finalize short-circuit (socket/integrity/not-ready), \(accumulatedSoFar.count) chars")
            stateLock.lock()
            resetTranscriptState()
            stateLock.unlock()
            return accumulatedSoFar
        }

        stateLock.lock()
        finalizeCommittedEventSeen = false
        finalizeTurnCompleteSeen = false
        stateLock.unlock()
        if task != nil || injectedMessageSender != nil {
            let endFrame: String
            switch liveOptions.vadMode {
            case .manual:
                endFrame = GeminiLiveOptions.makeActivityEndFrameJSON()
            case .hybrid, .automatic:
                // Automatic previously sent nothing and relied on timeout /
                // next transcription — that early-done path drops the tail.
                endFrame = GeminiLiveOptions.makeAudioStreamEndFrameJSON()
            }
            do {
                try await AsyncDeadline.run(
                    seconds: max(0, finalizeDeadline.timeIntervalSinceNow),
                    timeoutError: { CloudTranscriptionError(provider: .gemini, message: "Finalize deadline exceeded while ending audio") },
                    operation: { [self] in try await sendMessage(.string(endFrame)) }
                )
            } catch {
                markStreamIntegrityFailed()
                tearDownSocket()
                stateLock.lock()
                let text = Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
                resetTranscriptState()
                stateLock.unlock()
                return text
            }
        }
        stateLock.lock()
        finalizeBoundaryArmed = true
        let shouldResolveDone = finalizeCommittedEventSeen
            && finalizeTurnCompleteSeen
            && !doneResolved
        let earlyContinuation = shouldResolveDone ? doneContinuation : nil
        let earlyText = Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
        if shouldResolveDone {
            doneResolved = true
            doneContinuation = nil
        }
        stateLock.unlock()
        earlyContinuation?.resume(returning: earlyText)

        let remainingWait = max(0, finalizeDeadline.timeIntervalSinceNow)
        let waitNs = UInt64(remainingWait * 1_000_000_000)

        let result = await withTaskGroup(of: String?.self) { group -> String in
            group.addTask { [weak self] in
                guard let self else { return nil }
                return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                    self.stateLock.lock()
                    if self.doneResolved {
                        let text = Self.joinedTranscript(segments: self.committedSegments, partial: self.latestPartial)
                        self.stateLock.unlock()
                        continuation.resume(returning: text)
                        return
                    }
                    self.doneContinuation = continuation
                    self.stateLock.unlock()
                }
            }
            group.addTask { [weak self] in
                try? await Task.sleep(nanoseconds: waitNs)
                guard let self else { return nil }
                self.stateLock.lock()
                if self.doneResolved {
                    self.stateLock.unlock()
                    return nil
                }
                let pending = self.doneContinuation
                self.lastFinalizeRequiresBufferedAudioRecovery = true
                self.streamIntegrityFailed = true
                let text = Self.joinedTranscript(segments: self.committedSegments, partial: self.latestPartial)
                self.doneResolved = true
                self.doneContinuation = nil
                self.stateLock.unlock()
                pending?.resume(returning: text)
                return text
            }
            for await value in group {
                if let value {
                    group.cancelAll()
                    return value
                }
            }
            return ""
        }

        tearDownSocket()

        vlog("gemini-stream: finalize took \(String(format: "%.3f", Date().timeIntervalSince(finalizeStart)))s (budget=\(String(format: "%.1f", waitSeconds))s), \(result.count) chars")
        stateLock.lock()
        resetTranscriptState()
        stateLock.unlock()
        return result
    }

    func cancel() {
        stateLock.lock()
        if tornDown {
            stateLock.unlock()
            return
        }
        tornDown = true
        stateLock.unlock()
        stateLock.lock()
        let framesToFinish = frameContinuation
        frameContinuation = nil
        stateLock.unlock()
        framesToFinish?.finish()

        stateLock.lock()
        let pendingReady = readyResolved ? nil : readyContinuation
        if !readyResolved {
            readyResolved = true
            readyContinuation = nil
        }
        let pendingDone = doneResolved ? nil : doneContinuation
        doneResolved = true
        doneContinuation = nil
        let accumulated = Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
        resetTranscriptState()
        stateLock.unlock()
        pendingReady?.resume(throwing: CloudTranscriptionError(provider: .gemini, message: "cancelled"))
        pendingDone?.resume(returning: accumulated)

        tearDownSocket()
        vlog("gemini-stream: cancelled")
    }

    private func resetTranscriptState() {
        committedSegments = []
        latestPartial = ""
        everHadNonEmptyStreamText = false
        finalizeRequested = false
        finalizeBoundaryArmed = false
        finalizeCommittedEventSeen = false
        finalizeTurnCompleteSeen = false
        activityStartSent = false
        sessionCapReached = false
        sessionStartTime = nil
    }

    private func tearDownSocket() {
        stateLock.lock()
        intentionalSocketShutdown = true
        stateLock.unlock()
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        senderTask?.cancel()
        senderTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
        vlog("gemini-stream: socket opened (proto=\(proto ?? "none"))")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        vlog("gemini-stream: socket closed (code=\(closeCode.rawValue) reason=\(reasonStr))")
        noteSocketClosed(closeCode: closeCode)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1
        if let ns = error as NSError? {
            vlog("gemini-stream: task completed httpStatus=\(status) error=\(ns.domain)#\(ns.code)")
        } else {
            vlog("gemini-stream: task completed httpStatus=\(status) error=none")
        }
        stateLock.lock()
        let intentional = intentionalSocketShutdown
        stateLock.unlock()
        if error != nil, !intentional { markStreamIntegrityFailed() }
        failReadyIfPending("task completed httpStatus=\(status)")
    }

    private func failReadyIfPending(_ reason: String) {
        stateLock.lock()
        socketClosed = true
        let cont = readyResolved ? nil : readyContinuation
        if !readyResolved {
            readyResolved = true
            readyContinuation = nil
        }
        let pendingDone = doneResolved ? nil : doneContinuation
        let accumulated = Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
        if !doneResolved {
            doneResolved = true
            doneContinuation = nil
        }
        stateLock.unlock()
        cont?.resume(throwing: CloudTranscriptionError(provider: .gemini, message: reason))
        pendingDone?.resume(returning: accumulated)
    }

    // MARK: - Receive loop

    private func runReceiveLoop() async {
        guard let task else { return }
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                let ns = error as NSError
                // Domain+code only — localizedDescription can include the WSS URL (`key=`).
                vlog("gemini-stream: receive loop ended: \(ns.domain)#\(ns.code)")
                stateLock.lock()
                let intentional = intentionalSocketShutdown
                stateLock.unlock()
                if !intentional { markStreamIntegrityFailed() }
                failReadyIfPending("receive: \(ns.domain)#\(ns.code)")
                break
            }

            switch message {
            case .string(let text):
                handleServerEvent(text)
            case .data(let data):
                // Google Live WS delivers BidiGenerateContentServerMessage as
                // binary UTF-8 JSON (not text frames). Dropping `.data` means
                // setupComplete and every transcript never arrive — Live
                // always times out. Verified against the production WSS 2026-08-27.
                if let text = Self.utf8JSONText(fromWebSocketData: data) {
                    handleServerEvent(text)
                } else {
                    markStreamIntegrityFailed()
                    vlog("gemini-stream: received non-utf8 binary frame (\(data.count) bytes)")
                }
            @unknown default:
                continue
            }
        }
    }

    func handleServerEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            markStreamIntegrityFailed()
            vlog("gemini-stream: received unparseable event")
            return
        }

        if json["error"] != nil {
            let message: String
            if let node = json["error"] as? [String: Any] {
                message = (node["message"] as? String) ?? (node["status"] as? String) ?? "error"
            } else if let text = json["error"] as? String {
                message = text
            } else {
                message = "error"
            }
            vlog("gemini-stream: server error: \(CloudTranscriptionError.redactedBodyFragment(message))")
            markStreamIntegrityFailed()
            failReadyIfPending("server error")
            return
        }

        if json["setupComplete"] != nil || json["setup_complete"] != nil {
            stateLock.lock()
            let continuation = readyResolved ? nil : readyContinuation
            readyResolved = true
            readyContinuation = nil
            stateLock.unlock()
            continuation?.resume()
            vlog("gemini-stream: setupComplete")
            return
        }

        guard let serverContent = (json["serverContent"] as? [String: Any])
            ?? (json["server_content"] as? [String: Any]) else {
            return
        }

        if let interim = transcriptionText(
            from: serverContent,
            keys: ["interimInputTranscription", "interim_input_transcription"]
        ) {
            applyPartial(interim)
        }

        if let committed = transcriptionText(
            from: serverContent,
            keys: ["inputTranscription", "input_transcription"]
        ) {
            applyCommitted(committed)
        }

        if (serverContent["turnComplete"] as? Bool) == true
            || (serverContent["turn_complete"] as? Bool) == true {
            noteTurnComplete()
        }
    }

    private func transcriptionText(from serverContent: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let node = serverContent[key] as? [String: Any],
               let text = node["text"] as? String {
                return text
            }
        }
        return nil
    }

    private func applyPartial(_ partialText: String) {
        stateLock.lock()
        let trimmedPartial = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPartial.isEmpty {
            latestPartial = partialText
            everHadNonEmptyStreamText = true
        }
        let running = Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
        stateLock.unlock()
        onInterim?(running)
    }

    private func applyCommitted(_ committedText: String) {
        stateLock.lock()
        let trimmed = committedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            committedSegments.append(trimmed)
            everHadNonEmptyStreamText = true
            // Do not join new segment + stale partial (duplicates the head).
            latestPartial = ""
        }
        let running = Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
        if finalizeRequested { finalizeCommittedEventSeen = true }
        let shouldResolveDone = finalizeRequested
            && finalizeBoundaryArmed
            && finalizeCommittedEventSeen
            && finalizeTurnCompleteSeen
            && !doneResolved
        let continuation = shouldResolveDone ? doneContinuation : nil
        if shouldResolveDone {
            doneResolved = true
            doneContinuation = nil
        }
        stateLock.unlock()
        continuation?.resume(returning: running)
        onInterim?(running)
        vlog("gemini-stream: inputTranscription (\(trimmed.count) chars) finalizeRequested=\(finalizeRequested)")
    }

    private func noteTurnComplete() {
        stateLock.lock()
        if finalizeRequested { finalizeTurnCompleteSeen = true }
        let shouldResolveDone = finalizeRequested
            && finalizeBoundaryArmed
            && finalizeCommittedEventSeen
            && finalizeTurnCompleteSeen
            && !doneResolved
        let continuation = shouldResolveDone ? doneContinuation : nil
        let running = Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
        if shouldResolveDone {
            doneResolved = true
            doneContinuation = nil
        }
        stateLock.unlock()
        continuation?.resume(returning: running)
    }

    private func sendMessage(_ message: URLSessionWebSocketTask.Message) async throws {
        if let injectedMessageSender {
            try await injectedMessageSender(message)
            return
        }
        guard let task else {
            throw CloudTranscriptionError(provider: .gemini, message: "stream socket unavailable")
        }
        try await task.send(message)
    }

    private func markStreamIntegrityFailed() {
        stateLock.lock()
        streamIntegrityFailed = true
        lastFinalizeRequiresBufferedAudioRecovery = true
        stateLock.unlock()
    }

    func recordSessionCapReached() {
        stateLock.lock()
        let newlyReached = !sessionCapReached
        sessionCapReached = true
        streamIntegrityFailed = true
        lastFinalizeRequiresBufferedAudioRecovery = true
        stateLock.unlock()
        if newlyReached { vlogFromAudioTap(.geminiDurationCap) }
    }

    func noteSocketClosed(closeCode: URLSessionWebSocketTask.CloseCode) {
        stateLock.lock()
        socketClosed = true
        let terminalComplete = doneResolved
        let shouldFail = !intentionalSocketShutdown
            && !(closeCode == .normalClosure && terminalComplete)
        stateLock.unlock()
        if shouldFail { markStreamIntegrityFailed() }
        failReadyIfPending("closed code \(closeCode.rawValue)")
    }

    // MARK: - Static helpers (@testable)

    /// UTF-8 JSON from a binary WebSocket payload. Live API frames are not
    /// guaranteed to be `.string`.
    static func utf8JSONText(fromWebSocketData data: Data) -> String? {
        String(data: data, encoding: .utf8)
    }

    static func buildSocketURL(apiKey: String) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "generativelanguage.googleapis.com"
        components.path = "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        return components.url
    }

    static let maxVocabularyTerms = 100

    static func selectVocabulary(from entries: [DictionaryEntry]) -> [String] {
        var seen = Set<String>()
        var candidates: [(term: String, fixCount: Int, index: Int)] = []
        for (index, entry) in entries.enumerated() {
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count > 1 else { continue }
            let key = term.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            candidates.append((term: term, fixCount: entry.fixCount, index: index))
        }
        candidates.sort { a, b in
            if a.fixCount != b.fixCount { return a.fixCount > b.fixCount }
            return a.index > b.index
        }
        return candidates.prefix(maxVocabularyTerms).map { $0.term }
    }

    static func joinedTranscript(segments: [String], partial: String) -> String {
        let committed = segments.joined(separator: " ")
        let trimmedPartial = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPartial.isEmpty else { return committed }
        guard !committed.isEmpty else { return trimmedPartial }
        if committed.localizedCaseInsensitiveContains(trimmedPartial) { return committed }
        return committed + " " + trimmedPartial
    }

    static func sessionCapExceeded(elapsed: TimeInterval) -> Bool {
        elapsed > sessionCapSeconds
    }

    /// Text `finalize()` returns when the session cap cuts the socket short.
    /// The cap (plans/028: 10min, "cancel and batch-fallback") must stop
    /// further audio from being sent — it must not also discard whatever was
    /// already transcribed live. Pure so the no-data-loss contract is
    /// testable without standing up a live 580s session.
    static func capReachedFinalizeText(accumulatedSoFar: String) -> String {
        accumulatedSoFar
    }

    // MARK: - Format conversion

    private func convertToPCM16(_ buffer: AVAudioPCMBuffer) -> Data? {
        let inputFormat = buffer.format

        if converter == nil || converterInputFormat != inputFormat {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                vlogFromAudioTap(.conversionFailure(.gemini, .converterCreation))
                return nil
            }
            converter = newConverter
            converterInputFormat = inputFormat
        }
        guard let converter else { return nil }

        let capacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate).rounded(.up) + 16
        )
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            vlogFromAudioTap(.conversionFailure(.gemini, .bufferAllocation))
            return nil
        }

        var error: NSError?
        var suppliedInput = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil else {
            vlogFromAudioTap(.conversionFailure(.gemini, .conversion))
            return nil
        }
        guard let int16Data = outputBuffer.int16ChannelData else {
            return nil
        }

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else { return nil }
        return Data(bytes: int16Data[0], count: frameCount * MemoryLayout<Int16>.size)
    }
}

// MARK: - Batch decode

enum GeminiBatchDecode {
    /// Decodes transcript text from a Gemini Interactions API JSON body.
    static func decodeTranscript(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let text = json["output_text"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return text }
        }
        if let output = json["output"] {
            if let text = output as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return text }
            }
            if let array = output as? [[String: Any]] {
                let joined = array.compactMap { item -> String? in
                    if let text = item["text"] as? String { return text }
                    if let content = item["content"] as? String { return content }
                    return nil
                }.joined(separator: " ")
                let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return joined }
            }
            if let dict = output as? [String: Any] {
                for key in ["text", "content", "transcript"] {
                    if let text = dict[key] as? String {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { return text }
                    }
                }
            }
        }
        // Interactions `steps[].content[].text` — documented parse path when
        // `output_text` is omitted (200 responses can have usage-only bodies).
        if let steps = json["steps"] as? [[String: Any]] {
            var parts: [String] = []
            for step in steps {
                let content = (step["content"] as? [[String: Any]]) ?? []
                for item in content {
                    if let text = item["text"] as? String {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { parts.append(text) }
                    }
                }
            }
            let joined = parts.joined(separator: " ")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return joined
            }
        }
        return nil
    }
}
