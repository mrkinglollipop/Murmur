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
///     time a commit is processed. The service also commits automatically
///     after roughly 36 seconds of uncommitted audio even in manual mode
///     (https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/transcripts-and-commit-strategies),
///     so `send(_:)` sets `commit:true` on a chunk every 20–28 s itself and
///     finalize proves coverage by matching events to those commits (see
///     "Coverage proof" below).
///   - Non-fatal server errors arrive as distinct message types
///     (`input_error`, `transcriber_error`, `chunk_size_exceeded`, etc.) —
///     logged and otherwise ignored, mirroring xAI's `"error"` handling.
    ///   - Two further query params are built by `buildSocketURL`: `no_verbatim`
    ///     (server-side filler-word/disfluency removal) and repeated `keyterms`
    ///     (vocabulary bias from the learned dictionary). Advanced Settings
    ///     also send `commit_strategy`, optional `filter_background_audio`,
    ///     and VAD fields when commit is VAD.
///
/// CONCURRENCY DESIGN: identical shape to `XAIStreamingTranscriber` — see
/// that file's header for the full rationale. Summary: `send(_:)` runs on
/// the audio-tap thread, converts synchronously, and yields into an
/// `AsyncStream`; a single sender `Task` drains it in order onto the socket.
/// Two one-shot `CheckedContinuation`s bridge `start()`/`finalize()` to the
/// receive loop (`session_started` / final `committed_transcript`), guarded
/// by an `NSLock` + resolved-once flags exactly as xAI does.
final class ElevenLabsRealtimeTranscriber: NSObject, URLSessionWebSocketDelegate {
    typealias MessageSender = (URLSessionWebSocketTask.Message) async throws -> Void

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
    /// Advanced socket knobs (filter / commit / VAD). Defaults match the
    /// previous hardcoded URL.
    private let realtimeOptions: ElevenLabsRealtimeOptions
    private let injectedMessageSender: MessageSender?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private var senderTask: Task<Void, Never>?
    /// Opens only on a successful handshake; finishing without a value aborts sending.
    private var senderReadyContinuation: AsyncStream<Void>.Continuation?

    /// Feeds ready-to-send JSON `input_audio_chunk` frames (already encoded
    /// as a string) from `send(_:)` (audio-tap thread, synchronous,
    /// non-blocking) to the single sender `Task`.
    // Bound transport storage even when start is never called. Overflow latches
    // buffered-recording recovery; it must never silently truncate dictation.
    private var frameStream: AsyncStream<QueuedFrame>?
    private var frameContinuation: AsyncStream<QueuedFrame>.Continuation?

    /// One encoded `input_audio_chunk` plus the facts the coverage proof needs
    /// about it, so the sender can count audio it actually delivered.
    struct QueuedFrame: Sendable {
        let payload: String
        let samples: Int
        let commit: Bool
    }

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
    /// True once any non-empty partial or committed text arrived this session.
    /// Survives empty-commit clearing of `latestPartial` so stop can bypass
    /// local RMS silence cancel after HUD showed words.
    private var everHadNonEmptyStreamText = false

