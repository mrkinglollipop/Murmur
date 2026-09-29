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
    private var readyResolved = false

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
        super.init()
    }

    // MARK: - Lifecycle

    func start() async throws {
        vlog("muse-stream: starting session")
        stateLock.lock()
        streamIntegrityFailed = false
        lastFinalizeRequiresBufferedAudioRecovery = false
        intentionalSocketShutdown = false
        stateLock.unlock()
        resetTranscriptState()

        guard let url = Self.buildSocketURL(sessionId: sessionId) else {
            throw CloudTranscriptionError(provider: .meta, message: "Failed to build streaming URL")
        }

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task

        let stream = AsyncStream<Data> { continuation in
            self.stateLock.lock()
            self.frameContinuation = continuation
            self.stateLock.unlock()
        }

        receiveLoopTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }

        task.resume()

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
                    try await awaitReady()
                }
            )
        } catch {
            failPendingReady(error)
            throw error
        }

        senderTask = Task {
            for await pcmData in stream {
                do {
                    try await task.send(.data(pcmData))
                } catch {
                    self.markStreamIntegrityFailed()
                    vlog("muse-stream: send failed, stopping sender: \(error.localizedDescription)")
                    break
                }
            }
        }

        vlog("muse-stream: session ready")
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
        stateLock.unlock()
        guard let continuation else { return }
        guard let pcmData = convertToPCM16(buffer) else {
            markStreamIntegrityFailed()
            vlog("muse-stream: send — conversion produced no data, dropping buffer")
            return
        }
        continuation.yield(pcmData)
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
        stateLock.unlock()
        framesToFinish?.finish()
        let senderToDrain = senderTask
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
        senderTask = nil

        stateLock.lock()
        let closed = socketClosed
        let integrityFailed = streamIntegrityFailed
        let accumulatedSoFar = Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
        stateLock.unlock()
        if closed || integrityFailed {
            if closed { markStreamIntegrityFailed() }
            tearDownSocket()
            vlog("muse-stream: finalize short-circuit (socket/integrity), \(accumulatedSoFar.count) chars")
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
        pendingReady?.resume(throwing: CloudTranscriptionError(provider: .meta, message: "cancelled"))
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
        stateLock.lock()
        socketClosed = true
        let cont = readyResolved ? nil : readyContinuation
        if !readyResolved {
            readyResolved = true
            readyContinuation = nil
        }
        stateLock.unlock()
        cont?.resume(throwing: CloudTranscriptionError(provider: .meta, message: reason))
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
            readyResolved = true
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
        return committed + " " + trimmedPartial
    }

    // MARK: - Format conversion

    private func convertToPCM16(_ buffer: AVAudioPCMBuffer) -> Data? {
        let inputFormat = buffer.format

        if converter == nil || converterInputFormat != inputFormat {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                vlog("muse-stream: failed to create AVAudioConverter for input format")
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
            vlog("muse-stream: failed to allocate output PCM buffer")
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
            vlog("muse-stream: conversion error: \(error?.localizedDescription ?? "unknown")")
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
