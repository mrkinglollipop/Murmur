import AVFoundation
import Foundation
import os.log

// MARK: - Streaming transcription session (ElevenLabs Scribe v2 Realtime WebSocket)

/// Push-to-talk streaming speech-to-text client for ElevenLabs' Scribe v2
/// Realtime WebSocket (`wss://api.elevenlabs.io/v1/speech-to-text/realtime`).
/// Structurally modeled on `XAIStreamingTranscriber` (same mic-ownership
/// split, same non-blocking `send(_:)` + `AsyncStream` sender pattern, same
/// ready/done `CheckedContinuation` bridge) but SIMPLER: Scribe RT's
/// `committed_transcript` events are sequential, non-overlapping segments (no
/// segment-local chunk finals to stitch), so the accumulated transcript is
/// just committed segments joined in arrival order — none of xAI's
/// stitch/word-overlap/dedupe machinery is needed here.
///
/// PROTOCOL (ElevenLabs docs, verified 2026-07-09 against
/// https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime):
///   - Connect to `wss://api.elevenlabs.io/v1/speech-to-text/realtime?model_id=scribe_v2_realtime&audio_format=pcm_16000&language_code=<lang>`
///     with header `xi-api-key: <key>` (NOT bearer, NOT a query param).
///   - Server sends `{"message_type":"session_started",...}` once the socket
///     is ready to accept audio — `start()` gates on this the same way xAI's
///     `start()` gates on `transcript.created`.
///   - Audio is sent as TEXT (JSON) WebSocket frames, NOT binary — every
///     frame is `{"message_type":"input_audio_chunk","audio_base_64":"<b64
///     PCM16 mono 16kHz>","commit":<bool>,"sample_rate":16000}`. All four
///     fields are REQUIRED by the schema on every frame (`commit` is not
///     optional-omit). Frames stream with `commit:false`; the final frame
///     (at `finalize()`) sets `commit:true` — with default (manual) commit
///     strategy that is what triggers the server to flush its buffer.
///   - Server pushes `partial_transcript` (`text`, in-progress, may be
///     revised) during the hold, and `committed_transcript` (`text`) each
///     time a commit is processed — normally exactly one, right after the
///     final `commit:true` frame, but the accumulator handles more than one
///     defensively (e.g. if VAD auto-commit is ever turned on server-side).
///   - Non-fatal server errors arrive as distinct message types
///     (`input_error`, `transcriber_error`, `chunk_size_exceeded`, etc.) —
///     logged and otherwise ignored, mirroring xAI's `"error"` handling.
///   - Two further query params are built by `buildSocketURL`: `no_verbatim`
///     (server-side filler-word/disfluency removal) and repeated `keyterms`
///     (vocabulary bias from the learned dictionary).
///
/// CONCURRENCY DESIGN: identical shape to `XAIStreamingTranscriber` — see
/// that file's header for the full rationale. Summary: `send(_:)` runs on
/// the audio-tap thread, converts synchronously, and yields into an
/// `AsyncStream`; a single sender `Task` drains it in order onto the socket.
/// Two one-shot `CheckedContinuation`s bridge `start()`/`finalize()` to the
/// receive loop (`session_started` / final `committed_transcript`), guarded
/// by an `NSLock` + resolved-once flags exactly as xAI does.
final class ElevenLabsRealtimeTranscriber: NSObject, URLSessionWebSocketDelegate {

    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "elevenlabs-streaming")

    private let apiKey: String
    private let language: String
    /// Sent as `no_verbatim` on the socket URL — server-side filler-word /
    /// disfluency removal (plan 014). Driven by `SettingsStore.removeFillerWords`.
    private let noVerbatim: Bool
    /// Sent as repeated `keyterms` query params — biases Scribe RT toward the
    /// user's learned-dictionary vocabulary (plan 014). Canonical terms only;
    /// selection/cap/dedup happens in `selectKeyterms(from:)` before this
    /// reaches the initializer.
    private let keyterms: [String]

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private var senderTask: Task<Void, Never>?

    /// Feeds ready-to-send JSON `input_audio_chunk` frames (already encoded
    /// as a string) from `send(_:)` (audio-tap thread, synchronous,
    /// non-blocking) to the single sender `Task`.
    private var frameContinuation: AsyncStream<String>.Continuation?

    /// Lazily built on the first `send(_:)` call once the input buffer's
    /// native format is known. Same 16kHz mono PCM16 target as xAI.
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    /// Optional live-text callback (committed-so-far + latest partial),
    /// invoked as partials arrive. May be called on a background thread.
    var onInterim: ((String) -> Void)?

    // MARK: - Shared state (NSLock-guarded)

    private let stateLock = NSLock()
    /// Committed segments in arrival order. Scribe RT's `committed_transcript`
    /// text is already the full committed passage for that commit — no
    /// overlap with prior segments — so joining in order is correct.
    private var committedSegments: [String] = []
    /// Most recent (not-yet-committed) partial text, for `onInterim`'s preview.
    private var latestPartial: String = ""

    /// Resolved exactly once by the receive loop when `session_started` arrives.
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var readyResolved = false

    /// Resolved exactly once by the receive loop when the (final) committed
    /// transcript arrives after `finalize()` sends its `commit:true` frame.
    private var doneContinuation: CheckedContinuation<String, Never>?
    private var doneResolved = false

    /// True once `finalize()` has requested end-of-session. Mid-hold
    /// `committed_transcript` events only accumulate; they must not complete
    /// `finalize()`'s waiter (that was early-doneResolved).
    private var finalizeRequested = false

    /// Set once `finalize()`/`cancel()` has run, guarding against double-invoke.
    private var tornDown = false

    /// Set once the socket fails or closes, so `finalize()` can short-circuit
    /// instead of hanging on the done-timeout.
    private var socketClosed = false

    init(apiKey: String, language: String = "en", noVerbatim: Bool = false, keyterms: [String] = []) {
        self.apiKey = apiKey
        self.language = language
        self.noVerbatim = noVerbatim
        self.keyterms = keyterms
        super.init()
    }

    // MARK: - Lifecycle

    /// Opens the socket and awaits `session_started`. Throws on
    /// connection/auth failure or if readiness doesn't arrive within ~5s.
    func start() async throws {
        vlog("elevenlabs-stream: starting session")
        resetTranscriptState()

        guard let url = Self.buildSocketURL(language: language, noVerbatim: noVerbatim, keyterms: keyterms) else {
            throw CloudTranscriptionError(provider: .elevenLabs, message: "Failed to build streaming URL")
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key") // NOT bearer

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task

        // Buffer frames captured during the handshake (unbounded AsyncStream)
        // so the leading audio of the utterance survives socket-open latency;
        // the sender only starts draining once `session_started` arrives.
        let stream = AsyncStream<String> { continuation in
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
                throw CloudTranscriptionError(provider: .elevenLabs, message: "Timed out waiting for session_started")
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

        // Ready: safe to stream audio. Single consumer keeps writes ordered
        // even though each `task.send` is itself async.
        senderTask = Task {
            for await frame in stream {
                do {
                    try await task.send(.string(frame))
                } catch {
                    vlog("elevenlabs-stream: send failed, stopping sender: \(error.localizedDescription)")
                    break
                }
            }
        }

        vlog("elevenlabs-stream: session ready")
    }

    /// Converts one captured buffer to 16kHz mono PCM16, base64-encodes it,
    /// and enqueues the JSON frame payload for sending. Called from the
    /// realtime audio-tap thread — returns quickly, never blocks on the
    /// network. No-op until started and before finalize/cancel.
    func send(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let continuation = frameContinuation
        stateLock.unlock()
        guard let continuation else { return }
        guard let pcmData = convertToPCM16(buffer) else {
            vlog("elevenlabs-stream: send — conversion produced no data, dropping buffer")
            return
        }
        continuation.yield(Self.makeInputAudioChunkFrame(pcmData: pcmData, commit: false))
    }

    /// Sends a final `commit:true` frame (with an empty audio payload — all
    /// captured audio was already streamed via `send(_:)`), awaits the final
    /// `committed_transcript` (timeout scales with recording length), and
    /// returns the joined committed transcript. Tears the socket down either way.
    func finalize(recordingDuration: TimeInterval = 0) async -> String {
        stateLock.lock()
        if tornDown {
            let text = Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
            stateLock.unlock()
            return text
        }
        tornDown = true
        finalizeRequested = true
        stateLock.unlock()
        let finalizeStart = Date()

        // Stop accepting new frames, then wait for the sender to flush every
        // already-captured frame before sending the commit frame — otherwise
        // the commit could overtake buffered audio and truncate the tail.
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
        if closed {
            tearDownSocket()
            vlog("elevenlabs-stream: finalize short-circuit (socket closed), \(accumulatedSoFar.count) chars")
            stateLock.lock()
            resetTranscriptState()
            stateLock.unlock()
            return accumulatedSoFar
        }

        if let task {
            let commitFrame = Self.makeInputAudioChunkFrame(pcmData: Data(), commit: true)
            try? await task.send(.string(commitFrame))
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

        vlog("elevenlabs-stream: finalize took \(String(format: "%.3f", Date().timeIntervalSince(finalizeStart)))s (wait=\(String(format: "%.1f", waitSeconds))s), \(result.count) chars")
        stateLock.lock()
        resetTranscriptState()
        stateLock.unlock()
        return result
    }

    /// Hard stop, no read-back. Cancels the socket and sender.
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
        // Resume pending start() with cancel error so callers cannot hang
        // (mirrors XAIStreamingTranscriber.cancel).
        let pendingReady = readyResolved ? nil : readyContinuation
        if !readyResolved {
            readyResolved = true
            readyContinuation = nil
        }
        // Extract any pending finalize()-side continuation before discarding
        // it — resuming it (instead of dropping it) is what stops a
        // start-failure cancel() from leaking finalize()'s CheckedContinuation
        // and hanging it forever behind its own bounded timeout.
        let pendingDone = doneResolved ? nil : doneContinuation
        doneResolved = true
        doneContinuation = nil
        let accumulated = Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
        resetTranscriptState()
        stateLock.unlock()
        pendingReady?.resume(throwing: CloudTranscriptionError(provider: .elevenLabs, message: "cancelled"))
        pendingDone?.resume(returning: accumulated)

        tearDownSocket()
        vlog("elevenlabs-stream: cancelled")
    }

    private func resetTranscriptState() {
        committedSegments = []
        latestPartial = ""
        finalizeRequested = false
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
        vlog("elevenlabs-stream: socket opened (proto=\(proto ?? "none"))")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        vlog("elevenlabs-stream: socket closed (code=\(closeCode.rawValue) reason=\(reasonStr))")
        failReadyIfPending("closed code \(closeCode.rawValue)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1
        if let ns = error as NSError? {
            vlog("elevenlabs-stream: task completed httpStatus=\(status) error=\(ns.domain)#\(ns.code)")
        } else {
            vlog("elevenlabs-stream: task completed httpStatus=\(status) error=none")
        }
        failReadyIfPending("task completed httpStatus=\(status)")
    }

    /// If `start()` is still awaiting `session_started`, fail it now rather
    /// than let it block on the 5s timeout, so the caller falls back to the
    /// file/batch path promptly. No-op once ready has resolved.
    private func failReadyIfPending(_ reason: String) {
        stateLock.lock()
        socketClosed = true
        let cont = readyResolved ? nil : readyContinuation
        if !readyResolved {
            readyResolved = true
            readyContinuation = nil
        }
        stateLock.unlock()
        cont?.resume(throwing: CloudTranscriptionError(provider: .elevenLabs, message: reason))
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
                vlog("elevenlabs-stream: receive loop ended: \(ns.domain)#\(ns.code) \(error.localizedDescription)")
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
              let messageType = json["message_type"] as? String
        else {
            vlog("elevenlabs-stream: received unparseable event")
            return
        }

        switch messageType {
        case "session_started":
            stateLock.lock()
            let continuation = readyResolved ? nil : readyContinuation
            readyResolved = true
            readyContinuation = nil
            stateLock.unlock()
            continuation?.resume()
            vlog("elevenlabs-stream: session_started")

        case "partial_transcript":
            let partialText = (json["text"] as? String) ?? ""
            stateLock.lock()
            latestPartial = partialText
            let running = Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
            stateLock.unlock()
            onInterim?(running)

        case "committed_transcript":
            let committedText = (json["text"] as? String) ?? ""
            stateLock.lock()
            let trimmed = committedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                committedSegments.append(trimmed)
            }
            latestPartial = ""
            let running = Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
            // Only complete finalize()'s waiter after finalize requested
            // (post-release commit:true). Mid-hold commits accumulate only.
            let shouldResolveDone = finalizeRequested && !doneResolved
            let continuation = shouldResolveDone ? doneContinuation : nil
            if shouldResolveDone {
                doneResolved = true
                doneContinuation = nil
            }
            stateLock.unlock()
            continuation?.resume(returning: running)
            onInterim?(running)
            vlog("elevenlabs-stream: committed_transcript (\(trimmed.count) chars) finalizeRequested=\(finalizeRequested)")

        case "committed_transcript_with_timestamps":
            // Word-timestamp variant is opt-in (`include_timestamps`) and not
            // requested here — ignore if the server ever sends it anyway.
            break

        case "input_error", "transcriber_error", "chunk_size_exceeded",
             "queue_overflow", "resource_exhausted", "session_time_limit_exceeded",
             "insufficient_audio_activity":
            // Per the protocol these do not necessarily close the connection —
            // log and keep the receive loop running, mirroring xAI's "error".
            let message = (json["error"] as? String) ?? "unknown"
            vlog("elevenlabs-stream: server error event [\(messageType)]: \(CloudTranscriptionError.redactedBodyFragment(message))")

        default:
            vlog("elevenlabs-stream: unhandled message_type: \(messageType)")
        }
    }

    // MARK: - Socket URL building (static, @testable)

    /// Builds the realtime WebSocket URL, including `no_verbatim` (always
    /// present, reflecting the setting) and `keyterms` (only when non-empty).
    ///
    /// `keyterms` MUST be sent as REPEATED query params (`keyterms=a&keyterms=b`),
    /// never comma-joined: probed live against the socket on 2026-07-09, a
    /// comma-joined value is parsed as ONE keyterm and trips the server's
    /// per-term length limit. The repeated form is echoed back correctly in
    /// the `session_started` frame's `config.keyterms` array.
    ///
    /// Violating the server's keyterm limits (see `maxKeyterms` /
    /// `maxKeytermLength`) makes it answer the handshake with
    /// `invalid_request` instead of `session_started`, so `start()` times out
    /// and the whole dictation fails — `selectKeyterms(from:)` is what keeps
    /// that from happening. Do not bypass it.
    static func buildSocketURL(language: String, noVerbatim: Bool, keyterms: [String]) -> URL? {
        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        var queryItems = [
            URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "language_code", value: language),
            URLQueryItem(name: "no_verbatim", value: noVerbatim ? "true" : "false")
        ]
        queryItems.append(contentsOf: keyterms.map { URLQueryItem(name: "keyterms", value: $0) })
        components.queryItems = queryItems
        // URLComponents leaves `+` literal in query values (RFC 3986 doesn't
        // reserve it there), but form-urlencoded parsers decode a literal `+`
        // as a SPACE — a keyterm like "C++" would silently reach the server
        // as "C  ", defeating the bias for exactly the code-identifier terms
        // this feature exists for. Force `%2B` so every parser agrees.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    /// Server-enforced ceiling on how many keyterms one session may carry.
    /// Exceeding it is fatal, not lossy: the socket answers `invalid_request`
    /// ("Number of keyterms cannot exceed 50. You provided 150 keyterms.")
    /// and never starts the session. Confirmed against the live API 2026-07-09.
    static let maxKeyterms = 50

    /// Server-enforced ceiling on the length of a single keyterm. Same failure
    /// mode as `maxKeyterms` — one over-long term kills the whole handshake
    /// ("Each keyterm must be at most 20 characters."). Dictation dictionaries
    /// accumulate long code identifiers, so this filter is load-bearing.
    static let maxKeytermLength = 20

    /// Pure, testable selection of keyterms from the learned dictionary:
    /// canonical `term` values ONLY — never `variants` (those are the WRONG
    /// spellings; biasing toward them would be counterproductive) — de-duped
    /// case-insensitively, with empties, single-character terms, and terms
    /// over `maxKeytermLength` dropped, then capped at `maxKeyterms` preferring
    /// the highest `fixCount` (correction count), tie-broken by
    /// most-recently-added (later index in `entries`).
    ///
    /// Dropping over-long terms silently is deliberate: the alternative is a
    /// failed handshake and a lost dictation. A term Scribe can't be biased
    /// toward still gets fixed afterwards by `DictionaryStore.correct(_:)`.
    static func selectKeyterms(from entries: [DictionaryEntry]) -> [String] {
        var seen = Set<String>()
        var candidates: [(term: String, fixCount: Int, index: Int)] = []
        for (index, entry) in entries.enumerated() {
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            // Length-check in UTF-8 BYTES, not Swift grapheme clusters: the
            // server's counting method is unknown, and bytes is the strictest
            // of the plausible ones (bytes >= scalars >= graphemes). Over-
            // dropping is safe (DictionaryStore.correct still fixes the term
            // post-hoc); an under-count fails the entire handshake.
            guard term.count > 1, term.utf8.count <= maxKeytermLength else { continue }
            let key = term.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            candidates.append((term: term, fixCount: entry.fixCount, index: index))
        }
        candidates.sort { a, b in
            if a.fixCount != b.fixCount { return a.fixCount > b.fixCount }
            return a.index > b.index
        }
        return candidates.prefix(maxKeyterms).map { $0.term }
    }

    // MARK: - Transcript assembly (static, @testable)

    /// Joins committed segments in arrival order, appending any not-yet-committed
    /// partial tail so a mid-hold read (or a finalize that timed out before the
    /// last commit landed) doesn't lose in-flight text.
    static func joinedTranscript(segments: [String], partial: String) -> String {
        let committed = segments.joined(separator: " ")
        let trimmedPartial = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPartial.isEmpty else { return committed }
        guard !committed.isEmpty else { return trimmedPartial }
        // Partial is a live re-transcription of audio not yet committed — if
        // it's already contained in what's committed (race with the commit
        // event), don't double it.
        if committed.localizedCaseInsensitiveContains(trimmedPartial) { return committed }
        return committed + " " + trimmedPartial
    }

    /// Builds the JSON TEXT frame for one `input_audio_chunk` message. All
    /// four fields are required by the schema on every frame (`commit` is
    /// not optional-omit) — see the class doc comment.
    static func makeInputAudioChunkFrame(pcmData: Data, commit: Bool) -> String {
        let payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": pcmData.base64EncodedString(),
            "commit": commit,
            "sample_rate": 16000
        ]
        // Construction from a literal key set with primitive-only values
        // (String/Bool/Int) cannot fail JSONSerialization — force-try is safe.
        let data = try! JSONSerialization.data(withJSONObject: payload) // swiftlint:disable:this force_try
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Format conversion

    /// Converts `buffer` (in whatever format the mic tap negotiated) to
    /// 16kHz mono PCM16 and returns the raw interleaved bytes. Mirrors
    /// `XAIStreamingTranscriber.convertToPCM16` — duplicated rather than
    /// shared to keep this class a drop-in, independently-testable unit and
    /// avoid touching the xAI file (purely-additive constraint).
    private func convertToPCM16(_ buffer: AVAudioPCMBuffer) -> Data? {
        let inputFormat = buffer.format

        if converter == nil || converterInputFormat != inputFormat {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                vlog("elevenlabs-stream: failed to create AVAudioConverter for input format")
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
            vlog("elevenlabs-stream: failed to allocate output PCM buffer")
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
            vlog("elevenlabs-stream: conversion error: \(error?.localizedDescription ?? "unknown")")
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
