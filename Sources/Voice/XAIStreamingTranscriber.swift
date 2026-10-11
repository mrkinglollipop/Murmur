import AVFoundation
import Foundation
import os.log

// MARK: - Word-level transcript segment (xAI partial `words[]`)

struct TranscriptWord: Equatable {
    let text: String
    let start: Double
    let end: Double
}

// MARK: - Streaming transcription session (xAI Grok Voice Transcribe WebSocket)

/// Push-to-talk streaming speech-to-text client for xAI's Grok streaming STT
/// WebSocket (`wss://api.x.ai/v1/stt`). Unlike `StreamingTranscriber` (which
/// wraps WhisperKit's `AudioStreamTranscriber` and captures the mic itself),
/// this class does NOT own the mic — it is fed `AVAudioPCMBuffer`s by the
/// app's existing `AVAudioEngine` tap (see `AudioRecorder`'s tap install) and
/// only owns the network side: format conversion, framing, and the
/// WebSocket lifecycle. That split keeps mic ownership in exactly one place
/// (`AudioRecorder`) regardless of which transcription backend is active.
///
/// PROTOCOL (xAI docs, implemented verbatim):
///   - Connect to `wss://api.x.ai/v1/stt?model=grok-voice-transcribe-2.0&sample_rate=16000&encoding=pcm&interim_results=true&language=en&endpointing=5000`
///     with `Authorization: Bearer <key>` as an HTTP header on the upgrade
///     request (NOT a query param).
///   - Wait for `{"type":"transcript.created"}` before sending any audio —
///     sending earlier is undefined per the docs, so `start()` gates on it.
///   - Stream raw 16-bit signed little-endian mono PCM at 16kHz as BINARY
///     WebSocket frames. To end the utterance, send a TEXT frame
///     `{"type":"audio.done"}` and then send no more audio.
///   - Server pushes `transcript.partial` with `is_final` and `speech_final`:
///     interim (`is_final=false`), chunk final (~3s locked segment,
///     `is_final=true`, `speech_final=false`), utterance final (pause detected,
///     `speech_final=true`). Chunk finals are segment-local — NOT cumulative —
///     so they must be stitched, not assigned wholesale to `confirmedText`.
///
/// CONCURRENCY DESIGN (the load-bearing part of this class):
///   - `send(_:)` runs on the realtime audio-tap thread and MUST NOT block on
///     the network. It does the (synchronous, cheap) format conversion right
///     there, then hands the resulting `Data` to an `AsyncStream` via
///     `continuation.yield(_:)` — yielding into a stream is non-blocking and
///     preserves call order. A single consumer `Task` drains that stream
///     with `for await frame in stream { await task.send(...) }`, so frames
///     always reach the socket in the order they were captured even though
///     the network write itself is async and may momentarily suspend.
///   - Two one-shot `CheckedContinuation`s bridge the async receive loop back
///     to `start()`/`finalize()`: one resolved by `transcript.created`
///     (raced against a 5s timeout in `start()`), one resolved by
///     `transcript.done` (raced against a duration-scaled timeout in
///     `finalize()`, which falls back to the accumulated stitched text so a
///     slow/dropped final event never loses the utterance). Both are guarded
///     by an NSLock + resolved-once flag.
///   - All shared mutable state (`confirmedText`, the two "already resolved"
///     flags, `latestInterim`) is guarded by a single `NSLock` since it's
///     written from the receive-loop `Task` and read from `send`/`finalize`
///     on other threads/tasks.
final class XAIStreamingTranscriber: NSObject, URLSessionWebSocketDelegate {
    typealias MessageSender = (URLSessionWebSocketTask.Message) async throws -> Void

    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "xai-streaming")

    private let apiKey: String
    private let language: String
    /// Milliseconds of trailing silence before Grok fires `speech_final` and
    /// starts a new utterance. Default is the API max (5000) so a mid-hold
    /// pause does not split the take. Settings Advanced can lower it.
    private let endpointingMs: Int
    private let injectedMessageSender: MessageSender?
    private let finalizeBudgetOverride: TimeInterval?

    static let defaultEndpointingMs = 5000
    static let endpointingMsRange: ClosedRange<Int> = 500...5000

    static func clampEndpointingMs(_ value: Int) -> Int {
        min(max(value, endpointingMsRange.lowerBound), endpointingMsRange.upperBound)
    }

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private var senderTask: Task<Void, Never>?
    /// Opens only on a successful handshake; finishing without a value aborts sending.
    private var senderReadyContinuation: AsyncStream<Void>.Continuation?

    /// Feeds captured/converted PCM16 frames from `send(_:)` (audio-tap
    /// thread, synchronous, non-blocking) to the single sender `Task` (which
    /// awaits the actual network write). This is what lets `send(_:)` return
    /// immediately without ever touching `await`.
    // Bound transport storage even when start is never called. Overflow latches
    // buffered-recording recovery; it must never silently truncate dictation.
    private var frameStream: AsyncStream<Data>?
    private var frameContinuation: AsyncStream<Data>.Continuation?

    /// Lazily built on the first `send(_:)` call once we know the input
    /// buffer's native format. xAI requires 16kHz mono PCM16; the mic tap
    /// format is whatever `AVAudioEngine` negotiates (commonly 44.1/48kHz
    /// float), so a converter is required in the general case.
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    /// Optional live-text callback (confirmed + interim), invoked as partials
    /// arrive. May be called on a background thread — callers marshal to
    /// main themselves if needed (mirrors `StreamingTranscriber.levelCallback`
    /// convention of not assuming a queue).
    var onInterim: ((String) -> Void)?

    /// Whether this session ever received non-empty stream text.
    var hasEverHadNonEmptyStreamText: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return everHadNonEmptyStreamText
    }

    /// Stop-time joined transcript snapshot (confirmed + interim).
    func joinedTranscriptSnapshot() -> String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return mergeConfirmedWithInterim()
    }

    // MARK: - Shared state (NSLock-guarded)

    private let stateLock = NSLock()
    /// Running transcript built by stitching chunk finals (~3s segments) and
    /// cumulative refinements. Chunk finals from xAI are segment-local, NOT
    /// full-utterance cumulative — replacing this on every `is_final` drops
    /// everything before the last ~3s chunk on long dictations.
    private var confirmedText: String = ""
    /// Most recent (not-yet-final) interim text, for `onInterim`'s running preview.
    private var latestInterim: String = ""
    private var latestInterimWords: [TranscriptWord] = []
    private var confirmedSegments: [AudioSegment] = []
    /// Numeric timestamps may restart at an utterance boundary. Only segments
    /// received within the same open utterance share a timestamp origin.
    private var timestampOrigin = 0
    private var lastFinalTimestampOrigin = 0
    /// True once any non-empty interim/confirmed text arrived this session.
    private var everHadNonEmptyStreamText = false
    /// Word provenance retained alongside the original punctuated segment text.
    private var committedWords: [TranscriptWord] = []
    /// Latest `end` time among committed words (seconds).
    private var lastCommittedEnd: Double = 0
    /// Logs one sample of word `start` values per session for timestamp semantics diagnosis.
    private var hasLoggedWordTimestampSample = false

    /// Resolved exactly once by the receive loop when `transcript.created`
    /// arrives. Guarded separately from `readyResolved` below by the same
    /// lock since both are set from the receive-loop task.
    private var readyContinuation: CheckedContinuation<Void, Error>?
    // The first outcome also belongs to waiters registered after it resolves.
    private var readyResult: Result<Void, Error>?
    private var readyResolved: Bool { readyResult != nil }
    /// Set once `start()` has begun. With `readyResolved` still false, the
    /// server has not sent `transcript.created`, so anything sent now would be wasted.
    private var startInvoked = false

    /// Resolved exactly once by the receive loop when `transcript.done`
    /// arrives (or by `finalize()`'s own timeout, which also flips this so
    /// a late `transcript.done` can't attempt a second resume).
    private var doneContinuation: CheckedContinuation<String, Never>?
    private var doneResolved = false

    /// Guards `finalize()`/`cancel()` against being invoked twice.
    private var tornDown = false

    /// Set once the socket fails or closes (handshake error, server close,
    /// receive error). Lets `finalize()` short-circuit instead of hanging on
    /// the 3s done-timeout when there's no live socket to answer.
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
        endpointingMs: Int = XAIStreamingTranscriber.defaultEndpointingMs,
        finalizeBudgetOverride: TimeInterval? = nil,
        messageSender: MessageSender? = nil
    ) {
        self.apiKey = apiKey
        self.language = language
        self.endpointingMs = Self.clampEndpointingMs(endpointingMs)
        self.injectedMessageSender = messageSender
        self.finalizeBudgetOverride = finalizeBudgetOverride
        // Capture may begin as soon as this session is published, before start().
        let (stream, frames) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(256))
        self.frameStream = stream
        self.frameContinuation = frames
        super.init()
    }

    /// Builds the Grok Voice Transcribe WebSocket URL. `endpointing` is clamped to
    /// `endpointingMsRange`; default 5000 is the previous hardcoded value.
    static func buildSocketURL(language: String, endpointingMs: Int = defaultEndpointingMs) -> URL? {
        var components = URLComponents(string: "wss://api.x.ai/v1/stt")!
        components.queryItems = [
            URLQueryItem(name: "model", value: XAITranscriptionService.modelID),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "encoding", value: "pcm"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "endpointing", value: String(clampEndpointingMs(endpointingMs)))
        ]
        return components.url
    }

    // MARK: - Lifecycle

    /// Opens the socket and awaits `transcript.created`. Throws on
    /// connection/auth failure or if readiness doesn't arrive within ~5s.
    // Lifecycle hooks let offline tests hold start at the readiness boundary.
    func start(
        beforeReadiness: (() -> Void)? = nil,
        afterReadiness: (() async -> Void)? = nil
    ) async throws {
        vlog("xai-stream: starting session")
        stateLock.lock()
        startInvoked = true
        // Preserve conversion/overflow failures from audio captured before start.
        lastFinalizeRequiresBufferedAudioRecovery = false
        intentionalSocketShutdown = false
        stateLock.unlock()
        resetTranscriptState()
        var started = false
        defer { if !started { tearDownSocket() } }

        guard let url = Self.buildSocketURL(language: language, endpointingMs: endpointingMs) else {
            throw CloudTranscriptionError(provider: .xai, message: "Failed to build streaming URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // An injected message sender replaces the socket entirely (unit tests):
        // no URLSession is created, so start() never touches the network.
        let task: URLSessionWebSocketTask?
        if injectedMessageSender == nil {
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            let socketTask = session.webSocketTask(with: request)
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

        // Consume the queue prepared before publication. Audio must wait for
        // transcript.created before it can be sent to the server.
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
            for await frame in stream {
                do {
                    try await sendFrame(.data(frame))
                } catch {
                    self.markStreamIntegrityFailed()
                    vlog("xai-stream: send failed, stopping sender: \(error.localizedDescription)")
                    break
                }
            }
        }
        stateLock.unlock()

        receiveLoopTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }

        task?.resume()
        beforeReadiness?()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.stateLock.lock()
                    if let result = self.readyResult {
                        self.stateLock.unlock()
                        continuation.resume(with: result)
                        return
                    }
                    self.readyContinuation = continuation
                    self.stateLock.unlock()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw CloudTranscriptionError(provider: .xai, message: "Timed out waiting for transcript.created")
            }
            // First finisher wins; cancel the other. If the timeout fires,
            // this rethrows and the ready continuation is left set — mark it
            // resolved so a very-late transcript.created can't double-resume.
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                // Timeout (or an error surfaced by the ready task) won the race.
                // If the ready continuation is still pending, RESUME it with the
                // error rather than abandoning it via cancelAll() — a suspended
                // CheckedContinuation is not resumed by task cancellation, so
                // leaving it dangling violates the one-resume contract (leak
                // warning). Guarded by readyResolved so an already-resolved
                // continuation is never resumed twice.
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
                group.cancelAll()
                throw error
            }
        }

        started = true
        await afterReadiness?()

        vlog("xai-stream: session ready")
    }

    /// Converts one captured buffer to 16kHz mono PCM16 and enqueues it for
    /// sending. Called from the realtime audio-tap thread — returns quickly
    /// and never blocks on the network. Buffers before start; no-op after
    /// finalize/cancel (frameContinuation is nil/finished in those states).
    func send(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let continuation = frameContinuation
        stateLock.unlock()
        guard let continuation else { return }
        guard let pcmData = convertToPCM16(buffer) else {
            markStreamIntegrityFailed()
            vlogFromAudioTap(.conversionFailure(.xai, .emptyConversion))
            return
        }
        if case .dropped = continuation.yield(pcmData) {
            markStreamIntegrityFailed()
        }
    }

    /// Drains buffered frames, sends `{"type":"audio.done"}`, and awaits
    /// `transcript.done` within one duration-scaled budget. On
    /// timeout, returns the accumulated stitched text instead of losing the
    /// utterance. Tears the socket down either way.
    func finalize(recordingDuration: TimeInterval = 0) async -> String {
        stateLock.lock()
        if tornDown {
            let text = Self.postProcessTranscript(mergeConfirmedWithInterim())
            stateLock.unlock()
            return text
        }
        tornDown = true
        stateLock.unlock()
        let finalizeStart = Date()
        let waitSeconds = finalizeBudgetOverride
            ?? min(30.0, max(3.0, recordingDuration * 0.25 + 3.0))
        let finalizeDeadline = finalizeStart.addingTimeInterval(waitSeconds)

        // Stop accepting new frames, then WAIT for the sender to flush every
        // already-captured frame before signalling end-of-audio — otherwise
        // `audio.done` (sent directly on the task) could overtake the last
        // buffered audio frames and truncate the tail of the utterance.
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
                timeoutError: { CloudTranscriptionError(provider: .xai, message: "Finalize deadline exceeded while draining audio") },
                operation: { await senderToDrain?.value }
            )
        } catch {
            markStreamIntegrityFailed()
            tearDownSocket()
            stateLock.lock()
            let text = Self.postProcessTranscript(mergeConfirmedWithInterim())
            resetTranscriptState()
            stateLock.unlock()
            return text
        }
        stateLock.lock()
        senderTask = nil
        stateLock.unlock()

        // If the socket already failed/closed, don't send audio.done or wait on
        // transcript.done — return what we accumulated instead of hanging on
        // the 3s done-timeout (this is the dead-socket path the user hit).
        stateLock.lock()
        let closed = socketClosed
        let integrityFailed = streamIntegrityFailed
        let notReady = startInvoked && !readyResolved
        let confirmedSoFar = mergeConfirmedWithInterim()
        stateLock.unlock()
        // Released before transcript.created: audio.done would reach the socket
        // ahead of any audio, so skip it and recover from the buffered audio.
        if closed || integrityFailed || notReady {
            if closed || notReady { markStreamIntegrityFailed() }
            tearDownSocket()
            vlog("xai-stream: finalize short-circuit (socket/integrity/not-ready), \(confirmedSoFar.count) chars")
            let processed = Self.postProcessTranscript(confirmedSoFar)
            stateLock.lock()
            resetTranscriptState()
            stateLock.unlock()
            return processed
        }

        if task != nil || injectedMessageSender != nil {
            let doneMessage = "{\"type\":\"audio.done\"}"
            do {
                try await AsyncDeadline.run(
                    seconds: max(0, finalizeDeadline.timeIntervalSinceNow),
                    timeoutError: { CloudTranscriptionError(provider: .xai, message: "Finalize deadline exceeded while ending audio") },
                    operation: { [self] in try await sendMessage(.string(doneMessage)) }
                )
            } catch {
                markStreamIntegrityFailed()
                tearDownSocket()
                let processed = Self.postProcessTranscript(confirmedSoFar)
                stateLock.lock()
                resetTranscriptState()
                stateLock.unlock()
                return processed
            }
        }

        // Long recordings need more time for the server to stitch the full
        // transcript after audio.done — a flat 3s timeout was returning early
        // with only the last chunk on multi-minute dictations.
        let remainingWait = max(0, finalizeDeadline.timeIntervalSinceNow)
        let waitNs = UInt64(remainingWait * 1_000_000_000)

        let result = await withTaskGroup(of: String?.self) { group -> String in
            group.addTask { [weak self] in
                guard let self else { return nil }
                return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                    self.stateLock.lock()
                    if self.doneResolved {
                        // transcript.done already arrived before we got here.
                        let text = self.mergeConfirmedWithInterim()
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
                    // transcript.done beat the timeout — let that result win.
                    self.stateLock.unlock()
                    return nil
                }
                let pending = self.doneContinuation
                self.lastFinalizeRequiresBufferedAudioRecovery = true
                self.streamIntegrityFailed = true
                let text = self.mergeConfirmedWithInterim()
                self.doneResolved = true
                self.doneContinuation = nil
                self.stateLock.unlock()
                // Resume the still-suspended await-done continuation so it
                // completes instead of leaking when this timeout wins the race.
                pending?.resume(returning: text)
                return text
            }
            // First non-nil result wins (the loser task's own guard makes
            // its contribution nil once the winner already resolved state).
            for await value in group {
                if let value {
                    group.cancelAll()
                    return value
                }
            }
            return ""
        }

        tearDownSocket()

        vlog("xai-stream: finalize took \(String(format: "%.3f", Date().timeIntervalSince(finalizeStart)))s (budget=\(String(format: "%.1f", waitSeconds))s), \(result.count) chars")
        let processed = Self.postProcessTranscript(result)
        stateLock.lock()
        resetTranscriptState()
        stateLock.unlock()
        return processed
    }

    /// Hard stop, no read-back. Cancels the socket and sender.
    /// Resumes any pending `start()`/`finalize()` continuations so callers
    /// cannot hang after cancel (mirrors `ElevenLabsRealtimeTranscriber.cancel`).
    func cancel() {
        let error = CloudTranscriptionError(provider: .xai, message: "cancelled")
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
        // Extract any pending finalize()-side continuation before discarding
        // it — resuming it (instead of dropping it) is what stops cancel()
        // from leaking finalize()'s CheckedContinuation and hanging forever.
        let pendingDone = doneResolved ? nil : doneContinuation
        doneResolved = true
        doneContinuation = nil
        let accumulated = mergeConfirmedWithInterim()
        resetTranscriptState()
        stateLock.unlock()
        pendingReady?.resume(throwing: error)
        pendingDone?.resume(returning: accumulated)

        tearDownSocket()
        vlog("xai-stream: cancelled")
    }

    private func resetTranscriptState() {
        confirmedText = ""
        latestInterim = ""
        latestInterimWords = []
        confirmedSegments = []
        timestampOrigin = 0
        lastFinalTimestampOrigin = 0
        everHadNonEmptyStreamText = false
        committedWords = []
        lastCommittedEnd = 0
        hasLoggedWordTimestampSample = false
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

    // MARK: - URLSessionWebSocketDelegate (diagnostics + fail-fast)

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
        vlog("xai-stream: socket opened (proto=\(proto ?? "none"))")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        vlog("xai-stream: socket closed (code=\(closeCode.rawValue) reason=\(reasonStr))")
        noteSocketClosed(closeCode: closeCode)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // The DEFINITIVE diagnostic for a failed handshake: the HTTP status the
        // server actually returned to the WebSocket upgrade (e.g. 101 success,
        // 401 auth, 403 bot-challenge, 426 upgrade-required) plus the CFNetwork
        // error domain/code. Logged so an in-app failure that no standalone
        // repro reproduces can finally be seen.
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1
        if let ns = error as NSError? {
            vlog("xai-stream: task completed httpStatus=\(status) error=\(ns.domain)#\(ns.code)")
        } else {
            vlog("xai-stream: task completed httpStatus=\(status) error=none")
        }
        stateLock.lock()
        let intentional = intentionalSocketShutdown
        stateLock.unlock()
        if error != nil, !intentional { markStreamIntegrityFailed() }
        failReadyIfPending("task completed httpStatus=\(status)")
    }

    /// If `start()` is still awaiting `transcript.created`, fail it NOW (rather
    /// than letting it block on the 5s timeout) so `AudioRecorder` falls back
    /// to the file/batch path promptly. No-op once ready has resolved.
    private func failReadyIfPending(_ reason: String) {
        let error = CloudTranscriptionError(provider: .xai, message: reason)
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
                vlog("xai-stream: receive loop ended: \(ns.domain)#\(ns.code) \(error.localizedDescription)")
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
            case .data:
                // Server only ever sends text/JSON events per the documented
                // protocol; ignore any binary frame rather than failing.
                markStreamIntegrityFailed()
                continue
            @unknown default:
                continue
            }
        }
    }

    func handleServerEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            markStreamIntegrityFailed()
            vlog("xai-stream: received unparseable event")
            return
        }

        switch type {
        case "transcript.created":
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
            vlog("xai-stream: transcript.created")

        case "transcript.partial":
            let partialText = (json["text"] as? String) ?? ""
            let isFinal = (json["is_final"] as? Bool) ?? false
            let speechFinal = (json["speech_final"] as? Bool) ?? false
            let words = Self.parseWords(from: json)

            stateLock.lock()
            if !partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                latestInterim = partialText
                latestInterimWords = words
                everHadNonEmptyStreamText = true
                if isFinal {
                    ingestFinalSegment(text: partialText, words: words, speechFinal: speechFinal)
                    latestInterim = ""
                    latestInterimWords = []
                }
            }
            let running = mergeConfirmedWithInterim()
            if !running.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                everHadNonEmptyStreamText = true
            }
            stateLock.unlock()

            onInterim?(running)

        case "transcript.done":
            // transcript.done is frequently EMPTY even after a correct
            // transcription — the full text was already delivered via the
            // final partials — so fall back to the stitched confirmed/interim
            // text rather than trusting done's (empty) text and losing
            // everything. When done carries text, prefer it only if it is at
            // least as complete as what we already stitched — a shorter done
            // must not clobber earlier chunk finals.
            let doneText = (json["text"] as? String) ?? ""
            stateLock.lock()
            let resolved = bestResolvedTranscript(doneText: doneText, words: Self.parseWords(from: json))
            confirmedText = resolved
            // Resolution already incorporated or superseded the interim. A
            // waiter installed after done must see the same resolved text.
            latestInterim = ""
            latestInterimWords = []
            if !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                everHadNonEmptyStreamText = true
            }
            let continuation = doneResolved ? nil : doneContinuation
            doneResolved = true
            doneContinuation = nil
            stateLock.unlock()
            continuation?.resume(returning: resolved)
            vlog("xai-stream: transcript.done (done=\(doneText.count) resolved=\(resolved.count) chars)")

        case "error":
            // Per the protocol, an error event does not close the
            // connection — log and keep the receive loop running.
            let message = (json["message"] as? String) ?? "unknown"
            markStreamIntegrityFailed()
            vlog("xai-stream: server error event: \(CloudTranscriptionError.redactedBodyFragment(message))")

        default:
            vlog("xai-stream: unhandled event type: \(type)")
        }
    }

    private func sendMessage(_ message: URLSessionWebSocketTask.Message) async throws {
        if let injectedMessageSender {
            try await injectedMessageSender(message)
            return
        }
        guard let task else {
            throw CloudTranscriptionError(provider: .xai, message: "stream socket unavailable")
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

    /// Combines stitched chunk finals with the in-progress interim tail.
    /// Must be called with `stateLock` held. After chunk stitching,
    /// `latestInterim` may hold unfinalized text for the current segment while
    /// `confirmedText` holds earlier chunks — returning only `confirmedText`
    /// drops that tail.
    /// Internal (not private) for @testable replay tests — see Plan 002.
    func mergeConfirmedWithInterim() -> String {
        if confirmedText.isEmpty { return latestInterim }
        if latestInterim.isEmpty { return confirmedText }

        return Self.mergeSegmentIntoConfirmed(
            confirmed: confirmedText, text: latestInterim,
            incomingWords: latestInterimWords, committedWords: committedWords,
            lastCommittedEnd: lastCommittedEnd, segments: confirmedSegments,
            timestampOrigin: timestampOrigin
        ).confirmedText
    }

    /// Picks the best final transcript between client-stitched text and a
    /// `transcript.done` payload. Must be called with `stateLock` held.
    private func bestResolvedTranscript(doneText: String, words: [TranscriptWord]) -> String {
        if !words.isEmpty, !doneText.isEmpty {
            let timedSnapshot = latestInterim.isEmpty ? confirmedSegments : Self.mergeSegmentIntoConfirmed(
                confirmed: confirmedText, text: latestInterim, incomingWords: latestInterimWords,
                committedWords: committedWords, lastCommittedEnd: lastCommittedEnd,
                segments: confirmedSegments, timestampOrigin: timestampOrigin
            ).segments
            // A session-wide completion cannot prove which locally timed
            // utterance it revises after more than one origin has been seen.
            let origins = Set(timedSnapshot.filter { $0.interval != nil }.compactMap(\.timestampOrigin))
            let doneOrigin = origins.count <= 1 ? origins.first ?? lastFinalTimestampOrigin : nil
            return Self.mergeSegmentIntoConfirmed(
                confirmed: confirmedText, text: doneText, incomingWords: words,
                committedWords: committedWords, lastCommittedEnd: lastCommittedEnd,
                segments: timedSnapshot, timestampOrigin: doneOrigin
            ).confirmedText
        }
        if !doneText.isEmpty, confirmedText.isEmpty
            || (doneText.hasPrefix(confirmedText) && doneText.count > confirmedText.count) { return doneText }
        let stitched = mergeConfirmedWithInterim()
        let stitchedTrimmed = stitched.trimmingCharacters(in: .whitespacesAndNewlines)
        let doneTrimmed = doneText.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.resolveFinalTranscript(stitched: stitchedTrimmed, done: doneTrimmed)
    }

    /// Incorporates a chunk- or utterance-final partial. Must be called with `stateLock` held.
    /// Internal (not private) for @testable replay tests — see Plan 002.
    func ingestFinalSegment(text: String, words: [TranscriptWord], speechFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !words.isEmpty, !hasLoggedWordTimestampSample {
            hasLoggedWordTimestampSample = true
            let starts = words.map { String(format: "%.2f", $0.start) }.joined(separator: ",")
            vlog("xai-stream: word timestamp sample starts=[\(starts)] lastCommittedEnd=\(String(format: "%.2f", lastCommittedEnd))")
        }

        let merged = Self.mergeSegmentIntoConfirmed(
            confirmed: confirmedText,
            text: trimmed,
            incomingWords: words,
            committedWords: committedWords,
            lastCommittedEnd: lastCommittedEnd,
            segments: confirmedSegments, timestampOrigin: timestampOrigin
        )
        lastFinalTimestampOrigin = timestampOrigin
        if speechFinal { timestampOrigin += 1 }
        confirmedText = merged.confirmedText
        committedWords = merged.committedWords
        lastCommittedEnd = merged.lastCommittedEnd
        confirmedSegments = merged.segments
        latestInterim = ""
        latestInterimWords = []
    }

    // MARK: - Stitch / dedupe (static, @testable)

    static func parseWords(from json: [String: Any]) -> [TranscriptWord] {
        guard let raw = json["words"] as? [[String: Any]] else { return [] }
        var result: [TranscriptWord] = []
        for dict in raw {
            guard let text = dict["text"] as? String else { continue }
            guard let start = parseJSONDouble(dict["start"]),
                  let end = parseJSONDouble(dict["end"]),
                  start.isFinite, end.isFinite, start >= 0, end > start else { continue }
            result.append(TranscriptWord(text: text, start: start, end: end))
        }
        return result
    }

    private static func parseJSONDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    struct AudioSegment {
        let text: String
        let words: [TranscriptWord]
        let timestampOrigin: Int?

        var interval: Range<Double>? {
            guard !words.isEmpty,
                  words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start
                    && !XAIStreamingTranscriber.normalizedEquivalenceTokens($0.text).isEmpty }),
                  zip(words, words.dropFirst()).allSatisfy({ $0.end <= $1.start }),
                  words.flatMap({ XAIStreamingTranscriber.normalizedEquivalenceTokens($0.text) })
                    == XAIStreamingTranscriber.normalizedEquivalenceTokens(text),
                  let first = words.first, let last = words.last else { return nil }
            return first.start..<last.end
        }

        /// Preserve the original punctuation outside the revised audio.
        /// Replacement requires word-to-text alignment; a malformed
        /// payload must not authorize deleting an unrelated passage.
        func outside(_ incoming: Range<Double>) -> (before: AudioSegment?, after: AudioSegment?)? {
            guard interval != nil else { return nil }
            let overlapping = words.indices.filter {
                words[$0].start < incoming.upperBound && words[$0].end > incoming.lowerBound
            }
            guard let first = overlapping.first, let last = overlapping.last else { return nil }
            let expression = try! NSRegularExpression(pattern: #"\S+"#)
            let ranges = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap { Range($0.range, in: text) }
            let tokens = ranges.flatMap { range in
                XAIStreamingTranscriber.normalizedEquivalenceTokens(String(text[range])).map { ($0, range) }
            }
            var cursor = 0
            var wordRanges: [Range<String.Index>] = []
            for word in words {
                let expected = XAIStreamingTranscriber.normalizedEquivalenceTokens(word.text)
                guard !expected.isEmpty, cursor + expected.count <= tokens.count,
                      Array(tokens[cursor..<(cursor + expected.count)].map { $0.0 }) == expected else { return nil }
                wordRanges.append(tokens[cursor].1.lowerBound..<tokens[cursor + expected.count - 1].1.upperBound)
                cursor += expected.count
            }
            guard cursor == tokens.count else { return nil }
            if first > 0, wordRanges[first - 1].upperBound > wordRanges[first].lowerBound { return nil }
            if last + 1 < words.count, wordRanges[last].upperBound > wordRanges[last + 1].lowerBound { return nil }
            let before: AudioSegment? = first == 0 ? nil : AudioSegment(
                text: String(text[..<wordRanges[first].lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                words: Array(words[..<first]), timestampOrigin: timestampOrigin)
            let after: AudioSegment? = last + 1 == words.count ? nil : AudioSegment(
                text: String(text[wordRanges[last + 1].lowerBound...]),
                words: Array(words[(last + 1)...]), timestampOrigin: timestampOrigin)
            return (before, after)
        }
    }

    static func mergeSegmentIntoConfirmed(
        confirmed: String,
        text incomingText: String,
        incomingWords: [TranscriptWord],
        committedWords: [TranscriptWord],
        lastCommittedEnd: Double,
        segments: [AudioSegment]? = nil,
        timestampOrigin: Int? = nil
    ) -> (confirmedText: String, committedWords: [TranscriptWord], lastCommittedEnd: Double, segments: [AudioSegment]) {
        var current = segments ?? (confirmed.isEmpty ? [] : [AudioSegment(text: confirmed, words: committedWords, timestampOrigin: timestampOrigin)])
        let textTokens = normalizedEquivalenceTokens(incomingText)
        let freshWords = incomingWords.filter { $0.start >= lastCommittedEnd }
        // Some payloads include prior-audio metadata absent from their text.
        // Ignore it only when the remaining words fully align with the payload;
        // phantom overlap must not authorize replacing confirmed speech.
        let wordsMatchText = incomingWords.flatMap { normalizedEquivalenceTokens($0.text) } == textTokens
        let freshWordsMatchText = freshWords.flatMap { normalizedEquivalenceTokens($0.text) } == textTokens
        let alignedWords = !textTokens.isEmpty && !wordsMatchText && freshWordsMatchText
            ? freshWords : incomingWords
        let incoming = AudioSegment(text: incomingText.trimmingCharacters(in: .whitespacesAndNewlines), words: alignedWords,
                                    timestampOrigin: timestampOrigin)
        if !incoming.text.isEmpty {
            if let interval = incoming.interval {
                var replaced: [AudioSegment] = []
                var inserted = false
                for segment in current {
                    let sharesOrigin = incoming.timestampOrigin != nil && segment.timestampOrigin == incoming.timestampOrigin
                    if sharesOrigin, let oldInterval = segment.interval, oldInterval.overlaps(interval),
                       let outside = segment.outside(interval) {
                        if let before = outside.before { replaced.append(before) }
                        if !inserted { replaced.append(incoming); inserted = true }
                        if let after = outside.after { replaced.append(after) }
                    } else {
                        if sharesOrigin, !inserted, let oldInterval = segment.interval, oldInterval.lowerBound >= interval.upperBound {
                            replaced.append(incoming)
                            inserted = true
                        }
                        replaced.append(segment)
                    }
                }
                if !inserted { replaced.append(incoming) }
                current = replaced
            } else {
                current.append(incoming)
            }
        }
        let words = current.flatMap(\.words)
        return (current.map(\.text).joined(separator: " "), words, words.map(\.end).max() ?? lastCommittedEnd, current)
    }

    static func mergeStreamingSegment(left: String, right: String) -> String {
        let leftTrim = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let rightTrim = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rightTrim.isEmpty else { return leftTrim }
        guard !leftTrim.isEmpty else { return rightTrim }

        // With no audio evidence, a completed sentence is never a replaceable
        // prefix. Only unfinished fragments can use the legacy chunk overlap.
        if leftTrim.contains(where: { ".!?".contains($0) }) {
            return leftTrim + " " + rightTrim
        }
        if rightTrim.range(of: leftTrim, options: [.caseInsensitive]) != nil { return rightTrim }
        if let merged = stitchWithWordOverlap(leftTrim, rightTrim) { return merged }
        return leftTrim + " " + rightTrim
    }

    /// Words at the end of `left` to drop when `right` is an ASR refinement of
    /// that trailing passage. Prefers a window close to `right`'s length so
    /// partial 6-word prefix matches do not leave duplicated phrase heads.
    static func nearDuplicateTailWindow(in left: String, right: String, overlappingAudio: Bool = false) -> Int? {
        guard overlappingAudio else { return nil }
        let rightWords = normalizedTokens(right)
        let rightEquiv = normalizedEquivalenceTokens(right)
        guard rightWords.count >= 5 else { return nil }

        let leftWords = left.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard leftWords.count >= 5 else { return nil }

        // Short clause-extension (5-token stub → longer restart) before the
        // longer-window overlap heuristics, which still require ≥6.
        if isExtensionNearDuplicate(earlier: left, later: right) {
            return leftWords.count
        }

        if normalizedEquivalenceTokens(left) == rightEquiv { return nil }

        // Suffix has identical normalized tokens but different surface text → replace suffix.
        if leftWords.count >= rightWords.count {
            let windowSize = rightWords.count
            let suffix = leftWords.suffix(windowSize).joined(separator: " ")
            if normalizedEquivalenceTokens(suffix) == rightEquiv,
               suffix.caseInsensitiveCompare(right) != .orderedSame {
                return windowSize
            }
        }

        let maxWindow = min(leftWords.count, rightWords.count + 4)
        var candidates: [Int] = []
        for delta in 0...4 {
            let larger = rightWords.count + delta
            let smaller = rightWords.count - delta
            if larger <= maxWindow { candidates.append(larger) }
            // Extension floor is 5; overlap-ratio path still requires ≥6 below.
            if delta > 0, smaller >= 5 { candidates.append(smaller) }
        }

        for windowSize in candidates {
            guard windowSize >= 5, windowSize <= leftWords.count else { continue }
            let tailStr = leftWords.suffix(windowSize).joined(separator: " ")
            // Prefer ordered-prefix extension (allows 5-token mid-hold stubs).
            if isExtensionNearDuplicate(earlier: tailStr, later: right) {
                return windowSize
            }
            // Loose overlap path stays ≥6 to avoid short false positives.
            guard windowSize >= 6 else { continue }
            guard wordOverlapRatio(tailStr, right) >= 0.85 else { continue }
            if isKnownSpellingRefinement(earlier: tailStr, later: right) { return windowSize }
        }
        return nil
    }

    /// ASR restarted a clause and appended tokens (e.g. `Cursor?` → `Cursor into Notion?`).
    /// Earlier A is an ordered prefix of later B; B extends or refines A. Keeps B.
    /// Floor is 5 (not 6): short stubs like "How do I connect Cursor?" are common.
    static func isExtensionNearDuplicate(earlier: String, later: String) -> Bool {
        let aTokens = normalizedTokens(earlier)
        let bTokens = normalizedTokens(later)
        guard aTokens.count >= 5, bTokens.count > aTokens.count else { return false }
        if earlier.caseInsensitiveCompare(later) == .orderedSame { return false }

        // Ordered prefix + strictly longer later = clause restart with appended tokens.
        return Array(bTokens.prefix(aTokens.count)) == aTokens
    }

    static func shouldCollapseNearDuplicateSentencePair(
        earlier: String,
        later: String,
        allowOverlapPath: Bool = true,
        overlappingAudio: Bool = false
    ) -> Bool {
        guard overlappingAudio else { return false }
        if earlier.caseInsensitiveCompare(later) == .orderedSame { return false }

        if isExtensionNearDuplicate(earlier: earlier, later: later) {
            return true
        }

        guard normalizedTokens(later).count >= 6 else { return false }

        if normalizedEquivalenceTokens(earlier) == normalizedEquivalenceTokens(later) {
            return true
        }

        guard allowOverlapPath else { return false }

        guard wordOverlapRatio(earlier, later) >= 0.85 else { return false }
        let earlierTokens = normalizedTokens(earlier)
        let laterTokens = normalizedTokens(later)
        guard laterTokens.count >= earlierTokens.count else { return false }
        return isKnownSpellingRefinement(earlier: earlier, later: later)
    }

    /// Only surface spelling (punctuation, casing, hyphenation) can establish
    /// equivalence here. Nearby words can have opposite meanings, so edit
    /// distance must never authorize dropping the earlier words.
    private static func isKnownSpellingRefinement(earlier: String, later: String) -> Bool {
        earlier.caseInsensitiveCompare(later) != .orderedSame
            && normalizedEquivalenceTokens(earlier) == normalizedEquivalenceTokens(later)
    }

    static func replaceTailWindow(in left: String, dropWordCount: Int, with right: String) -> String {
        let leftWords = left.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard dropWordCount > 0, leftWords.count >= dropWordCount else { return right }
        let prefix = leftWords.dropLast(dropWordCount)
        if prefix.isEmpty { return right }
        return prefix.joined(separator: " ") + " " + right
    }

    /// Sentence-level near-duplicate collapse after chunk stitching.
    static func dedupeStitchArtifacts(_ text: String) -> String {
        var current = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<4 {
            let next = collapseNearDuplicateWordTail(collapseNearDuplicateTail(current))
            if next == current { break }
            current = next
        }
        return current
    }

    static func wordOverlapRatio(_ lhs: String, _ rhs: String) -> Double {
        let leftTokens = Set(normalizedTokens(lhs))
        let rightTokens = normalizedTokens(rhs)
        guard !leftTokens.isEmpty, !rightTokens.isEmpty else { return 0 }
        let overlap = rightTokens.filter { leftTokens.contains($0) }.count
        return Double(overlap) / Double(rightTokens.count)
    }

    static func normalizedTokens(_ text: String) -> [String] {
        let edgePunctuation = CharacterSet(charactersIn: ".!?,\"'`")
            .union(CharacterSet(charactersIn: "\u{201C}\u{201D}\u{2018}\u{2019}"))
        return text.split(whereSeparator: { $0.isWhitespace }).compactMap { rawWord in
            let token = String(rawWord).lowercased().trimmingCharacters(in: edgePunctuation)
            return token.isEmpty ? nil : token
        }
    }

    /// Aggressive ASR equivalence: splits hyphens and strips quotes so
    /// `always-on` and `"always on` compare equal. Used only for full-sequence
    /// refinement detection — not overlap-ratio collapse (avoids false positives).
    static func normalizedEquivalenceTokens(_ text: String) -> [String] {
        let edgePunctuation = CharacterSet(charactersIn: ".!?,\"'`")
            .union(CharacterSet(charactersIn: "\u{201C}\u{201D}\u{2018}\u{2019}"))
        var tokens: [String] = []
        for rawWord in text.split(whereSeparator: { $0.isWhitespace }) {
            let word = String(rawWord).lowercased().trimmingCharacters(in: edgePunctuation)
            guard !word.isEmpty else { continue }
            for part in word.split(separator: "-", omittingEmptySubsequences: true) {
                let token = String(part).trimmingCharacters(in: edgePunctuation)
                if !token.isEmpty { tokens.append(token) }
            }
        }
        return tokens
    }

    static func shouldReplaceTail(left: String, right: String) -> Bool {
        nearDuplicateTailWindow(in: left, right: right) != nil
    }

    static func collapseNearDuplicateWordTail(_ text: String) -> String {
        // A text-only caller cannot establish that repeated words share audio.
        return text
    }

    static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for char in text {
            current.append(char)
            if char == "." || char == "!" || char == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    static func collapseNearDuplicateTail(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var sentences = splitSentences(trimmed)
        guard sentences.count >= 2 else { return collapseNearDuplicateWordTail(trimmed) }

        var changed = true
        while changed {
            changed = false
            var index = 0
            while index < sentences.count - 1 {
                let isLastAdjacentPair = index == sentences.count - 2
                if shouldCollapseNearDuplicateSentencePair(
                    earlier: sentences[index],
                    later: sentences[index + 1],
                    allowOverlapPath: isLastAdjacentPair
                ) {
                    sentences.remove(at: index)
                    changed = true
                    continue
                }
                index += 1
            }
        }

        return collapseNearDuplicateWordTail(sentences.joined(separator: " "))
    }

    static func hasNearDuplicateTailSentence(_ text: String) -> Bool {
        let sentences = splitSentences(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard sentences.count >= 2 else { return false }
        for index in 0..<(sentences.count - 1) {
            let isLastAdjacentPair = index == sentences.count - 2
            if shouldCollapseNearDuplicateSentencePair(
                earlier: sentences[index],
                later: sentences[index + 1],
                allowOverlapPath: isLastAdjacentPair
            ) {
                return true
            }
        }
        return false
    }

    static func resolveFinalTranscript(stitched: String, done: String) -> String {
        let accumulated = stitched.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = done.trimmingCharacters(in: .whitespacesAndNewlines)
        if accumulated.isEmpty { return final }
        // An untimed done can extend the known transcript, but its length or
        // similarity cannot establish permission to replace confirmed speech.
        if final.hasPrefix(accumulated) { return final }
        return accumulated
    }

    static func postProcessTranscript(_ text: String) -> String {
        // Replacement happens during ingestion, while audio provenance exists.
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Joins `left` and `right` when they share trailing/leading words
    /// (chunk boundary overlap). Returns nil when segments are disjoint.
    static func stitchWithWordOverlap(_ left: String, _ right: String) -> String? {
        let leftWords = left.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let rightWords = right.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !leftWords.isEmpty, !rightWords.isEmpty else { return nil }

        let maxOverlap = min(leftWords.count, rightWords.count)
        for overlap in stride(from: maxOverlap, through: 1, by: -1) {
            if leftWords.suffix(overlap).elementsEqual(rightWords.prefix(overlap), by: {
                $0.caseInsensitiveCompare($1) == .orderedSame
            }) {
                return (leftWords + rightWords.dropFirst(overlap)).joined(separator: " ")
            }
        }
        return nil
    }

    /// Collapses a transcript that was accidentally duplicated end-to-end
    /// (common when cumulative chunk finals get appended onto stitched text).
    /// Requires word-boundary-aligned halves (split on whitespace, compare
    /// word arrays) so partial character matches don't false-positive.
    ///
    /// Each repeated half must be at least `minRepeatedHalfWords` long: shorter
    /// repeats ("no no no no", "I think so I think so") are ordinary speech,
    /// while a stitching artifact duplicates a whole chunk.
    static let minRepeatedHalfWords = 6

    static func dedupeRepeatedContent(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= minRepeatedHalfWords * 2 else { return trimmed }

        let half = words.count / 2
        let firstHalf = Array(words.prefix(half))
        let secondHalf = Array(words.suffix(words.count - half))
        if firstHalf.count == secondHalf.count,
           firstHalf.map({ $0.lowercased() }) == secondHalf.map({ $0.lowercased() }),
           !Self.firstHalfEndsSentence(firstHalf) {
            return firstHalf.joined(separator: " ")
        }

        for splitCount in stride(from: words.count / 2, through: max(words.count / 4, minRepeatedHalfWords), by: -1) {
            let prefix = Array(words.prefix(splitCount))
            let suffix = Array(words.suffix(words.count - splitCount))
            guard prefix.count == suffix.count, prefix.count >= minRepeatedHalfWords else { continue }
            if prefix.map({ $0.lowercased() }) == suffix.map({ $0.lowercased() }),
               !Self.firstHalfEndsSentence(prefix) {
                return prefix.joined(separator: " ")
            }
        }

        return trimmed
    }

    /// True when the first duplicated half ends on sentence punctuation —
    /// a speaker repeating a full sentence verbatim should not be collapsed.
    private static func firstHalfEndsSentence(_ words: [String]) -> Bool {
        guard let last = words.last?.last else { return false }
        return last == "." || last == "!" || last == "?"
    }

    // MARK: - Format conversion

    /// Converts `buffer` (in whatever format the mic tap negotiated) to
    /// 16kHz mono PCM16 and returns the raw interleaved bytes. Builds the
    /// converter lazily from the first buffer's format since the tap's
    /// format is not known until capture starts. Runs on the calling
    /// (audio-tap) thread — cheap enough per the house convention already
    /// established by `StreamingTranscriber`'s per-buffer RMS computation.
    private func convertToPCM16(_ buffer: AVAudioPCMBuffer) -> Data? {
        let inputFormat = buffer.format

        if converter == nil || converterInputFormat != inputFormat {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                vlogFromAudioTap(.conversionFailure(.xai, .converterCreation))
                return nil
            }
            converter = newConverter
            converterInputFormat = inputFormat
        }
        guard let converter else { return nil }

        // Worst case (no sample-rate reduction) the output has as many
        // frames as the input; oversize slightly as headroom for rounding.
        let capacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate).rounded(.up) + 16
        )
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            vlogFromAudioTap(.conversionFailure(.xai, .bufferAllocation))
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
            vlogFromAudioTap(.conversionFailure(.xai, .conversion))
            return nil
        }
        guard let int16Data = outputBuffer.int16ChannelData else {
            return nil
        }

        // Interleaved mono → channel 0 holds all samples.
        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else { return nil }
        return Data(bytes: int16Data[0], count: frameCount * MemoryLayout<Int16>.size)
    }
}
