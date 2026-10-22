import AVFoundation
import Foundation
import os.log

// MARK: - Streaming transcription session (Meta Muse Voice Transcribe WebSocket)

/// Push-to-talk streaming speech-to-text client for Meta's Muse Voice
/// Transcribe realtime WebSocket (`wss://api.meta.ai/v1/asr/realtime`).
/// Structurally modeled on `ElevenLabsRealtimeTranscriber` — same public API,
/// same non-blocking `send(_:)` + `AsyncStream` sender pattern, same
/// ready/done `CheckedContinuation` bridge — but sends raw binary PCM16 LE
/// frames (not base64 JSON) per the Meta Model API.
final class MuseLiveTranscriber: NSObject, URLSessionWebSocketDelegate {
    typealias MessageSender = (URLSessionWebSocketTask.Message) async throws -> Void

    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "muse-streaming")

    private let apiKey: String
    private let language: String
    private let keywords: [String]
    private let sessionId: String
    private let injectedMessageSender: MessageSender?
    private let readinessTimeoutSeconds: TimeInterval
    private let finalizeBudgetOverride: TimeInterval?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private var senderTask: Task<Void, Never>?
    /// Opens only on a successful handshake; finishing without a value aborts sending.
    private var senderReadyContinuation: AsyncStream<Void>.Continuation?

    // Bound transport storage even when start is never called. Overflow latches
    // buffered-recording recovery; it must never silently truncate dictation.
    private var frameStream: AsyncStream<Data>?
    private var frameContinuation: AsyncStream<Data>.Continuation?

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
    // The first outcome also belongs to waiters registered after it resolves.
    private var readyResult: Result<Void, Error>?
    private var readyResolved: Bool { readyResult != nil }
    /// Set once `start()` has begun. With `readyResolved` still false, the
    /// handshake has not been acked, so anything sent now would be wasted.
    private var startInvoked = false

    private var doneContinuation: CheckedContinuation<String, Never>?
    private var doneResolved = false

    private var finalizeRequested = false
    private var finalizeBoundaryArmed = false
    private var finalizeSpeechCompleteSeen = false
    private var tornDown = false
    private var socketClosed = false
    private var streamIntegrityFailed = false
    private var lastFinalizeRequiresBufferedAudioRecovery = false
    private var intentionalSocketShutdown = false

    var requiresBufferedAudioRecovery: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastFinalizeRequiresBufferedAudioRecovery || streamIntegrityFailed
    }

    init(
        apiKey: String,
        language: String = "en",
        keywords: [String] = [],
        sessionId: String = UUID().uuidString,
        finalizeBudgetOverride: TimeInterval? = nil,
        readinessTimeoutSeconds: TimeInterval = 5,
        messageSender: MessageSender? = nil
    ) {
        self.apiKey = apiKey
        self.language = language
        self.keywords = keywords
        self.sessionId = sessionId
        self.injectedMessageSender = messageSender
        self.readinessTimeoutSeconds = readinessTimeoutSeconds
        self.finalizeBudgetOverride = finalizeBudgetOverride
        // Capture may begin as soon as this session is published, before start().
        let (stream, frames) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(256))
        self.frameStream = stream
        self.frameContinuation = frames
        super.init()
    }

    // MARK: - Lifecycle

    // Lifecycle hooks let offline tests hold start at the readiness boundary.
    func start(
        beforeReadiness: (() -> Void)? = nil,
        afterReadiness: (() async -> Void)? = nil
    ) async throws {
        vlog("muse-stream: starting session")
        stateLock.lock()
        startInvoked = true
        // Preserve conversion/overflow failures from audio captured before start.
        lastFinalizeRequiresBufferedAudioRecovery = false
        intentionalSocketShutdown = false
        stateLock.unlock()
        resetTranscriptState()
        var started = false
        defer { if !started { tearDownSocket() } }

        guard let url = Self.buildSocketURL(sessionId: sessionId) else {
            throw CloudTranscriptionError(provider: .meta, message: "Failed to build streaming URL")
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

        let (readiness, readySignal) = AsyncStream<Void>.makeStream()
        // Install the gated consumer under the finalize lock so finalize can
        // drain the prepared queue even before start resumes from readiness.
        stateLock.lock()
        guard !tornDown, let stream = frameStream else {
            stateLock.unlock()
            tearDownSocket()
            throw CancellationError()
        }
        senderReadyContinuation = readySignal
        senderTask = Task {
            defer { self.releaseFrameQueue() }
            var readyIterator = readiness.makeAsyncIterator()
            guard await readyIterator.next() != nil, !Task.isCancelled else { return }
            for await pcmData in stream {
                do {
                    try await sendFrame(.data(pcmData))
                } catch {
                    self.markStreamIntegrityFailed()
                    vlog("muse-stream: send failed, stopping sender: \(error.localizedDescription)")
                    break
                }
            }
        }
        stateLock.unlock()

        receiveLoopTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }

        task?.resume()

        let handshake = Self.makeHandshakeJSON(
            apiKey: apiKey,
            language: language,
            keywords: keywords
        )
        // The setup send shares the readiness deadline: a stalled connect must
        // not block start() (and the finalize budget behind it) on a send that
        // never returns.
        do {
            try await AsyncDeadline.run(
                seconds: readinessTimeoutSeconds,
                timeoutError: { CloudTranscriptionError(provider: .meta, message: "Timed out waiting for handshake ack") },
                operation: { [self] in
                    try await sendMessage(.string(handshake))
                    beforeReadiness?()
                    try await awaitReady()
                }
            )
        } catch {
            failPendingReady(error)
            throw error
        }

        started = true
        await afterReadiness?()

        vlog("muse-stream: session ready")
    }

    /// Suspends until the ready signal resolves (or returns immediately when it
    /// already did before this call registered).
    private func awaitReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stateLock.lock()
            if let result = readyResult {
                stateLock.unlock()
                continuation.resume(with: result)
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
            streamIntegrityFailed = true
            senderReadyContinuation?.finish()
            senderReadyContinuation = nil
            readyResult = .failure(error)
            readyContinuation = nil
        }
        stateLock.unlock()
        pending?.resume(throwing: error)
    }

    func send(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let continuation = frameContinuation
        stateLock.unlock()
        guard let continuation else { return }
        guard let pcmData = convertToPCM16(buffer) else {
            markStreamIntegrityFailed()
            vlogFromAudioTap(.conversionFailure(.muse, .emptyConversion))
            return
        }
        if case .dropped = continuation.yield(pcmData) {
            markStreamIntegrityFailed()
        }
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
        finalizeSpeechCompleteSeen = false
        stateLock.unlock()
        let finalizeStart = Date()
        let waitSeconds = finalizeBudgetOverride
            ?? min(30.0, max(3.0, recordingDuration * 0.25 + 3.0))
        let finalizeDeadline = finalizeStart.addingTimeInterval(waitSeconds)

        stateLock.lock()
        let framesToFinish = frameContinuation
        frameContinuation = nil
        let senderToDrain = senderTask
        if startInvoked && !readyResolved {
            streamIntegrityFailed = true
            senderReadyContinuation?.finish()
            senderReadyContinuation = nil
        }
        stateLock.unlock()
        framesToFinish?.finish()
        do {
            try await AsyncDeadline.run(
                seconds: max(0, finalizeDeadline.timeIntervalSinceNow),
                timeoutError: { CloudTranscriptionError(provider: .meta, message: "Finalize deadline exceeded while draining audio") },
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
        stateLock.lock()
        senderTask = nil
        stateLock.unlock()

        stateLock.lock()
        let closed = socketClosed
        let integrityFailed = streamIntegrityFailed
        let notReady = startInvoked && !readyResolved
        let accumulatedSoFar = Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
        stateLock.unlock()
        // Released before the handshake ack: the end-of-stream message would
        // reach the socket ahead of any audio, so skip it and recover from the
        // buffered audio.
        if closed || integrityFailed || notReady {
            if closed || notReady { markStreamIntegrityFailed() }
            tearDownSocket()
            vlog("muse-stream: finalize short-circuit (socket/integrity/not-ready), \(accumulatedSoFar.count) chars")
            stateLock.lock()
            resetTranscriptState()
            stateLock.unlock()
            return accumulatedSoFar
        }

        stateLock.lock()
        finalizeSpeechCompleteSeen = false
        stateLock.unlock()
        if task != nil || injectedMessageSender != nil {
            do {
                try await AsyncDeadline.run(
                    seconds: max(0, finalizeDeadline.timeIntervalSinceNow),
                    timeoutError: { CloudTranscriptionError(provider: .meta, message: "Finalize deadline exceeded while ending audio") },
                    operation: { [self] in try await sendMessage(.string(Self.makeEndStreamJSON())) }
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
        let shouldResolveDone = finalizeSpeechCompleteSeen && !doneResolved
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
                        let text = Self.joinedTranscript(
                            segments: self.committedSegments,
                            partial: self.latestPartial
                        )
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
                let text = Self.joinedTranscript(
                    segments: self.committedSegments,
                    partial: self.latestPartial
                )
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

        vlog("muse-stream: finalize took \(String(format: "%.3f", Date().timeIntervalSince(finalizeStart)))s (budget=\(String(format: "%.1f", waitSeconds))s), \(result.count) chars")
        stateLock.lock()
        resetTranscriptState()
        stateLock.unlock()
        return result
    }

    func cancel() {
        let error = CloudTranscriptionError(provider: .meta, message: "cancelled")
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
            senderReadyContinuation?.finish()
            senderReadyContinuation = nil
            readyResult = .failure(error)
            readyContinuation = nil
        }
        let pendingDone = doneResolved ? nil : doneContinuation
        doneResolved = true
        doneContinuation = nil
        let accumulated = Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
        resetTranscriptState()
        stateLock.unlock()
        pendingReady?.resume(throwing: error)
        pendingDone?.resume(returning: accumulated)

        tearDownSocket()
        vlog("muse-stream: cancelled")
    }

    private func resetTranscriptState() {
        committedSegments = []
        latestPartial = ""
        everHadNonEmptyStreamText = false
        finalizeRequested = false
        finalizeBoundaryArmed = false
        finalizeSpeechCompleteSeen = false
    }

    private func releaseFrameQueue() {
        stateLock.lock()
        let frames = frameContinuation
        frameContinuation = nil
        frameStream = nil
        stateLock.unlock()
        frames?.finish()
    }

    private func tearDownSocket() {
        releaseFrameQueue()
        stateLock.lock()
        intentionalSocketShutdown = true
        let senderToCancel = senderTask
        senderTask = nil
        senderReadyContinuation?.finish()
        senderReadyContinuation = nil
        stateLock.unlock()
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        senderToCancel?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
        vlog("muse-stream: socket opened (proto=\(proto ?? "none"))")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        vlog("muse-stream: socket closed (code=\(closeCode.rawValue) reason=\(reasonStr))")
        noteSocketClosed(closeCode: closeCode)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1
        if let ns = error as NSError? {
            vlog("muse-stream: task completed httpStatus=\(status) error=\(ns.domain)#\(ns.code)")
        } else {
            vlog("muse-stream: task completed httpStatus=\(status) error=none")
        }
        stateLock.lock()
        let intentional = intentionalSocketShutdown
        stateLock.unlock()
        if error != nil, !intentional { markStreamIntegrityFailed() }
        failReadyIfPending("task completed httpStatus=\(status)")
    }

    private func failReadyIfPending(_ reason: String) {
        let error = CloudTranscriptionError(provider: .meta, message: reason)
        stateLock.lock()
        socketClosed = true
        let cont = readyResolved ? nil : readyContinuation
        if !readyResolved {
            streamIntegrityFailed = true
            senderReadyContinuation?.finish()
            senderReadyContinuation = nil
            readyResult = .failure(error)
            readyContinuation = nil
        }
        stateLock.unlock()
        cont?.resume(throwing: error)
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
                vlog("muse-stream: receive loop ended: \(ns.domain)#\(ns.code) \(error.localizedDescription)")
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
                if let text = String(data: data, encoding: .utf8) {
                    handleServerEvent(text)
                } else {
                    markStreamIntegrityFailed()
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
            vlog("muse-stream: received unparseable event")
            return
        }

        if let type = json["type"] as? String {
            switch type {
            case "transcript":
                handleTranscriptEvent(json)
            case "speechComplete":
                handleSpeechCompleteEvent(json)
            case "error":
                let message = (json["message"] as? String) ?? (json["error"] as? String) ?? "unknown"
                markStreamIntegrityFailed()
                vlog("muse-stream: server error: \(CloudTranscriptionError.redactedBodyFragment(message))")
            default:
                vlog("muse-stream: unhandled type: \(type)")
            }
            return
        }

        if json["sessionId"] != nil {
            stateLock.lock()
            let continuation = readyResolved ? nil : readyContinuation
            if !readyResolved {
                readyResult = .success(())
                senderReadyContinuation?.yield(())
            }
            senderReadyContinuation?.finish()
            senderReadyContinuation = nil
            readyContinuation = nil
            stateLock.unlock()
            continuation?.resume()
            vlog("muse-stream: handshake ack")
            return
        }

        vlog("muse-stream: received event without type or sessionId")
    }

    private func handleTranscriptEvent(_ json: [String: Any]) {
        let transcript = (json["transcript"] as? String) ?? ""
        let isFinal = (json["final"] as? Bool) ?? false
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        stateLock.lock()
        if isFinal {
            if !trimmed.isEmpty {
                // Replacing the full transcript must not join new final +
                // stale partial (duplicates).
                committedSegments = [trimmed]
                everHadNonEmptyStreamText = true
                latestPartial = ""
            }
        } else if !trimmed.isEmpty {
            latestPartial = transcript
            everHadNonEmptyStreamText = true
        }
        let running = Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
        stateLock.unlock()

        onInterim?(running)
        vlog("muse-stream: transcript final=\(isFinal) (\(trimmed.count) chars)")
    }

    private func handleSpeechCompleteEvent(_ json: [String: Any]) {
        let transcript = (json["transcript"] as? String)
            ?? (json["text"] as? String)
            ?? ""
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        stateLock.lock()
        if !trimmed.isEmpty {
            // Do not join final + stale partial.
            committedSegments = [trimmed]
            latestPartial = ""
            everHadNonEmptyStreamText = true
        }
        let running = Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
        if finalizeRequested { finalizeSpeechCompleteSeen = true }
        let shouldResolveDone = finalizeRequested && finalizeBoundaryArmed && !doneResolved
        let continuation = shouldResolveDone ? doneContinuation : nil
        if shouldResolveDone {
            doneResolved = true
            doneContinuation = nil
        }
        stateLock.unlock()

        continuation?.resume(returning: running)
        onInterim?(running)
        vlog("muse-stream: speechComplete (\(trimmed.count) chars)")
    }

    private func sendMessage(_ message: URLSessionWebSocketTask.Message) async throws {
        if let injectedMessageSender {
            try await injectedMessageSender(message)
            return
        }
        guard let task else {
            throw CloudTranscriptionError(provider: .meta, message: "stream socket unavailable")
        }
        try await task.send(message)
    }

    /// Forces the buffered-audio fallback for this session. The recorder uses it
    /// when it could not prove every captured buffer reached the session.
    func requireBufferedAudioRecovery() { markStreamIntegrityFailed() }

    private func markStreamIntegrityFailed() {
        stateLock.lock()
        streamIntegrityFailed = true
        lastFinalizeRequiresBufferedAudioRecovery = true
        stateLock.unlock()
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

    static func buildSocketURL(sessionId: String) -> URL? {
        var components = URLComponents(string: "wss://api.meta.ai/v1/asr/realtime")!
        components.queryItems = [URLQueryItem(name: "sessionId", value: sessionId)]
        return components.url
    }

    static let maxKeywords = 50
    static let maxKeywordLength = 20

    static func selectKeywords(from entries: [DictionaryEntry]) -> [String] {
        var seen = Set<String>()
        var candidates: [(term: String, fixCount: Int, index: Int)] = []
        for (index, entry) in entries.enumerated() {
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count > 1, term.utf8.count <= maxKeywordLength else { continue }
            let key = term.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            candidates.append((term: term, fixCount: entry.fixCount, index: index))
        }
        candidates.sort { a, b in
            if a.fixCount != b.fixCount { return a.fixCount > b.fixCount }
            return a.index > b.index
        }
        return candidates.prefix(maxKeywords).map { $0.term }
    }

    static func makeHandshakeJSON(apiKey: String, language: String, keywords: [String]) -> String {
        var payload: [String: Any] = [
            "authorization": ["accessToken": "Bearer \(apiKey)"],
            "audioEncoding": "PCM_16KHZ",
            "model": "muse-voice-transcribe-1.0",
            "mode": "PUSH_TO_TALK",
            "partialMode": "CUMULATIVE"
        ]
        if !keywords.isEmpty {
            payload["keywords"] = keywords
        }
        _ = language
        let data = try! JSONSerialization.data(withJSONObject: payload) // swiftlint:disable:this force_try
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func makeEndStreamJSON() -> String {
        let payload: [String: Any] = ["type": "endStream"]
        let data = try! JSONSerialization.data(withJSONObject: payload) // swiftlint:disable:this force_try
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func joinedTranscript(segments: [String], partial: String) -> String {
        let committed = segments.joined(separator: " ")
        let trimmedPartial = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPartial.isEmpty else { return committed }
        guard !committed.isEmpty else { return trimmedPartial }
        if committed.localizedCaseInsensitiveContains(trimmedPartial) { return committed }
        // Cumulative partials restate the whole utterance, so one arriving after
        // a final already begins with the committed text.
        if trimmedPartial.range(of: committed, options: [.caseInsensitive, .anchored]) != nil {
            return trimmedPartial
        }
        return committed + " " + trimmedPartial
    }

    // MARK: - Format conversion

    private func convertToPCM16(_ buffer: AVAudioPCMBuffer) -> Data? {
        let inputFormat = buffer.format

        if converter == nil || converterInputFormat != inputFormat {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                vlogFromAudioTap(.conversionFailure(.muse, .converterCreation))
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
            vlogFromAudioTap(.conversionFailure(.muse, .bufferAllocation))
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
            vlogFromAudioTap(.conversionFailure(.muse, .conversion))
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

enum MuseBatchDecode {
    static func decodeTranscript(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in ["transcript", "text", "output_text"] {
            if let text = json[key] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return text }
            }
        }
        if let result = json["result"] as? [String: Any] {
            for key in ["transcript", "text"] {
                if let text = result[key] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return text }
                }
            }
        }
        return nil
    }
}
