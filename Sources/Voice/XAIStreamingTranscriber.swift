import AVFoundation
import Foundation
import os.log

// MARK: - Word-level transcript segment (xAI partial `words[]`)

struct TranscriptWord: Equatable {
    let text: String
    let start: Double
    let end: Double
}

// MARK: - Streaming transcription session (xAI Grok STT WebSocket)

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
///   - Connect to `wss://api.x.ai/v1/stt?sample_rate=16000&encoding=pcm&interim_results=true&language=en&endpointing=5000`
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

    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "xai-streaming")

    private let apiKey: String
    private let language: String

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private var senderTask: Task<Void, Never>?

    /// Feeds captured/converted PCM16 frames from `send(_:)` (audio-tap
    /// thread, synchronous, non-blocking) to the single sender `Task` (which
    /// awaits the actual network write). This is what lets `send(_:)` return
    /// immediately without ever touching `await`.
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

    // MARK: - Shared state (NSLock-guarded)

    private let stateLock = NSLock()
    /// Running transcript built by stitching chunk finals (~3s segments) and
    /// cumulative refinements. Chunk finals from xAI are segment-local, NOT
    /// full-utterance cumulative — replacing this on every `is_final` drops
    /// everything before the last ~3s chunk on long dictations.
    private var confirmedText: String = ""
    /// Most recent (not-yet-final) interim text, for `onInterim`'s running preview.
    private var latestInterim: String = ""
    /// Words committed by timestamp filter — used for boundary dedup only, not text rebuild.
    private var committedWords: [TranscriptWord] = []
    /// Latest `end` time among committed words (seconds).
    private var lastCommittedEnd: Double = 0
    /// Logs one sample of word `start` values per session for timestamp semantics diagnosis.
    private var hasLoggedWordTimestampSample = false

    /// Resolved exactly once by the receive loop when `transcript.created`
    /// arrives. Guarded separately from `readyResolved` below by the same
    /// lock since both are set from the receive-loop task.
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var readyResolved = false

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

    init(apiKey: String, language: String = "en") {
        self.apiKey = apiKey
        self.language = language
        super.init()
    }

    // MARK: - Lifecycle

    /// Opens the socket and awaits `transcript.created`. Throws on
    /// connection/auth failure or if readiness doesn't arrive within ~5s.
    func start() async throws {
        vlog("xai-stream: starting session")
        resetTranscriptState()

        var components = URLComponents(string: "wss://api.x.ai/v1/stt")!
        components.queryItems = [
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "encoding", value: "pcm"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "language", value: language),
            // Max endpointing (5000ms) so brief mid-thought pauses during a long
            // hold don't fire speech_final and start a new utterance segment.
            URLQueryItem(name: "endpointing", value: "5000")
        ]
        guard let url = components.url else {
            throw CloudTranscriptionError(provider: .xai, message: "Failed to build streaming URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task

        // Create the frame stream + continuation BEFORE resuming so frames
        // captured during the connection handshake are BUFFERED (AsyncStream's
        // default policy is unbounded) rather than dropped — the leading audio
        // of a push-to-talk utterance must survive the ~100-300ms socket open.
        // The consumer that DRAINS this stream is started only after
        // `transcript.created` (below): the protocol forbids sending audio
        // before the server is ready, so buffered frames wait, then flush in
        // capture order once the sender starts.
        let stream = AsyncStream<Data> { continuation in
            self.stateLock.lock()
            self.frameContinuation = continuation
            self.stateLock.unlock()
        }

        receiveLoopTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }

        task.resume()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.stateLock.lock()
                    if self.readyResolved {
                        // transcript.created already arrived between resume()
                        // and here (unlikely but possible) — resolve immediately.
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
                    readyResolved = true
                    readyContinuation = nil
                }
                stateLock.unlock()
                pending?.resume(throwing: error)
                group.cancelAll()
                throw error
            }
        }

        // Ready: now safe to stream audio. A single consumer drains the
        // buffered + live frames so network writes stay in capture order even
        // though each `task.send` is async.
        senderTask = Task {
            for await frame in stream {
                do {
                    try await task.send(.data(frame))
                } catch {
                    vlog("xai-stream: send failed, stopping sender: \(error.localizedDescription)")
                    break
                }
            }
        }

        vlog("xai-stream: session ready")
    }

    /// Converts one captured buffer to 16kHz mono PCM16 and enqueues it for
    /// sending. Called from the realtime audio-tap thread — returns quickly
    /// and never blocks on the network. No-op until started and before
    /// finalize/cancel (frameContinuation is nil/finished in those states).
    func send(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let continuation = frameContinuation
        stateLock.unlock()
        guard let continuation else { return }
        guard let pcmData = convertToPCM16(buffer) else {
            vlog("xai-stream: send — conversion produced no data, dropping buffer")
            return
        }
        continuation.yield(pcmData)
    }

    /// Sends `{"type":"audio.done"}`, awaits `transcript.done` (timeout scales
    /// with recording length), returns the final transcript trimmed. On
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

        // Stop accepting new frames, then WAIT for the sender to flush every
        // already-captured frame before signalling end-of-audio — otherwise
        // `audio.done` (sent directly on the task) could overtake the last
        // buffered audio frames and truncate the tail of the utterance.
        stateLock.lock()
        let framesToFinish = frameContinuation
        frameContinuation = nil
        stateLock.unlock()
        framesToFinish?.finish()
        await senderTask?.value
        senderTask = nil

        // If the socket already failed/closed, don't send audio.done or wait on
        // transcript.done — return what we accumulated instead of hanging on
        // the 3s done-timeout (this is the dead-socket path the user hit).
        stateLock.lock()
        let closed = socketClosed
        let confirmedSoFar = mergeConfirmedWithInterim()
        stateLock.unlock()
        if closed {
            tearDownSocket()
            vlog("xai-stream: finalize short-circuit (socket closed), \(confirmedSoFar.count) chars")
            let processed = Self.postProcessTranscript(confirmedSoFar)
            stateLock.lock()
            resetTranscriptState()
            stateLock.unlock()
            return processed
        }

        if let task {
            let doneMessage = "{\"type\":\"audio.done\"}"
            try? await task.send(.string(doneMessage))
        }

        // Long recordings need more time for the server to stitch the full
        // transcript after audio.done — a flat 3s timeout was returning early
        // with only the last chunk on multi-minute dictations.
        let waitSeconds = min(30.0, max(3.0, recordingDuration * 0.25 + 3.0))
        let waitNs = UInt64(waitSeconds * 1_000_000_000)

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

        vlog("xai-stream: finalize took \(String(format: "%.3f", Date().timeIntervalSince(finalizeStart)))s (wait=\(String(format: "%.1f", waitSeconds))s), \(result.count) chars")
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
        // Extract any pending finalize()-side continuation before discarding
        // it — resuming it (instead of dropping it) is what stops cancel()
        // from leaking finalize()'s CheckedContinuation and hanging forever.
        let pendingDone = doneResolved ? nil : doneContinuation
        doneResolved = true
        doneContinuation = nil
        let accumulated = mergeConfirmedWithInterim()
        resetTranscriptState()
        stateLock.unlock()
        pendingReady?.resume(throwing: CloudTranscriptionError(provider: .xai, message: "cancelled"))
        pendingDone?.resume(returning: accumulated)

        tearDownSocket()
        vlog("xai-stream: cancelled")
    }

    private func resetTranscriptState() {
        confirmedText = ""
        latestInterim = ""
        committedWords = []
        lastCommittedEnd = 0
        hasLoggedWordTimestampSample = false
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

    // MARK: - URLSessionWebSocketDelegate (diagnostics + fail-fast)

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
        vlog("xai-stream: socket opened (proto=\(proto ?? "none"))")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        vlog("xai-stream: socket closed (code=\(closeCode.rawValue) reason=\(reasonStr))")
        failReadyIfPending("closed code \(closeCode.rawValue)")
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
        failReadyIfPending("task completed httpStatus=\(status)")
    }

    /// If `start()` is still awaiting `transcript.created`, fail it NOW (rather
    /// than letting it block on the 5s timeout) so `AudioRecorder` falls back
    /// to the file/batch path promptly. No-op once ready has resolved.
    private func failReadyIfPending(_ reason: String) {
        stateLock.lock()
        socketClosed = true
        let cont = readyResolved ? nil : readyContinuation
        if !readyResolved {
            readyResolved = true
            readyContinuation = nil
        }
        stateLock.unlock()
        cont?.resume(throwing: CloudTranscriptionError(provider: .xai, message: reason))
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
                failReadyIfPending("receive: \(ns.domain)#\(ns.code)")
                break
            }

            switch message {
            case .string(let text):
                handleServerEvent(text)
            case .data:
                // Server only ever sends text/JSON events per the documented
                // protocol; ignore any binary frame rather than failing.
                continue
            @unknown default:
                continue
            }
        }
    }

    private func handleServerEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            vlog("xai-stream: received unparseable event")
            return
        }

        switch type {
        case "transcript.created":
            stateLock.lock()
            let continuation = readyResolved ? nil : readyContinuation
            readyResolved = true
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
            if !partialText.isEmpty {
                latestInterim = partialText
                if isFinal {
                    ingestFinalSegment(text: partialText, words: words, speechFinal: speechFinal)
                    if confirmedText.localizedCaseInsensitiveContains(partialText) {
                        latestInterim = ""
                    }
                }
            }
            let running = mergeConfirmedWithInterim()
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
            let resolved = bestResolvedTranscript(doneText: doneText)
            confirmedText = resolved
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
            vlog("xai-stream: server error event: \(CloudTranscriptionError.redactedBodyFragment(message))")

        default:
            vlog("xai-stream: unhandled event type: \(type)")
        }
    }

    /// Combines stitched chunk finals with the in-progress interim tail.
    /// Must be called with `stateLock` held. After chunk stitching,
    /// `latestInterim` may hold unfinalized text for the current segment while
    /// `confirmedText` holds earlier chunks — returning only `confirmedText`
    /// drops that tail.
    private func mergeConfirmedWithInterim() -> String {
        if confirmedText.isEmpty { return latestInterim }
        if latestInterim.isEmpty { return confirmedText }

        let confirmed = confirmedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let interim = latestInterim.trimmingCharacters(in: .whitespacesAndNewlines)

        if interim.caseInsensitiveCompare(confirmed) == .orderedSame { return confirmedText }
        if interim.hasPrefix(confirmed) { return latestInterim }
        if confirmed.hasPrefix(interim) { return confirmedText }
        if confirmed.localizedCaseInsensitiveContains(interim) { return confirmedText }
        if let merged = Self.stitchWithWordOverlap(confirmed, interim),
           merged.count > confirmed.count {
            return merged
        }

        return Self.dedupeStitchArtifacts(Self.mergeStreamingSegment(left: confirmed, right: interim))
    }

    /// Picks the best final transcript between client-stitched text and a
    /// `transcript.done` payload. Must be called with `stateLock` held.
    private func bestResolvedTranscript(doneText: String) -> String {
        let stitched = mergeConfirmedWithInterim()
        let stitchedTrimmed = stitched.trimmingCharacters(in: .whitespacesAndNewlines)
        let doneTrimmed = doneText.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.resolveFinalTranscript(stitched: stitchedTrimmed, done: doneTrimmed)
    }

    /// Incorporates a chunk- or utterance-final partial. Must be called with `stateLock` held.
    private func ingestFinalSegment(text: String, words: [TranscriptWord], speechFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !words.isEmpty, !hasLoggedWordTimestampSample {
            hasLoggedWordTimestampSample = true
            let starts = words.map { String(format: "%.2f", $0.start) }.joined(separator: ",")
            vlog("xai-stream: word timestamp sample starts=[\(starts)] lastCommittedEnd=\(String(format: "%.2f", lastCommittedEnd))")
        }

        if speechFinal, !confirmedText.isEmpty {
            let confirmedLower = confirmedText.lowercased()
            let incomingLower = trimmed.lowercased()
            if incomingLower.contains(confirmedLower), trimmed.count >= confirmedText.count {
                confirmedText = trimmed
                if !words.isEmpty {
                    committedWords = words
                    lastCommittedEnd = words.last?.end ?? lastCommittedEnd
                }
                latestInterim = ""
                return
            }
        }

        let merged = Self.mergeSegmentIntoConfirmed(
            confirmed: confirmedText,
            text: trimmed,
            incomingWords: words,
            committedWords: committedWords,
            lastCommittedEnd: lastCommittedEnd
        )
        confirmedText = merged.confirmedText
        committedWords = merged.committedWords
        lastCommittedEnd = merged.lastCommittedEnd
        confirmedText = Self.dedupeStitchArtifacts(confirmedText)
        if speechFinal {
            latestInterim = ""
        }
    }

    // MARK: - Stitch / dedupe (static, @testable)

    static func parseWords(from json: [String: Any]) -> [TranscriptWord] {
        guard let raw = json["words"] as? [[String: Any]] else { return [] }
        var result: [TranscriptWord] = []
        for dict in raw {
            guard let text = dict["text"] as? String else { continue }
            guard let start = parseJSONDouble(dict["start"]),
                  let end = parseJSONDouble(dict["end"]) else { continue }
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

    static func mergeSegmentIntoConfirmed(
        confirmed: String,
        text incomingText: String,
        incomingWords: [TranscriptWord],
        committedWords: [TranscriptWord],
        lastCommittedEnd: Double
    ) -> (confirmedText: String, committedWords: [TranscriptWord], lastCommittedEnd: Double) {
        var confirmedText = confirmed
        var wordsOut = committedWords
        var endOut = lastCommittedEnd

        guard !incomingText.isEmpty else {
            return (confirmedText, wordsOut, endOut)
        }

        if confirmedText.isEmpty {
            return (incomingText, incomingWords, incomingWords.last?.end ?? 0)
        }

        if incomingText.hasPrefix(confirmedText) {
            confirmedText = incomingText
            if !incomingWords.isEmpty {
                wordsOut = incomingWords
                endOut = incomingWords.last?.end ?? endOut
            }
            return (confirmedText, wordsOut, endOut)
        }

        if confirmedText.hasPrefix(incomingText) {
            return (confirmedText, wordsOut, endOut)
        }

        if confirmedText.count > 0,
           incomingText.range(of: confirmedText, options: [.caseInsensitive]) != nil,
           incomingText.count >= confirmedText.count {
            confirmedText = incomingText
            if !incomingWords.isEmpty {
                wordsOut = incomingWords
                endOut = incomingWords.last?.end ?? endOut
            }
            return (confirmedText, wordsOut, endOut)
        }

        if !incomingWords.isEmpty {
            let tolerance = 0.15
            let newWords = incomingWords.filter {
                endOut > 0 ? $0.start >= endOut : $0.start >= -tolerance
            }
            if !newWords.isEmpty {
                wordsOut.append(contentsOf: newWords)
                endOut = max(endOut, newWords.map(\.end).max() ?? endOut)
            }
        }

        confirmedText = mergeStreamingSegment(left: confirmedText, right: incomingText)
        confirmedText = dedupeStitchArtifacts(confirmedText)
        return (confirmedText, wordsOut, endOut)
    }

    static func mergeStreamingSegment(left: String, right: String) -> String {
        let leftTrim = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let rightTrim = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rightTrim.isEmpty else { return leftTrim }
        guard !leftTrim.isEmpty else { return rightTrim }

        let leftTokens = normalizedEquivalenceTokens(leftTrim)
        let rightTokens = normalizedEquivalenceTokens(rightTrim)

        // Same word sequence, different surface form (punctuation / ITN) → ASR
        // refinement of one segment, not an intentional verbatim repeat.
        if leftTokens == rightTokens {
            if leftTrim.caseInsensitiveCompare(rightTrim) == .orderedSame {
                return leftTrim + (leftTrim.hasSuffix(" ") ? "" : " ") + rightTrim
            }
            return rightTrim
        }

        if let window = nearDuplicateTailWindow(in: leftTrim, right: rightTrim) {
            return dedupeStitchArtifacts(replaceTailWindow(in: leftTrim, dropWordCount: window, with: rightTrim))
        }

        if let merged = stitchWithWordOverlap(leftTrim, rightTrim),
           merged.count > leftTrim.count {
            if let window = nearDuplicateTailWindow(in: merged, right: rightTrim) {
                return dedupeStitchArtifacts(replaceTailWindow(in: merged, dropWordCount: window, with: rightTrim))
            }
            return dedupeStitchArtifacts(merged)
        }

        let appended = leftTrim + (leftTrim.hasSuffix(" ") ? "" : " ") + rightTrim
        return dedupeStitchArtifacts(appended)
    }

    /// Words at the end of `left` to drop when `right` is an ASR refinement of
    /// that trailing passage. Prefers a window close to `right`'s length so
    /// partial 6-word prefix matches do not leave duplicated phrase heads.
    static func nearDuplicateTailWindow(in left: String, right: String) -> Int? {
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
            let tailTokenSet = Set(normalizedTokens(tailStr))
            let diffCount = rightWords.filter { !tailTokenSet.contains($0) }.count
            if diffCount >= 1 { return windowSize }
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
        allowOverlapPath: Bool = true
    ) -> Bool {
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
        let laterTokenSet = Set(laterTokens)
        return earlierTokens.filter { !laterTokenSet.contains($0) }.count >= 1
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

    static func lastSentence(of text: String) -> String {
        splitSentences(text).last ?? text
    }

    static func shouldReplaceTail(left: String, right: String) -> Bool {
        nearDuplicateTailWindow(in: left, right: right) != nil
    }

    static func replaceLastSentence(in text: String, with replacement: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let repl = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        if let window = nearDuplicateTailWindow(in: trimmed, right: repl) {
            return replaceTailWindow(in: trimmed, dropWordCount: window, with: repl)
        }
        var sentences = splitSentences(trimmed)
        guard !sentences.isEmpty else { return repl }
        if sentences.count >= 2 {
            sentences[sentences.count - 1] = repl
            return sentences.joined(separator: " ")
        }
        return trimmed + (trimmed.hasSuffix(" ") ? "" : " ") + repl
    }

    static func replaceOverlappingTail(in left: String, with right: String) -> String {
        if let window = nearDuplicateTailWindow(in: left, right: right) {
            return replaceTailWindow(in: left, dropWordCount: window, with: right)
        }
        let leftWords = left.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let rightWords = right.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !rightWords.isEmpty else { return left }
        guard !leftWords.isEmpty else { return right }

        if let merged = stitchWithWordOverlap(left, right), merged.count > left.count {
            return merged
        }

        return left + (left.hasSuffix(" ") ? "" : " ") + right
    }

    static func collapseNearDuplicateWordTail(_ text: String) -> String {
        var words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= 12 else { return text }

        var changed = true
        while changed {
            changed = false
            let maxWindow = min(40, words.count / 2)
            guard maxWindow >= 6 else { break }

            for window in stride(from: maxWindow, through: 6, by: -1) {
                guard words.count >= window * 2 else { continue }
                let tail = Array(words.suffix(window))
                let prev = Array(words.dropLast(window).suffix(window))
                let tailStr = tail.joined(separator: " ")
                let prevStr = prev.joined(separator: " ")
                let prevNorm = normalizedEquivalenceTokens(prevStr)
                let tailNorm = normalizedEquivalenceTokens(tailStr)

                if prevNorm == tailNorm {
                    if prevStr.caseInsensitiveCompare(tailStr) != .orderedSame {
                        words = Array(words.dropLast(window * 2)) + tail
                        changed = true
                        break
                    }
                    continue
                }

                guard wordOverlapRatio(prevStr, tailStr) >= 0.85 else { continue }

                let tailTokenSet = Set(tailNorm)
                let diffCount = prevNorm.filter { !tailTokenSet.contains($0) }.count
                guard diffCount >= 1 else { continue }

                words = Array(words.dropLast(window * 2)) + tail
                changed = true
                break
            }
        }
        return words.joined(separator: " ")
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
        let stitchedCollapsed = collapseNearDuplicateTail(stitched)

        if done.isEmpty { return stitchedCollapsed }
        if stitched.isEmpty { return done }
        if done.caseInsensitiveCompare(stitched) == .orderedSame { return stitched }

        // Segment-local `transcript.done` payloads are often shorter than the
        // client stitch — never clobber a longer accumulated transcript.
        if done.count < stitchedCollapsed.count { return stitchedCollapsed }

        if hasNearDuplicateTailSentence(stitched) { return done }
        if done.count >= stitchedCollapsed.count { return done }
        return stitchedCollapsed
    }

    static func postProcessTranscript(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var current = dedupeStitchArtifacts(trimmed)
        current = collapseNearDuplicateWordTail(current)
        return dedupeRepeatedContent(current)
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
    static func dedupeRepeatedContent(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= 4 else { return trimmed }

        let half = words.count / 2
        let firstHalf = Array(words.prefix(half))
        let secondHalf = Array(words.suffix(words.count - half))
        if firstHalf.count == secondHalf.count,
           firstHalf.map({ $0.lowercased() }) == secondHalf.map({ $0.lowercased() }),
           !Self.firstHalfEndsSentence(firstHalf) {
            return firstHalf.joined(separator: " ")
        }

        for splitCount in stride(from: words.count / 2, through: max(words.count / 4, 2), by: -1) {
            let prefix = Array(words.prefix(splitCount))
            let suffix = Array(words.suffix(words.count - splitCount))
            guard prefix.count == suffix.count, prefix.count >= 2 else { continue }
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
                vlog("xai-stream: failed to create AVAudioConverter for input format")
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
            vlog("xai-stream: failed to allocate output PCM buffer")
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
            vlog("xai-stream: conversion error: \(error?.localizedDescription ?? "unknown")")
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
