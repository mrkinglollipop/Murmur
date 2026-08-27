import AVFoundation
import Foundation
import os.log

// MARK: - Streaming transcription session (Gemini 3.5 Transcribe Live WebSocket)

/// Push-to-talk streaming speech-to-text client for Google's
/// `gemini-3.5-transcribe-live` BidiGenerateContent WebSocket.
/// Structurally modeled on `ElevenLabsRealtimeTranscriber`.
final class GeminiLiveTranscriber: NSObject, URLSessionWebSocketDelegate {

    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "gemini-streaming")

    private let apiKey: String
    private let language: String
    private let smartMode: Bool
    private let vocabulary: [String]
    private let liveOptions: GeminiLiveOptions

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

    private var doneContinuation: CheckedContinuation<String, Never>?
    private var doneResolved = false

    private var finalizeRequested = false
    private var tornDown = false
    private var socketClosed = false

    private var sessionStartTime: Date?
    private var sessionCapReached = false
    private var activityStartSent = false

    static let sessionCapSeconds: TimeInterval = 580

    init(
        apiKey: String,
        language: String = "en",
        smartMode: Bool = true,
        vocabulary: [String] = [],
        liveOptions: GeminiLiveOptions = .defaults
    ) {
        self.apiKey = apiKey
        self.language = language
        self.smartMode = smartMode
        self.vocabulary = vocabulary
        self.liveOptions = liveOptions.clamped()
        super.init()
    }

    // MARK: - Lifecycle

    func start() async throws {
        vlog("gemini-stream: starting session")
        resetTranscriptState()

        guard let url = Self.buildSocketURL(apiKey: apiKey) else {
            throw CloudTranscriptionError(provider: .gemini, message: "Failed to build streaming URL")
        }

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        self.sessionStartTime = Date()

        let stream = AsyncStream<String> { continuation in
            self.stateLock.lock()
            self.frameContinuation = continuation
            self.stateLock.unlock()
        }

        receiveLoopTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }

        task.resume()

        let setupFrame = GeminiLiveOptions.makeSetupMessageJSON(
            language: language,
            smartMode: smartMode,
            vocabulary: vocabulary,
            options: liveOptions
        )
        try await task.send(.string(setupFrame))

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.stateLock.lock()
                    if self.readyResolved {
                        self.stateLock.unlock()
                        continuation.resume()
                        return
                    }
                    self.readyContinuation = continuation
                    self.stateLock.unlock()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw CloudTranscriptionError(provider: .gemini, message: "Timed out waiting for setupComplete")
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                stateLock.lock()
                let pending = readyResolved ? nil : readyContinuation
                if !readyResolved {
                    readyResolved = true
                    readyContinuation = nil
                }
                stateLock.unlock()
                pending?.resume(throwing: error)
                group.cancelAll()
                throw error
            }
        }

        senderTask = Task { [weak self] in
            guard let self else { return }
            if self.liveOptions.vadMode == .manual, !self.activityStartSent {
                if let task = self.task {
                    let startFrame = GeminiLiveOptions.makeActivityStartFrameJSON()
                    try? await task.send(.string(startFrame))
                    self.stateLock.lock()
                    self.activityStartSent = true
                    self.stateLock.unlock()
                }
            }
            for await frame in stream {
                do {
                    try await task.send(.string(frame))
                } catch {
                    let ns = error as NSError
                    vlog("gemini-stream: send failed, stopping sender: \(ns.domain)#\(ns.code)")
                    break
                }
            }
        }

        vlog("gemini-stream: session ready")
    }

    func send(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let continuation = frameContinuation
        let capReached = sessionCapReached
        if let start = sessionStartTime, !capReached {
            if Date().timeIntervalSince(start) > Self.sessionCapSeconds {
                sessionCapReached = true
                vlog("gemini-stream: 10min cap")
            }
        }
        let blocked = capReached || sessionCapReached
        stateLock.unlock()
        guard let continuation, !blocked else { return }
        guard let pcmData = convertToPCM16(buffer) else {
            vlog("gemini-stream: send — conversion produced no data, dropping buffer")
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
        let capReached = sessionCapReached
        stateLock.unlock()
        let finalizeStart = Date()

        stateLock.lock()
        let framesToFinish = frameContinuation
        frameContinuation = nil
        stateLock.unlock()
        framesToFinish?.finish()
        await senderTask?.value
        senderTask = nil

        stateLock.lock()
        let closed = socketClosed
        let accumulatedSoFar = Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
        stateLock.unlock()

        if capReached {
            tearDownSocket()
            vlog("gemini-stream: finalize short-circuit (10min cap), 0 chars forced")
            stateLock.lock()
            resetTranscriptState()
            stateLock.unlock()
            return ""
        }

        if closed {
            tearDownSocket()
            vlog("gemini-stream: finalize short-circuit (socket closed), \(accumulatedSoFar.count) chars")
            stateLock.lock()
            resetTranscriptState()
            stateLock.unlock()
            return accumulatedSoFar
        }

        if let task {
            switch liveOptions.vadMode {
            case .manual:
                let endFrame = GeminiLiveOptions.makeActivityEndFrameJSON()
                try? await task.send(.string(endFrame))
            case .hybrid:
                let endFrame = GeminiLiveOptions.makeAudioStreamEndFrameJSON()
                try? await task.send(.string(endFrame))
            case .automatic:
                break
            }
        }

        let waitSeconds = min(30.0, max(3.0, recordingDuration * 0.25 + 3.0))
        let waitNs = UInt64(waitSeconds * 1_000_000_000)

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

        vlog("gemini-stream: finalize took \(String(format: "%.3f", Date().timeIntervalSince(finalizeStart)))s (wait=\(String(format: "%.1f", waitSeconds))s), \(result.count) chars")
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
        activityStartSent = false
        sessionCapReached = false
        sessionStartTime = nil
    }

    private func tearDownSocket() {
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
        failReadyIfPending("closed code \(closeCode.rawValue)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1
        if let ns = error as NSError? {
            vlog("gemini-stream: task completed httpStatus=\(status) error=\(ns.domain)#\(ns.code)")
        } else {
            vlog("gemini-stream: task completed httpStatus=\(status) error=none")
        }
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
                failReadyIfPending("receive: \(ns.domain)#\(ns.code)")
                break
            }

            switch message {
            case .string(let text):
                handleServerEvent(text)
            case .data:
                continue
            @unknown default:
                continue
            }
        }
    }

    func handleServerEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
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
            latestPartial = ""
        }
        let running = Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
        let shouldResolveDone = finalizeRequested && !doneResolved
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

    // MARK: - Static helpers (@testable)

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

    // MARK: - Format conversion

    private func convertToPCM16(_ buffer: AVAudioPCMBuffer) -> Data? {
        let inputFormat = buffer.format

        if converter == nil || converterInputFormat != inputFormat {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                vlog("gemini-stream: failed to create AVAudioConverter for input format")
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
            vlog("gemini-stream: failed to allocate output PCM buffer")
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
            vlog("gemini-stream: conversion error: \(error?.localizedDescription ?? "unknown")")
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
        return nil
    }
}