    /// Whether this session ever received non-empty stream text (partial or commit).
    var hasEverHadNonEmptyStreamText: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return everHadNonEmptyStreamText
    }

    /// Stop-time joined transcript snapshot (committed + in-flight partial).
    /// This is deliberately the current hypothesis, not the longest one seen:
    /// partials are speculative and can be corrected by a later commit.
    func joinedTranscriptSnapshot() -> String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
    }

    /// Resolved exactly once by the receive loop when `session_started` arrives.
    private var readyContinuation: CheckedContinuation<Void, Error>?
    // The first outcome also belongs to waiters registered after it resolves.
    private var readyResult: Result<Void, Error>?
    private var readyResolved: Bool { readyResult != nil }
    /// Set once `start()` has begun. With `readyResolved` still false, the
    /// server has not sent `session_started`, so the commit frame would reach
    /// the socket ahead of any audio.
    private var startInvoked = false

    /// Resolved exactly once after committed events become briefly quiet
    /// following `finalize()`'s `commit:true` frame.
    private var doneContinuation: CheckedContinuation<String, Never>?
    private var doneResolved = false
    /// ElevenLabs exposes finality per segment, not per session. A manual
    /// commit can race an automatic segment commit, so drain a short quiet
    /// window after the latest committed segment before completing finalize.
    private var doneDrainTask: Task<Void, Never>?
    private var doneDrainGeneration: UInt64 = 0
    private var finalizeWorkerTask: Task<Void, Never>?
    private var finalizeDeadlineTask: Task<Void, Never>?
    private var finalizeGeneration: UInt64 = 0
    private var finalizeCommitSeen = false
    private var finalizeCommitHadText = false
    private var lastFinalizeRequiresBufferedAudioRecovery = false
    private var streamIntegrityFailed = false
    private var intentionalSocketShutdown = false
    private var finalizeCoverageAmbiguous = false

    // MARK: Coverage proof (Murmur-driven segmentation)
    //
    // ElevenLabs auto-commits after ~36 s of uncommitted audio even under the
    // manual strategy, and its word timestamps have no documented reference
    // point, so a server-chosen boundary cannot be placed in the audio.
    // Murmur therefore commits every segment itself, well before the
    // auto-commit point, and matches committed events to its own commit frames
    // first-in-first-out over the single ordered socket. Coverage is proven
    // when every captured sample was handed to the transport (and the
    // recording is no longer than that audio), every commit Murmur sent (the
    // last one after the final audio sample) has exactly one committed event,
    // no event arrived without an outstanding commit, and no segment that
    // showed speech was answered with empty text. "Every captured sample"
    // includes the resampler's retained tail, flushed at finalize once no
    // conversion is in flight. Anything else needs buffered recovery.

    /// 16 kHz samples enqueued since the last commit frame (tap thread writes,
    /// finalize reads; stateLock-guarded).
    private var samplesSinceCommit = 0
    private var segmentRMSSum: Double = 0
    private var segmentChunkCount = 0
    /// Mid-hold commit frames enqueued by `send(_:)`.
    private var midHoldCommitsQueued = 0
    /// 16 kHz samples accepted into the frame queue.
    private var samplesQueued = 0
    /// 16 kHz samples the transport accepted, and those sent after the last
    /// commit frame. Commit counts alone cannot show how much audio a
    /// segment held.
    private var samplesSent = 0
    private var samplesSentSinceCommit = 0
    /// Commit frames handed to the transport, counted before the send so a
    /// fast reply can never look unsolicited.
    private var commitsDispatched = 0
    /// `committed_transcript` events received, empty ones included.
    private var committedEventsReceived = 0
    private var lastCommittedEventHadText = false
    /// A committed event arrived with no outstanding Murmur commit — a
    /// server-chosen boundary whose audio span cannot be proven.
    private var unsolicitedCommitSeen = false
    /// A non-empty partial arrived since the last committed event: the
    /// segment being transcribed contains speech.
    private var partialSinceCommittedEvent = false
    /// A segment that showed speech was answered with empty text. Its words
    /// may have been folded into, or overwritten by, a later segment, so the
    /// per-segment proof no longer holds.
    private var emptyCommitAfterSpeechSeen = false
    /// Ordinal of the commit covering the final audio sample; finalize may
    /// complete only once that many committed events have arrived.
    private var terminalCommitOrdinal: Int?

    /// `send(_:)` calls converting outside stateLock. Finalize waits for this
    /// to reach zero before draining the converter and closing the queue.
    private var conversionsInFlight = 0
    /// Set when finalize begins: later `send(_:)` calls never start a
    /// conversion, so the in-flight set can only shrink.
    private var captureClosed = false
    /// Set only by `cancel()`. Audio arriving after the queue closed latches
    /// recovery for every other session end.
    private var cancelledByUser = false
    /// Bound on how long finalize waits for in-flight conversions (normally
    /// microseconds). Past it, the result recovers from the recording.
    static let conversionSettleNanoseconds: UInt64 = 200_000_000

    /// Emits whatever the converter still holds once input has ended. A nil
    /// return means the drain failed. Replaceable in tests.
    var drainConverterTail: (AVAudioConverter, AVAudioFormat) -> Data? = ElevenLabsRealtimeTranscriber.drainTail(of:outputFormat:)
    /// Runs between conversion and the enqueue re-check, outside stateLock.
    /// Tests use it to hold a conversion in flight.
    var afterConversionHook: (() -> Void)?

    /// Earliest point a mid-hold commit may be placed (ElevenLabs recommends
    /// committing every 20–30 s). Waiting for a quieter chunk only moves the
    /// boundary; every sample is still sent.
    static let segmentSoftCommitSamples = 20 * 16_000
    /// Forced boundary, far enough below the ~36 s auto-commit that the
    /// server never chooses a boundary of its own.
    static let segmentHardCommitSamples = 28 * 16_000
    /// Allowed shortfall of streamed audio against `recordingDuration` (the
    /// captured recording): sample-rate converter latency and per-buffer
    /// rounding only, far below one spoken word.
    static let streamedAudioToleranceSeconds: TimeInterval = 0.25

    /// ElevenLabs has no session-final event. Bound the whole stop-time path —
    /// queued audio drain, terminal send, provider wait, and committed-event
    /// quiet drain — then recover from the complete retained recording.
    private static let finalizeBudgetNanoseconds: UInt64 = 1_500_000_000
    /// Extra allowance when a mid-hold commit is still unanswered at release:
    /// the server answers it before the terminal commit. Bounded to one step.
    private static let outstandingSegmentBudgetNanoseconds: UInt64 = 500_000_000
    private static let committedDrainNanoseconds: UInt64 = 250_000_000
    private var finalizeStartedAt: Date?
    private var finalizeSenderDrainedAt: Date?
    private var finalizeTerminalSentAt: Date?
    private var finalizeFirstEventAt: Date?

    var requiresBufferedAudioRecovery: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastFinalizeRequiresBufferedAudioRecovery || streamIntegrityFailed
    }

    /// True once `finalize()` has requested end-of-session. Mid-hold
    /// `committed_transcript` events only accumulate; they must not complete
    /// `finalize()`'s waiter (that was early-doneResolved).
    private var finalizeRequested = false
    private var finalizeDrainArmed = false

    /// Set once `finalize()`/`cancel()` has run, guarding against double-invoke.
    private var tornDown = false

    /// Set once the socket fails or closes, so `finalize()` can short-circuit
    /// instead of hanging on the done-timeout.
    private var socketClosed = false

    init(
        apiKey: String,
        language: String = "en",
        noVerbatim: Bool = false,
        keyterms: [String] = [],
        realtimeOptions: ElevenLabsRealtimeOptions = .defaults,
        messageSender: MessageSender? = nil
    ) {
        self.apiKey = apiKey
        self.language = language
        self.noVerbatim = noVerbatim
        self.keyterms = keyterms
        self.realtimeOptions = realtimeOptions.clamped()
        self.injectedMessageSender = messageSender
        // Capture may begin as soon as this session is published, before start().
        let (stream, frames) = AsyncStream<QueuedFrame>.makeStream(bufferingPolicy: .bufferingOldest(256))
        self.frameStream = stream
        self.frameContinuation = frames
        super.init()
    }

    // MARK: - Lifecycle

    /// Opens the socket and awaits `session_started`. Throws on
    /// connection/auth failure or if readiness doesn't arrive within ~5s.
    // Lifecycle hooks let offline tests hold start at the readiness boundary.
    func start(
        beforeReadiness: (() -> Void)? = nil,
        afterReadiness: (() async -> Void)? = nil
    ) async throws {
        vlog("elevenlabs-stream: starting session")
        stateLock.lock()
        startInvoked = true
        // Preserve conversion/overflow failures from audio captured before start.
        lastFinalizeRequiresBufferedAudioRecovery = false
        intentionalSocketShutdown = false
        stateLock.unlock()
        resetTranscriptState()
        var started = false
        defer { if !started { tearDownSocket() } }

        guard let url = Self.buildSocketURL(
            language: language,
            noVerbatim: noVerbatim,
            keyterms: keyterms,
            options: realtimeOptions
        ) else {
            throw CloudTranscriptionError(provider: .elevenLabs, message: "Failed to build streaming URL")
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key") // NOT bearer

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

        // Buffer frames captured during the handshake in capture order
        // so the leading audio of the utterance survives socket-open latency;
        // the sender only starts draining once `session_started` arrives.
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
                if frame.commit {
                    self.stateLock.lock()
                    self.commitsDispatched += 1
                    let ordinal = self.commitsDispatched
                    self.stateLock.unlock()
                    vlog("elevenlabs-stream: mid-hold commit #\(ordinal) dispatched")
                }
                do {
                    try await sendFrame(.string(frame.payload))
                } catch {
                    self.markStreamIntegrityFailed()
                    vlog("elevenlabs-stream: send failed, stopping sender: \(error.localizedDescription)")
                    break
                }
                self.stateLock.lock()
                self.samplesSent += frame.samples
                self.samplesSentSinceCommit = frame.commit ? 0 : self.samplesSentSinceCommit + frame.samples
                self.stateLock.unlock()
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
                throw CloudTranscriptionError(provider: .elevenLabs, message: "Timed out waiting for session_started")
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
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

        vlog("elevenlabs-stream: session ready")
    }

    /// Converts one captured buffer to 16kHz mono PCM16, base64-encodes it,
    /// and enqueues the JSON frame payload for sending. Called from the
    /// realtime audio-tap thread — returns quickly, never blocks on the
    /// network. Buffers before start; no-op after finalize/cancel.
    func send(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        guard frameContinuation != nil, !captureClosed else {
            noteUnstreamedAudioLocked(samples: Int(buffer.frameLength))
            stateLock.unlock()
            return
        }
        // Counted before the lock is released so finalize can wait for this
        // conversion instead of closing the queue underneath it.
        conversionsInFlight += 1
        stateLock.unlock()
        let converted = convertToPCM16(buffer)
        afterConversionHook?()
        stateLock.lock()
        conversionsInFlight -= 1
        guard let pcmData = converted else {
            streamIntegrityFailed = true
            lastFinalizeRequiresBufferedAudioRecovery = true
            stateLock.unlock()
            vlogFromAudioTap(.conversionFailure(.elevenlabs, .emptyConversion))
            return
        }
        let samples = pcmData.count / MemoryLayout<Int16>.size
        let chunkRMS = Self.rms(ofPCM16: pcmData)
        // Re-read under the lock that also covers the yield: finalize may have
        // closed the queue during conversion, and a yield into a finished
        // queue would lose this audio without a trace.
        guard let continuation = frameContinuation else {
            noteUnstreamedAudioLocked(samples: samples)
            stateLock.unlock()
            return
        }
        let commit = realtimeOptions.commitStrategy == .manual && Self.shouldCommitSegment(
            samplesSinceCommit: samplesSinceCommit + samples,
            chunkRMS: chunkRMS,
            segmentMeanRMS: segmentChunkCount > 0 ? segmentRMSSum / Double(segmentChunkCount) : chunkRMS
        )
        // Count and enqueue under one lock so finalize never observes a
        // commit that is not yet in the queue (or the reverse).
        if commit {
            samplesSinceCommit = 0
            segmentRMSSum = 0
            segmentChunkCount = 0
            midHoldCommitsQueued += 1
        } else {
            samplesSinceCommit += samples
            segmentRMSSum += chunkRMS
            segmentChunkCount += 1
        }
        let frame = QueuedFrame(
            payload: Self.makeInputAudioChunkFrame(pcmData: pcmData, commit: commit),
            samples: samples,
            commit: commit
        )
        if case .enqueued = continuation.yield(frame) {
            samplesQueued += samples
        } else {
            // Dropped on overflow, or terminated: either way not streamed.
            streamIntegrityFailed = true
            lastFinalizeRequiresBufferedAudioRecovery = true
        }
        stateLock.unlock()
    }

    /// Must be called with stateLock held. Captured audio arrived after the
    /// frame queue closed, so the stream never carried it. Latches for every
    /// session end except a user cancel, independent of finalize's own state
    /// resets. A latch after finalize returned cannot reach an accepted
    /// result: finalize accepts only after every conversion begun before
    /// `captureClosed` has finished (see `runFinalizeWork`), and the recorder
    /// returns from `send(_:)` for every buffer in its recovery snapshot
    /// before finalize is called (`AudioRecorder.finishStop`,
    /// `captureDeliveryLock`). Later audio is in neither the stream nor the
    /// recording that `recordingDuration` measures.
    private func noteUnstreamedAudioLocked(samples: Int) {
        guard samples > 0, !cancelledByUser else { return }
        streamIntegrityFailed = true
        lastFinalizeRequiresBufferedAudioRecovery = true
    }

    /// Mid-hold boundary rule. After the soft limit, commit on the first chunk
    /// clearly quieter than the segment so far (likely a pause between words);
    /// at the hard limit, commit regardless. Only placement changes: the
    /// chunk is still sent, as the last audio of its segment.
    static func shouldCommitSegment(samplesSinceCommit: Int, chunkRMS: Double, segmentMeanRMS: Double) -> Bool {
        if samplesSinceCommit >= segmentHardCommitSamples { return true }
        guard samplesSinceCommit >= segmentSoftCommitSamples else { return false }
        return chunkRMS <= segmentMeanRMS * 0.5
    }

    static func rms(ofPCM16 data: Data) -> Double {
        let count = data.count / MemoryLayout<Int16>.size
        guard count > 0 else { return 0 }
        let sum = data.withUnsafeBytes { raw -> Double in
            raw.bindMemory(to: Int16.self).reduce(0.0) { $0 + Double($1) * Double($1) }
        }
        return (sum / Double(count)).squareRoot()
    }

    /// Sends a final `commit:true` frame (with an empty audio payload — all
    /// captured audio was already streamed via `send(_:)`) and awaits the final
    /// `committed_transcript` within the product latency budget. If any part of
    /// finalization exceeds that budget, the coordinator recovers from the
    /// complete retained recording. Tears the socket down either way.
    func finalize(recordingDuration: TimeInterval = 0) async -> String {
        stateLock.lock()
        if tornDown {
            let text = Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
            stateLock.unlock()
            return text
        }
        tornDown = true
        finalizeRequested = true
        finalizeDrainArmed = false
        finalizeGeneration &+= 1
        let generation = finalizeGeneration
        finalizeStartedAt = Date()
        finalizeSenderDrainedAt = nil
        finalizeTerminalSentAt = nil
        finalizeFirstEventAt = nil
        let budget = Self.finalizeBudgetNanoseconds
            + (midHoldCommitsQueued > committedEventsReceived ? Self.outstandingSegmentBudgetNanoseconds : 0)
        // No new conversion starts from here on. Conversions already running
        // may still enqueue; the worker waits for them before closing the
        // queue, all inside the finalize budget.
        captureClosed = true
        stateLock.unlock()

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            stateLock.lock()
            doneContinuation = continuation
            stateLock.unlock()

            let deadline = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: budget)
                } catch {
                    return
                }
                self?.completeFinalize(generation: generation, requiresBufferedRecovery: true)
            }
            let worker = Task { [weak self] in
                guard let self else { return }
                await self.runFinalizeWork(
                    recordingDuration: recordingDuration,
                    generation: generation
                )
            }
            stateLock.lock()
            if finalizeGeneration == generation, !doneResolved {
                finalizeDeadlineTask = deadline
                finalizeWorkerTask = worker
                stateLock.unlock()
            } else {
                stateLock.unlock()
                deadline.cancel()
                worker.cancel()
            }
        }

        tearDownSocket()

        stateLock.lock()
        let startedAt = finalizeStartedAt
        let senderDrainedAt = finalizeSenderDrainedAt
        let terminalSentAt = finalizeTerminalSentAt
        let firstEventAt = finalizeFirstEventAt
        let recovered = lastFinalizeRequiresBufferedAudioRecovery || streamIntegrityFailed
        let coverage = "commits=\(commitsDispatched) events=\(committedEventsReceived) unsolicited=\(unsolicitedCommitSeen) emptyAfterSpeech=\(emptyCommitAfterSpeechSeen) sent=\(String(format: "%.2f", Double(samplesSent) / 16_000))s queued=\(String(format: "%.2f", Double(samplesQueued) / 16_000))s recording=\(String(format: "%.2f", recordingDuration))s"
        resetTranscriptState()
        stateLock.unlock()
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let senderDrain = Self.elapsedDescription(senderDrainedAt, since: startedAt)
        let terminalSend = Self.elapsedDescription(terminalSentAt, since: startedAt)
        let firstEvent = Self.elapsedDescription(firstEventAt, since: startedAt)
        vlog("elevenlabs-stream: finalize took \(String(format: "%.3f", elapsed))s recovery=\(recovered) senderDrain=\(senderDrain) terminalSend=\(terminalSend) firstEvent=\(firstEvent) \(coverage), \(result.count) chars")
        return result
    }

    /// Waits for conversions begun before `captureClosed`, flushes the
    /// converter's retained tail into the queue, then closes it. Returns the
    /// sender to drain; `active` is false once this finalize has resolved.
    private func closeCaptureQueue(generation: UInt64) async -> (sender: Task<Void, Never>?, active: Bool) {
        let settleDeadline = DispatchTime.now().uptimeNanoseconds + Self.conversionSettleNanoseconds
        var settled = false
        while true {
            stateLock.lock()
            let active = finalizeGeneration == generation && !doneResolved
            settled = conversionsInFlight == 0
            stateLock.unlock()
            guard active else { return (nil, false) }
            if settled || DispatchTime.now().uptimeNanoseconds >= settleDeadline { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        // With capture closed and nothing in flight, no conversion can touch
        // the converter concurrently. Resampling keeps up to a few samples
        // back until end-of-stream; those are captured audio and must be sent
        // before the terminal commit, or the commit answers less than the
        // recording holds.
        var tail = Data()
        var tailFailed = !settled
        if settled, let converter {
            if let drained = drainConverterTail(converter, outputFormat) {
                tail = drained
            } else {
                tailFailed = true
            }
        }

        stateLock.lock()
        if tailFailed {
            // An unfinished conversion may still hold captured audio, and a
            // failed drain leaves the converter's tail unsent.
            streamIntegrityFailed = true
            lastFinalizeRequiresBufferedAudioRecovery = true
        }
        if !tailFailed, !tail.isEmpty, let continuation = frameContinuation {
            let samples = tail.count / MemoryLayout<Int16>.size
            let frame = QueuedFrame(
                payload: Self.makeInputAudioChunkFrame(pcmData: tail, commit: false),
                samples: samples,
                commit: false
            )
            if case .enqueued = continuation.yield(frame) {
                samplesQueued += samples
                samplesSinceCommit += samples
            } else {
                streamIntegrityFailed = true
                lastFinalizeRequiresBufferedAudioRecovery = true
            }
        }
        // Stop accepting new frames, then let the sender flush every
        // already-captured frame before the commit frame — otherwise the
        // commit could overtake buffered audio and truncate the tail.
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
        if tailFailed {
            vlog("elevenlabs-stream: capture close \(settled ? "converter drain failed" : "timed out on in-flight conversion") — recovery")
        }
        return (senderToDrain, true)
    }

    /// Flushes `converter` with end-of-stream input. Nil on any converter
    /// error, or if it never reports end-of-stream within a bounded number of
    /// passes.
    static func drainTail(of converter: AVAudioConverter, outputFormat: AVAudioFormat) -> Data? {
        var tail = Data()
        for _ in 0..<16 {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1024) else { return nil }
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard status != .error, error == nil else { return nil }
            let frames = Int(buffer.frameLength)
            if frames > 0 {
                guard let samples = buffer.int16ChannelData else { return nil }
                tail.append(Data(bytes: samples[0], count: frames * MemoryLayout<Int16>.size))
            }
            if status == .endOfStream { return tail }
        }
        return nil
    }

    private func runFinalizeWork(
        recordingDuration: TimeInterval,
        generation: UInt64
    ) async {
        let (senderToDrain, active) = await closeCaptureQueue(generation: generation)
        guard active else { return }
        await senderToDrain?.value
        stateLock.lock()
        guard finalizeGeneration == generation, !doneResolved else {
            stateLock.unlock()
            return
        }
        finalizeSenderDrainedAt = Date()
        let closed = socketClosed
        let integrityFailed = streamIntegrityFailed
        // VAD boundaries are server-chosen, and an unsolicited commit is a
        // boundary Murmur cannot place in the audio. An empty answer to a
        // segment that showed speech leaves that segment's words unaccounted
        // for. None of these can be proven, so no terminal commit could
        // improve the result. The sender has drained: audio queued but never
        // sent, or a recording longer than the audio the transport accepted,
        // means part of the hold never reached the server.
        let streamedSeconds = Double(samplesSent) / 16_000
        finalizeCoverageAmbiguous = realtimeOptions.commitStrategy == .vad
            || unsolicitedCommitSeen
            || emptyCommitAfterSpeechSeen
            || samplesSent != samplesQueued
            || recordingDuration > streamedSeconds + Self.streamedAudioToleranceSeconds
        let notReady = startInvoked && !readyResolved
        let needsBatchRecovery = finalizeCoverageAmbiguous || notReady
        stateLock.unlock()

        if closed || integrityFailed || needsBatchRecovery {
            if closed { markStreamIntegrityFailed() }
            completeFinalize(generation: generation, requiresBufferedRecovery: true)
            return
        }

        // Commits received while the sender backlog was draining answer
        // earlier, Murmur-placed boundaries. Only the event for the commit
        // covering the final sample may complete this finalize call.
        let hasTerminalDestination = task != nil || injectedMessageSender != nil
        stateLock.lock()
        guard finalizeGeneration == generation, !doneResolved else {
            stateLock.unlock()
            return
        }
        finalizeCommitSeen = false
        finalizeCommitHadText = false
        // The sender has drained, so every queued mid-hold commit is
        // dispatched. Only when the transport accepted no audio after the last
        // one does it already cover the final sample; an empty terminal commit
        // would then be unanswerable.
        let audioAlreadyCommitted = hasTerminalDestination && samplesSentSinceCommit == 0 && commitsDispatched > 0
        let sendTerminal = hasTerminalDestination && !audioAlreadyCommitted
        if audioAlreadyCommitted {
            terminalCommitOrdinal = commitsDispatched
            if committedEventsReceived >= commitsDispatched {
                finalizeCommitSeen = true
                finalizeCommitHadText = lastCommittedEventHadText
            }
        } else if sendTerminal {
            // Counted before the send so its reply is never unsolicited.
            commitsDispatched += 1
            terminalCommitOrdinal = commitsDispatched
        } else {
            // No transport: nothing can answer, so require one more event
            // than was requested; the budget then recovers from audio.
            terminalCommitOrdinal = commitsDispatched + 1
        }
        stateLock.unlock()

        if sendTerminal {
            do {
                let commitFrame = Self.makeInputAudioChunkFrame(pcmData: Data(), commit: true)
                try await sendMessage(.string(commitFrame))
            } catch {
                stateLock.lock()
                let stillActive = finalizeGeneration == generation && !doneResolved
                stateLock.unlock()
                if stillActive {
                    markStreamIntegrityFailed()
                    completeFinalize(generation: generation, requiresBufferedRecovery: true)
                }
                return
            }
        }

        stateLock.lock()
        guard finalizeGeneration == generation, !doneResolved else {
            stateLock.unlock()
            return
        }
        if sendTerminal {
            finalizeTerminalSentAt = Date()
        }
        finalizeDrainArmed = true
        if finalizeCommitSeen {
            scheduleDoneAfterCommittedQuietPeriodLocked()
        }
        stateLock.unlock()
    }

    private func completeFinalize(generation: UInt64, requiresBufferedRecovery: Bool) {
        stateLock.lock()
        guard finalizeGeneration == generation, !doneResolved else {
            stateLock.unlock()
            return
        }
        if requiresBufferedRecovery {
            lastFinalizeRequiresBufferedAudioRecovery = true
        }
        let continuation = doneContinuation
        let text = finalizeResultLocked()
        doneResolved = true
        doneContinuation = nil
        stateLock.unlock()
        continuation?.resume(returning: text)
    }

    private static func elapsedDescription(_ date: Date?, since start: Date?) -> String {
        guard let date, let start else { return "none" }
        return String(format: "%.3f", date.timeIntervalSince(start))
    }

    /// Hard stop, no read-back. Cancels the socket and sender.
    func cancel() {
        let error = CloudTranscriptionError(provider: .elevenLabs, message: "cancelled")
        stateLock.lock()
        if tornDown {
            stateLock.unlock()
            return
        }
        tornDown = true
        cancelledByUser = true
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
            senderReadyContinuation?.finish()
            senderReadyContinuation = nil
            readyResult = .failure(error)
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
        pendingReady?.resume(throwing: error)
        pendingDone?.resume(returning: accumulated)

        tearDownSocket()
        vlog("elevenlabs-stream: cancelled")
    }

    private func resetTranscriptState() {
        committedSegments = []
        latestPartial = ""
        everHadNonEmptyStreamText = false
        // Send-side segmentation counters are not reset here: start() calls
        // this after capture may already have queued pre-ready audio.
        commitsDispatched = 0
        committedEventsReceived = 0
        lastCommittedEventHadText = false
        unsolicitedCommitSeen = false
        partialSinceCommittedEvent = false
        emptyCommitAfterSpeechSeen = false
        terminalCommitOrdinal = nil
        finalizeRequested = false
        finalizeDrainArmed = false
        finalizeCommitSeen = false
        finalizeCommitHadText = false
        finalizeCoverageAmbiguous = false
        doneDrainGeneration &+= 1
        doneDrainTask?.cancel()
        doneDrainTask = nil
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
        finalizeWorkerTask?.cancel()
        finalizeWorkerTask = nil
        finalizeDeadlineTask?.cancel()
        finalizeDeadlineTask = nil
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
        noteSocketClosed(closeCode: closeCode)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1
        if let ns = error as NSError? {
            vlog("elevenlabs-stream: task completed httpStatus=\(status) error=\(ns.domain)#\(ns.code)")
        } else {
            vlog("elevenlabs-stream: task completed httpStatus=\(status) error=none")
        }
        stateLock.lock()
        let intentional = intentionalSocketShutdown
        stateLock.unlock()
        if error != nil, !intentional { markStreamIntegrityFailed() }
        failReadyIfPending("task completed httpStatus=\(status)")
    }

    /// If `start()` is still awaiting `session_started`, fail it now rather
    /// than let it block on the 5s timeout, so the caller falls back to the
    /// file/batch path promptly. No-op once ready has resolved.
    private func failReadyIfPending(_ reason: String) {
        let error = CloudTranscriptionError(provider: .elevenLabs, message: reason)
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
                vlog("elevenlabs-stream: receive loop ended: \(ns.domain)#\(ns.code) \(error.localizedDescription)")
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

    /// Package-visible for unit tests (`@testable`) — production receive loop only.
    func handleServerEvent(_ text: String) {
        stateLock.lock()
        if tornDown && doneResolved {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageType = json["message_type"] as? String
        else {
            markStreamIntegrityFailed()
            vlog("elevenlabs-stream: received unparseable event")
            return
        }

        stateLock.lock()
        if tornDown && doneResolved {
            stateLock.unlock()
            return
        }
        if finalizeRequested, finalizeFirstEventAt == nil {
            finalizeFirstEventAt = Date()
        }
        stateLock.unlock()

        switch messageType {
        case "session_started":
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
            vlog("elevenlabs-stream: session_started")

        case "partial_transcript":
            let partialText = (json["text"] as? String) ?? ""
            stateLock.lock()
            guard !(tornDown && doneResolved) else {
                stateLock.unlock()
                return
            }
            // Empty/whitespace partial must not wipe a prior non-empty
            // latestPartial (mirrors empty committed_transcript retain).
            let trimmedPartial = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPartial.isEmpty {
                latestPartial = partialText
                everHadNonEmptyStreamText = true
                partialSinceCommittedEvent = true
            }
            let running = Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
            let shouldDrain = finalizeRequested && finalizeDrainArmed
                && finalizeCommitSeen && !doneResolved
            if shouldDrain { scheduleDoneAfterCommittedQuietPeriodLocked() }
            stateLock.unlock()
            onInterim?(running)

        case "committed_transcript":
            let committedText = (json["text"] as? String) ?? ""
            stateLock.lock()
            guard !(tornDown && doneResolved) else {
                stateLock.unlock()
                return
            }
            let trimmed = committedText.trimmingCharacters(in: .whitespacesAndNewlines)
            // The socket and the server's segment processing are both
            // in-order, so the nth event answers Murmur's nth commit and
            // arrival order is audio order. An event with no outstanding
            // commit is a server-chosen boundary; its text is still kept for
            // the HUD, but the session can no longer prove coverage.
            committedEventsReceived += 1
            lastCommittedEventHadText = !trimmed.isEmpty
            let unsolicited = committedEventsReceived > commitsDispatched
            if unsolicited {
                unsolicitedCommitSeen = true
            }
            // Partials between two committed events describe the segment the
            // second one answers. An empty answer after speech must latch now:
            // the next segment's partials and commit would erase the evidence.
            let emptyAfterSpeech = trimmed.isEmpty && partialSinceCommittedEvent
            if emptyAfterSpeech {
                emptyCommitAfterSpeechSeen = true
                lastFinalizeRequiresBufferedAudioRecovery = true
            }
            partialSinceCommittedEvent = false
            if !trimmed.isEmpty {
                committedSegments.append(trimmed)
                everHadNonEmptyStreamText = true
                // Do not join the new segment with the still-present partial —
                // that duplicates the head ("commit + partial").
                latestPartial = ""
            }
            let running = Self.joinedTranscript(segments: committedSegments, partial: latestPartial)
            if finalizeRequested, let terminal = terminalCommitOrdinal,
               committedEventsReceived >= terminal {
                finalizeCommitSeen = true
                if !trimmed.isEmpty { finalizeCommitHadText = true }
            }
            let shouldDrain = finalizeRequested && finalizeDrainArmed && !doneResolved
            if shouldDrain { scheduleDoneAfterCommittedQuietPeriodLocked() }
            stateLock.unlock()
            onInterim?(running)
            vlog("elevenlabs-stream: committed_transcript (\(trimmed.count) chars) finalizeRequested=\(finalizeRequested) unsolicited=\(unsolicited) emptyAfterSpeech=\(emptyAfterSpeech)")

        case "committed_transcript_with_timestamps":
            // This follows committed_transcript and repeats the same segment.
            // Never append it. If timestamps are enabled in the future, count
            // it as receive activity so finalize does not close between the
            // paired events.
            stateLock.lock()
            guard !(tornDown && doneResolved) else {
                stateLock.unlock()
                return
            }
            let shouldDrain = finalizeRequested && finalizeDrainArmed && !doneResolved
            if shouldDrain { scheduleDoneAfterCommittedQuietPeriodLocked() }
            stateLock.unlock()

        case "input_error", "transcriber_error", "chunk_size_exceeded",
             "queue_overflow", "resource_exhausted", "session_time_limit_exceeded",
             "insufficient_audio_activity":
            // Per the protocol these do not necessarily close the connection —
            // log and keep the receive loop running, mirroring xAI's "error".
            let message = (json["error"] as? String) ?? "unknown"
            markStreamIntegrityFailed()
            vlog("elevenlabs-stream: server error event [\(messageType)]: \(CloudTranscriptionError.redactedBodyFragment(message))")

        default:
            vlog("elevenlabs-stream: unhandled message_type: \(messageType)")
        }
    }

    /// Must be called with stateLock held so transcript mutation and drain
    /// invalidation are one atomic state transition.
    private func scheduleDoneAfterCommittedQuietPeriodLocked() {
        doneDrainGeneration &+= 1
        let generation = doneDrainGeneration
        doneDrainTask?.cancel()
        doneDrainTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.committedDrainNanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            self.stateLock.lock()
            guard self.doneDrainGeneration == generation,
                  self.finalizeRequested,
                  self.finalizeDrainArmed,
                  !self.doneResolved else {
                self.stateLock.unlock()
                return
            }
            if self.unsolicitedCommitSeen || self.emptyCommitAfterSpeechSeen {
                // Coverage is already disproven; waiting cannot restore it.
                self.lastFinalizeRequiresBufferedAudioRecovery = true
                let continuation = self.doneContinuation
                let text = self.finalizeResultLocked()
                self.doneResolved = true
                self.doneContinuation = nil
                self.doneDrainTask = nil
                self.stateLock.unlock()
                continuation?.resume(returning: text)
                return
            }
            guard self.finalizeCommitSeen else {
                // An earlier segment's event arrived after release. The
                // commit covering the final sample is still owed; the global
                // budget requests buffered recovery if it never arrives.
                self.doneDrainTask = nil
                self.stateLock.unlock()
                return
            }
            if self.finalizeCommitHadText,
               !self.latestPartial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !Self.partialIsCovered(byCommitted: self.committedSegments, partial: self.latestPartial) {
                // A new hypothesis arrived after a committed segment. Wait for
                // its authoritative commit; the global timeout will request
                // buffered-audio recovery if that commit never arrives.
                // A partial whose words are all already committed (a trailing
                // re-emit) carries nothing a further commit could add — no audio
                // follows the terminal frame — so it must not hold the wait.
                self.doneDrainTask = nil
                self.stateLock.unlock()
                return
            }
            if self.finalizeCoverageAmbiguous {
                self.lastFinalizeRequiresBufferedAudioRecovery = true
            }
            let continuation = self.doneContinuation
            let text = self.finalizeResultLocked()
            self.doneResolved = true
            self.doneContinuation = nil
            self.doneDrainTask = nil
            self.stateLock.unlock()
            continuation?.resume(returning: text)
        }
    }

    private func sendMessage(_ message: URLSessionWebSocketTask.Message) async throws {
        if let injectedMessageSender {
            try await injectedMessageSender(message)
            return
        }
        guard let task else {
            throw CloudTranscriptionError(provider: .elevenLabs, message: "stream socket unavailable")
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
        let shouldFail = !intentionalSocketShutdown
        stateLock.unlock()
        if shouldFail { markStreamIntegrityFailed() }
        failReadyIfPending("closed code \(closeCode.rawValue)")
    }

    /// Must be called with stateLock held. Once a post-finalize commit has
    /// arrived, an even later partial is speculative until another commit;
    /// timeout must not promote it to authoritative output.
    private func finalizeResultLocked() -> String {
        Self.finalizeTranscript(
            segments: committedSegments,
            partial: latestPartial,
            commitSeen: finalizeCommitHadText
        )
    }

    /// True when every word of `partial` already appears, in order and
    /// contiguously, inside the committed text (case- and punctuation-
    /// insensitive). Such a partial adds no words to the result.
    static func partialIsCovered(byCommitted segments: [String], partial: String) -> Bool {
        func words(_ text: String) -> [Substring] {
            text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        }
        let needle = words(partial)
        guard !needle.isEmpty else { return true }
        let haystack = words(segments.joined(separator: " "))
        guard haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count)
            where haystack[start..<(start + needle.count)].elementsEqual(needle) {
            return true
        }
        return false
    }

    static func finalizeTranscript(
        segments: [String],
        partial: String,
        commitSeen: Bool
    ) -> String {
        joinedTranscript(segments: segments, partial: commitSeen ? "" : partial)
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
    ///
    /// Advanced knobs (`commit_strategy`, optional `filter_background_audio`,
    /// VAD fields when commit is VAD) come from `options`. Do not add
    /// `include_timestamps` here: EL rejects that combo with background filter.
    static func buildSocketURL(
        language: String,
        noVerbatim: Bool,
        keyterms: [String],
        options: ElevenLabsRealtimeOptions = .defaults
    ) -> URL? {
        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        var queryItems = [
            URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "language_code", value: language),
            URLQueryItem(name: "no_verbatim", value: noVerbatim ? "true" : "false")
        ]
        queryItems.append(contentsOf: options.queryItems())
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
        // Pending learn suggestions bias nothing until the user approves them.
        for (index, entry) in entries.enumerated() where !entry.isPendingApproval {
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

        // A format change replaces the converter; its retained tail is
        // captured audio and leads this buffer's output.
        var carriedTail = Data()
        if let previous = converter, converterInputFormat != inputFormat {
            guard let drained = drainConverterTail(previous, outputFormat) else {
                vlogFromAudioTap(.conversionFailure(.elevenlabs, .conversion))
                return nil
            }
            carriedTail = drained
            converter = nil
        }
        if converter == nil {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                vlogFromAudioTap(.conversionFailure(.elevenlabs, .converterCreation))
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
            vlogFromAudioTap(.conversionFailure(.elevenlabs, .bufferAllocation))
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
            vlogFromAudioTap(.conversionFailure(.elevenlabs, .conversion))
            return nil
        }
        guard let int16Data = outputBuffer.int16ChannelData else {
            return nil
        }

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else { return nil }
        return carriedTail + Data(bytes: int16Data[0], count: frameCount * MemoryLayout<Int16>.size)
    }
}
