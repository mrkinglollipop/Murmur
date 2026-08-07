import AppKit
import AVFoundation
import Carbon
import os.log

/// Captures microphone audio via AVAudioEngine while the push-to-talk key
/// is held.  On release, writes the buffer to a temp .caf file, then passes
/// it to the selected ASR engine for transcription.

final class AudioRecorder {

    /// Engine selector — change `selectedModel` to switch models/backends.
    let asrSelector = ASREngineSelector()

    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "audio")

    private let engine = AVAudioEngine()
    private var pcmBuffers: [AVAudioPCMBuffer] = []
    private let pcmBuffersLock = NSLock()
    private var startTime: Date?
    private var isSetUp = false

    /// Tracks the most recent start/stop request. Guards against a stale
    /// permission-completion handler (fired after a later stopRecording())
    /// resurrecting a recording the caller already cancelled.
    private var wantsRecording = false

    /// True while `doStop` has claimed the current take. Prevents a second
    /// `doStop` (fn flicker / toggle-lock / tap-resync) from falling through
    /// to the file/batch path after streaming already owns the stop.
    private var isStopping = false

    /// Bumped on every `stopRecording`. Captured into the queued `doStop` so a
    /// stale stop (after a newer stop, or after re-press re-armed recording)
    /// aborts without tearing down the newer session's mic/stream/hold/cache.
    private var stopGeneration: UInt64 = 0

    /// Returns whether a subtle start/stop sound should play, read fresh at
    /// each call site rather than cached. Wired by `AppDelegate` to
    /// `SettingsStore.playDictationSound`.
    var playDictationSoundProvider: (() -> Bool)?

    /// Short label for the HUD key chip (e.g. "fn", "⌥"). Wired by
    /// `AppDelegate` to `SettingsStore.activationKeyOption.hudLabel`.
    var activationKeyLabelProvider: (() -> String)?

    /// Paths that must not be deleted when pruning retained recordings
    /// (failed history rows still need audio for retry). Wired by AppDelegate.
    var protectedAudioPathsProvider: (() -> [String])?

    /// Size budget (bytes) for retained recordings. Wired by AppDelegate to
    /// `SettingsStore.recordingBudgetBytes`.
    var recordingBudgetBytesProvider: (() -> Int64)?

    /// Single shared HUD instance, shown/hidden across the capture lifecycle
    /// — never recreated per recording.
    let hud = RecordingHUD()

    /// Thread-safe smoothed mic level (0...1), written from the realtime
    /// audio-tap thread and consumed on main via `publishLevel`. A simple
    /// exponential smoother keeps the value fluid without allocating on the
    /// audio thread.
    private let levelLock = NSLock()
    private var smoothedLevel: Float = 0

    /// Loudest raw per-buffer RMS seen during the current recording, updated on
    /// the audio thread inside `publishLevel` (under `levelLock`). Read at stop
    /// to gate out silent recordings BEFORE they reach the ASR: Whisper-family
    /// models were trained on subtitled video and hallucinate stock captions
    /// ("thank you", "thanks for watching") on near-silence, so a hold with no
    /// real speech must inject nothing rather than a dreamed phrase.
    private var maxLevelObserved: Float = 0

    /// Raw-RMS speech-presence threshold. If the loudest buffer of a whole
    /// recording never crosses this, the clip is treated as silence and the
    /// transcription is skipped entirely. Room tone sits well below this and
    /// speech well above; the observed max is logged at every stop
    /// (`recordingHadSpeech`) so it can be tuned from real data.
    private static let speechRMSThreshold: Float = 0.007

    /// xAI / WhisperKit streaming session state and start/stop decisions.
    private let streamingCoordinator = StreamingCoordinator()

    /// Off-main queue for concatenating buffers, writing CAF, and retention copy.
    private let audioIOQueue = DispatchQueue(label: "com.matt.voice-dictation.audio-io", qos: .userInitiated)

    /// Speaker-gating stream processor — allocated only when gating is active
    /// (enabled setting + stored profile). Nil otherwise for zero overhead.
    private var voiceGateProcessor: VoiceGateStreamProcessor?
    private lazy var voiceGateEmbeddingProvider: FluidAudioEmbeddingProvider = FluidAudioEmbeddingProvider()
    private let voiceGateProfileStore = VoiceProfileStore()
    private let voiceGateRecordingSession = VoiceGateRecordingSession()

    /// Publishes in-memory speaker-gate telemetry snapshots on the main queue.
    var voiceGateTelemetryPublisher: ((VoiceGateTelemetrySnapshot) -> Void)?

    /// Main-run-loop poll for mid-hold secure input. Must never run Carbon
    /// checks on the realtime audio-tap thread.
    private var secureInputPollTimer: Timer?

    /// Held-caret generation from `onRecordingWillStart` for this start attempt.
    /// Promoted to `activeHeldCaretToken` when capture actually starts; cleared
    /// (token-matched) on start failure / skip before promote.
    private var pendingHeldCaretToken: UInt64?

    /// Held-caret generation for the in-flight recording session after capture
    /// has started. Stop/abort/silence/empty/write-fail paths clear matching
    /// this token only — never unscoped — so a late teardown cannot wipe a
    /// newer hold from a rapid re-press.
    private var activeHeldCaretToken: UInt64?

    /// AudioRecorder-owned hold triples keyed by session token, frozen when
    /// each token is assigned. `sampleActiveSessionHold` reads this map —
    /// never a live pipeline slot that a newer will-start can steal. Per-token
    /// so session B's cache write cannot erase session A's frozen triple.
    private var cachedSessionHolds: [UInt64: (snapshot: CaretContext.Snapshot?, pid: pid_t?)] = [:]

    /// Pure decision seam for the mid-hold secure-input abort — extracted so
    /// it can be exercised in unit tests, since `IsSecureEventInputEnabled`
    /// (Carbon) cannot be forced on in a test.
    ///
    /// Returns true when an in-flight capture must be aborted: secure input
    /// became active while we were already recording.
    static func shouldAbortForSecureInput(secureInput: Bool, isRecording: Bool) -> Bool {
        secureInput && isRecording
    }

    /// Clears the held caret for this start attempt (token-matched). No-op when
    /// pending is nil — never falls back to unscoped clear (that would wipe a
    /// newer session's hold).
    private func clearPendingHeldCaretSnapshot() {
        if let token = pendingHeldCaretToken {
            asrSelector.clearHeldCaretSnapshot(matching: token)
            clearCachedSessionHold(matching: token)
        }
        pendingHeldCaretToken = nil
    }

    /// Promotes pending → active when mic/stream capture actually begins.
    /// Idempotent: a second call with nil pending (WhisperKit stream-start
    /// promote, then async fallback → `startMicCapture`) must not wipe an
    /// already-active session token.
    private func promotePendingHeldCaretToActive() {
        let next = Self.heldCaretTokensAfterPromote(
            active: activeHeldCaretToken,
            pending: pendingHeldCaretToken
        )
        activeHeldCaretToken = next.active
        pendingHeldCaretToken = next.pending
    }

    /// Async write-fail / late teardown: clear matching a token captured when
    /// the session owned the hold, then drop `active` / `pending` only if
    /// they still match that token.
    private func clearHeldCaretSnapshotMatchingSession(_ token: UInt64?) {
        guard let token else { return }
        asrSelector.clearHeldCaretSnapshot(matching: token)
        if activeHeldCaretToken == token {
            activeHeldCaretToken = nil
        }
        if pendingHeldCaretToken == token {
            pendingHeldCaretToken = nil
        }
        clearCachedSessionHold(matching: token)
    }

    /// Freeze the pipeline hold into the session cache immediately when a
    /// token is assigned (will-start → `startRecording`). Hops to main because
    /// the event-tap path may call `startRecording` off-main.
    private func cacheHoldForAssignedToken(_ token: UInt64?) {
        guard let token else { return }
        let store: () -> Void = { [weak self] in
            guard let self else { return }
            let (snapshot, pid) = self.asrSelector.copyHeldCaretMatching(token)
            self.cachedSessionHolds = Self.insertCachedSessionHold(
                into: self.cachedSessionHolds,
                token: token,
                snapshot: snapshot,
                pid: pid
            )
        }
        if Thread.isMainThread {
            store()
        } else {
            DispatchQueue.main.sync(execute: store)
        }
    }

    private func clearCachedSessionHold(matching token: UInt64) {
        cachedSessionHolds = Self.removeCachedSessionHold(
            from: cachedSessionHolds,
            token: token
        )
    }

    /// Sample this session's hold (token + snapshot + PID) on main at recording
    /// stop — before streaming finalize / audio-IO async gaps that can race a
    /// newer will-start hold. Prefers pending when both slots differ (stale
    /// active from an uncleared prior take must not win); else active, else
    /// pending (stop-before-promote). Does not re-query a live pipeline slot.
    private func sampleActiveSessionHold() -> (
        token: UInt64?,
        snapshot: CaretContext.Snapshot?,
        pid: pid_t?
    ) {
        assert(Thread.isMainThread, "sampleActiveSessionHold requires main thread")
        return Self.sampleCachedSessionHold(
            activeToken: Self.preferredSessionHoldToken(
                active: activeHeldCaretToken,
                pending: pendingHeldCaretToken
            ),
            cache: cachedSessionHolds
        )
    }

    /// After inject pipeline finishes a take: drop that take's AudioRecorder
    /// session slots + cache entry. Token-matched so a newer pending that
    /// differs from the consumed token is preserved. Does not touch the live
    /// pipeline hold (inject already cleared it on success paths).
    private func clearConsumedSessionHold(sampledToken: UInt64?) {
        let clearToken = Self.consumedSessionHoldClearToken(
            sampled: sampledToken,
            active: activeHeldCaretToken,
            pending: pendingHeldCaretToken
        )
        guard let clearToken else { return }
        let next = Self.sessionHoldStateAfterConsume(
            active: activeHeldCaretToken,
            pending: pendingHeldCaretToken,
            cache: cachedSessionHolds,
            clearToken: clearToken
        )
        activeHeldCaretToken = next.active
        pendingHeldCaretToken = next.pending
        cachedSessionHolds = next.cache
    }

    /// Testable seam: promote is a no-op when pending is nil so an already-
    /// active token survives WhisperKit fallback re-entry.
    internal static func heldCaretTokensAfterPromote(
        active: UInt64?,
        pending: UInt64?
    ) -> (active: UInt64?, pending: UInt64?) {
        guard let pending else {
            return (active, nil)
        }
        return (pending, nil)
    }

    /// Prefer pending when both slots are set and differ (newer session wins
    /// over a stale uncleared active from a prior take). Otherwise
    /// `active ?? pending` (stop-before-promote / single-slot cases).
    internal static func preferredSessionHoldToken(
        active: UInt64?,
        pending: UInt64?
    ) -> UInt64? {
        if let pending, active != nil, pending != active {
            return pending
        }
        return active ?? pending
    }

    /// Testable seam: teardown clear token selection — same preference as
    /// sample (never unscoped when a session token is known).
    internal static func teardownHeldCaretClearToken(
        active: UInt64?,
        pending: UInt64?
    ) -> UInt64? {
        preferredSessionHoldToken(active: active, pending: pending)
    }

    /// Tokens to clear on mid-hold secure abort.
    ///
    /// When active≠pending and recording was still wanted (re-press already
    /// armed a newer hold), clear **only** the aborted active capture so the
    /// pending hold survives. When not re-armed and both differ, clear both
    /// (full abort of in-flight holds). Otherwise the single preferred token
    /// from `teardownHeldCaretClearToken`.
    internal static func secureAbortClearTokens(
        active: UInt64?,
        pending: UInt64?,
        wantsRecording: Bool
    ) -> [UInt64] {
        if let active, let pending, pending != active {
            if wantsRecording {
                return [active]
            }
            return [active, pending]
        }
        if let token = teardownHeldCaretClearToken(active: active, pending: pending) {
            return [token]
        }
        return []
    }

    /// Token to clear after a take finishes inject: prefer the stop-sampled
    /// token; when sampled is nil, same preference as
    /// `preferredSessionHoldToken` (pending when active≠pending).
    internal static func consumedSessionHoldClearToken(
        sampled: UInt64?,
        active: UInt64?,
        pending: UInt64?
    ) -> UInt64? {
        if let sampled { return sampled }
        return preferredSessionHoldToken(active: active, pending: pending)
    }

    /// Pure consume: nil matching slots + remove cache entry for `clearToken`
    /// without wiping an unrelated newer pending/active that differs.
    internal static func sessionHoldStateAfterConsume(
        active: UInt64?,
        pending: UInt64?,
        cache: [UInt64: (snapshot: CaretContext.Snapshot?, pid: pid_t?)],
        clearToken: UInt64
    ) -> (
        active: UInt64?,
        pending: UInt64?,
        cache: [UInt64: (snapshot: CaretContext.Snapshot?, pid: pid_t?)]
    ) {
        (
            active == clearToken ? nil : active,
            pending == clearToken ? nil : pending,
            removeCachedSessionHold(from: cache, token: clearToken)
        )
    }

    /// Testable seam: skip a queued `doStop` when a newer stop superseded it
    /// or a re-press already re-armed `wantsRecording`.
    internal static func shouldSkipStaleDoStop(
        wantsRecording: Bool,
        capturedGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        wantsRecording || capturedGeneration != currentGeneration
    }

    /// Testable seam: one-entry cache map for a session token (mirrors the
    /// insert performed by `cacheHoldForAssignedToken`).
    internal static func makeCachedSessionHold(
        token: UInt64,
        snapshot: CaretContext.Snapshot?,
        pid: pid_t?
    ) -> [UInt64: (snapshot: CaretContext.Snapshot?, pid: pid_t?)] {
        [token: (snapshot, pid)]
    }

    /// Testable seam: insert/update one token without erasing other entries.
    internal static func insertCachedSessionHold(
        into cache: [UInt64: (snapshot: CaretContext.Snapshot?, pid: pid_t?)],
        token: UInt64,
        snapshot: CaretContext.Snapshot?,
        pid: pid_t?
    ) -> [UInt64: (snapshot: CaretContext.Snapshot?, pid: pid_t?)] {
        var next = cache
        next[token] = (snapshot, pid)
        return next
    }

    /// Testable seam: remove one token's cache entry; leave others intact.
    internal static func removeCachedSessionHold(
        from cache: [UInt64: (snapshot: CaretContext.Snapshot?, pid: pid_t?)],
        token: UInt64
    ) -> [UInt64: (snapshot: CaretContext.Snapshot?, pid: pid_t?)] {
        var next = cache
        next.removeValue(forKey: token)
        return next
    }

    /// Testable seam: stop-time sample prefers the cached triple for the
    /// active (or pending) session token over any live pipeline slot a later
    /// hold stole.
    internal static func sampleCachedSessionHold(
        activeToken: UInt64?,
        cache: [UInt64: (snapshot: CaretContext.Snapshot?, pid: pid_t?)]
    ) -> (token: UInt64?, snapshot: CaretContext.Snapshot?, pid: pid_t?) {
        guard let activeToken else {
            return (nil, nil, nil)
        }
        guard let entry = cache[activeToken] else {
            return (activeToken, nil, nil)
        }
        return (activeToken, entry.snapshot, entry.pid)
    }

    // MARK: - Public interface

    func startRecording(heldCaretToken: UInt64? = nil) {
        pendingHeldCaretToken = heldCaretToken
        // Freeze hold immediately while this token still owns the pipeline
        // slot — a rapid re-press can steal the live slot before stop samples.
        cacheHoldForAssignedToken(heldCaretToken)
        if IsSecureEventInputEnabled() {
            logger.info("Secure input active — refusing to start capture.")
            clearPendingHeldCaretSnapshot()
            DispatchQueue.main.async { [weak self] in
                self?.asrSelector.onFailure?(.secureInputBlocked)
            }
            return
        }
        wantsRecording = true
        isStopping = false
        vlog("AudioRecorder.startRecording — requesting mic permission")
        requestMicrophonePermissionIfNeeded { [weak self] granted in
            vlog("mic permission callback — granted=\(granted)")
            guard let self = self, granted else {
                self?.logger.error("Microphone permission denied.")
                self?.clearPendingHeldCaretSnapshot()
                DispatchQueue.main.async {
                    self?.asrSelector.onFailure?(.micStartFailed)
                }
                return
            }
            DispatchQueue.main.async {
                guard self.wantsRecording else {
                    self.logger.info("Mic permission resolved after stopRecording() — skipping start.")
                    self.clearPendingHeldCaretSnapshot()
                    return
                }
                self.doStart()
            }
        }
    }

    func stopRecording() {
        wantsRecording = false
        stopGeneration &+= 1
        let generation = stopGeneration
        invalidateSecureInputPollTimer()
        endVoiceGateRecordingSession()
        DispatchQueue.main.async { [weak self] in
            self?.doStop(capturedGeneration: generation)
        }
    }

    /// Pushes live speaker-gating settings from `SettingsStore`. Active only
    /// when `enabled` is true AND a profile exists on disk.
    func updateSpeakerGating(enabled: Bool, sensitivity: VoiceGateSensitivity) {
        let hasProfile = voiceGateProfileStore.load() != nil
        if enabled, hasProfile {
            if voiceGateProcessor == nil {
                let gate = VoiceGate(
                    profileStore: voiceGateProfileStore,
                    embeddingProvider: voiceGateEmbeddingProvider,
                    sensitivity: sensitivity
                )
                voiceGateProcessor = VoiceGateStreamProcessor(
                    gate: gate,
                    recordingSession: voiceGateRecordingSession,
                    onTelemetryUpdate: { [weak self] in
                        guard let self else { return }
                        let snapshot = self.voiceGateRecordingSession.snapshot()
                        self.voiceGateTelemetryPublisher?(snapshot)
                    }
                )
            } else {
                voiceGateProcessor?.updateSensitivity(sensitivity)
            }
            voiceGateProcessor?.isActive = true
        } else {
            // End the shared session before dropping the processor — otherwise
            // a mid-hold Focus disable / profile clear leaves isSessionActive
            // stuck true (Settings "listening…" forever) and in-flight evals
            // can still commit.
            voiceGateProcessor?.isActive = false
            endVoiceGateRecordingSession()
            voiceGateProcessor = nil
        }
    }

    /// Ends the shared gate recording session on every teardown path, including
    /// when the stream processor is nil. Session lifetime is independent of the
    /// optional processor so Focus disable / profile clear / stop / secure-input
    /// abort cannot leave telemetry stuck active. `end()` still bumps the
    /// generation token so in-flight evaluations cannot commit.
    private func endVoiceGateRecordingSession() {
        Self.endGateRecordingSession(
            session: voiceGateRecordingSession,
            processor: voiceGateProcessor,
            onSessionEndedWithoutProcessor: { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.voiceGateTelemetryPublisher?(self.voiceGateRecordingSession.snapshot())
                }
            }
        )
    }

    /// Testable seam for gate-session teardown. Prefer the processor when
    /// present (resets latch/accumulator + publishes via its callback); otherwise
    /// end the shared session directly and invoke `onSessionEndedWithoutProcessor`.
    internal static func endGateRecordingSession(
        session: VoiceGateRecordingSession,
        processor: VoiceGateStreamProcessor?,
        onSessionEndedWithoutProcessor: (() -> Void)? = nil
    ) {
        if let processor {
            processor.endRecordingSession()
        } else {
            session.end()
            onSessionEndedWithoutProcessor?()
        }
    }

    /// Whether doStart / startMicCapture may proceed for the current hold.
    /// Keyed only on `wantsRecording`. `isStopping` is accepted so callers and
    /// tests can pass the sticky stop flag from a prior hold, but it must
    /// **not** veto — doStop on main can set it after a newer startRecording
    /// already re-armed the hold on the event-tap thread (rapid re-press).
    internal static func shouldProceedWithRecordingStart(
        wantsRecording: Bool,
        isStopping: Bool
    ) -> Bool {
        _ = isStopping
        return wantsRecording
    }

    /// Testable seam: begin a gate recording session only while the hold is
    /// still wanted. Mirrors WhisperKit's `guard wantsRecording()` before
    /// late fallback so a permission/async start that lost the race to
    /// `stopRecording` cannot re-activate telemetry "listening…".
    /// Does **not** let sticky `isStopping` block a still-wanted re-press.
    @discardableResult
    internal static func beginGateRecordingSessionIfWanted(
        wantsRecording: Bool,
        isStopping: Bool,
        begin: () -> Void
    ) -> Bool {
        guard shouldProceedWithRecordingStart(
            wantsRecording: wantsRecording,
            isStopping: isStopping
        ) else {
            return false
        }
        begin()
        return true
    }

    // MARK: - Internal

    private func doStart() {
        // Re-check after the permission hop / main dispatch — stopRecording may
        // have cleared wantsRecording on the event-tap thread already.
        // Do not veto on isStopping: doStop may have set it sticky for a prior
        // hold while this hold already re-armed wantsRecording on the tap thread.
        guard Self.shouldProceedWithRecordingStart(
            wantsRecording: wantsRecording,
            isStopping: isStopping
        ) else {
            logger.info("doStart skipped — recording no longer wanted")
            vlog("doStart skipped — wantsRecording=false")
            clearPendingHeldCaretSnapshot()
            return
        }
        isStopping = false
        streamingCoordinator.resetStreamTextLatch()
        playFeedbackSound(named: "Tink")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let label = self.activationKeyLabelProvider?() {
                self.hud.setActivationKeyLabel(label)
            }
            self.hud.show()
        }
        startTime = Date()

        if streamingCoordinator.tryStartXAI(asrSelector: asrSelector, startMicCapture: { [weak self] in
            self?.startMicCapture()
        }) {
            return
        }

        if streamingCoordinator.tryStartElevenLabs(asrSelector: asrSelector, startMicCapture: { [weak self] in
            self?.startMicCapture()
        }) {
            return
        }

        if streamingCoordinator.tryStartWhisperKit(
            asrSelector: asrSelector,
            wantsRecording: { [weak self] in self?.wantsRecording ?? false },
            levelCallback: { [weak self] level in self?.hud.pushLevel(level) },
            fallbackToFileBased: { [weak self] in self?.startMicCapture() }
        ) {
            // WhisperKit owns the mic — still poll secure input mid-hold.
            promotePendingHeldCaretToActive()
            startSecureInputPollTimer()
            return
        }

        vlog("doStart — streaming ineligible, using file-based path")
        startMicCapture()
    }

    /// Installs the mic tap and starts the engine. The tap forks per buffer:
    /// it ALWAYS computes the RMS level for the reactive HUD waveform, then —
    /// in xAI streaming mode — converts + streams the buffer to the socket, or
    /// — in file mode — copies it into `pcmBuffers` for a post-release .caf
    /// transcribe. One mic engine backs both paths so the live pill animates
    /// identically regardless of which transcription backend is active.
    private func startMicCapture() {
        // Defense in depth for WhisperKit fallback / late doStart: do not
        // begin a gate session (or start the engine) after the hold ended.
        // Keyed on wantsRecording only — sticky isStopping from a prior
        // doStop must not block a still-wanted re-press.
        guard Self.beginGateRecordingSessionIfWanted(
            wantsRecording: wantsRecording,
            isStopping: isStopping,
            begin: { [weak self] in
                self?.voiceGateProcessor?.beginRecordingSession()
            }
        ) else {
            logger.info("startMicCapture skipped — recording no longer wanted")
            vlog("startMicCapture skipped — wantsRecording=false")
            clearPendingHeldCaretSnapshot()
            return
        }

        vlog("startMicCapture — AVAudioEngine begins capture")
        pcmBuffersLock.lock()
        pcmBuffers.removeAll()
        pcmBuffersLock.unlock()

        levelLock.lock()
        maxLevelObserved = 0
        levelLock.unlock()

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Avoid double-installing a tap
        if !isSetUp {
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                guard let self = self else { return }

                // Realtime-thread safe: compute smoothed RMS amplitude and
                // publish it for the HUD waveform. Only a Float + a lock — no
                // AppKit access on this thread. Done in BOTH modes.
                if let channelData = buffer.floatChannelData {
                    let frameCount = Int(buffer.frameLength)
                    if frameCount > 0 {
                        var sum: Float = 0
                        let samples = channelData[0]
                        for i in 0 ..< frameCount {
                            let s = samples[i]
                            sum += s * s
                        }
                        self.publishLevel(sqrt(sum / Float(frameCount)))
                    }
                }

                // Speaker gating: attenuate native buffer before downstream
                // pcmBuffers / streaming when the latched decision says so.
                // RMS/HUD level above uses the pre-attenuation buffer.
                self.voiceGateProcessor?.processBuffer(buffer)

                // ALWAYS buffer a copy of the audio — this is the safety net.
                // If a streaming session fails mid-utterance (socket drops,
                // handshake error), the file/batch fallback can still
                // transcribe the FULL audio instead of losing the front of it.
                // On the streaming-success path these buffers are simply
                // discarded. Cheap for typical push-to-talk holds. The copy is
                // required because `buffer` doesn't outlive this callback.
                if let copy = AVAudioPCMBuffer(
                    pcmFormat: buffer.format,
                    frameCapacity: buffer.frameLength
                ) {
                    copy.frameLength = buffer.frameLength
                    if let srcChannelData = buffer.floatChannelData,
                       let dstChannelData = copy.floatChannelData {
                        for ch in 0 ..< Int(buffer.format.channelCount) {
                            memcpy(
                                dstChannelData[ch],
                                srcChannelData[ch],
                                Int(buffer.frameLength) * MemoryLayout<Float>.size
                            )
                        }
                    }
                    self.pcmBuffersLock.lock()
                    self.pcmBuffers.append(copy)
                    self.pcmBuffersLock.unlock()
                }

                // Streaming mode: ALSO convert + stream this buffer to the
                // socket (the session consumes it synchronously). Only one of
                // xAI/ElevenLabs is ever active (both gated on the same
                // single-value `cloudModel` selection), so both sends are
                // safe no-ops when their session is nil.
                self.streamingCoordinator.sendToXAI(buffer)
                self.streamingCoordinator.sendToElevenLabs(buffer)
            }
            isSetUp = true
        }

        do {
            try engine.start()
            logger.info("AVAudioEngine started — recording…")
            promotePendingHeldCaretToActive()
            startSecureInputPollTimer()
        } catch {
            logger.error("AVAudioEngine start failed: \(error.localizedDescription)")
            invalidateSecureInputPollTimer()
            // beginRecordingSession already ran above — clear so Settings does
            // not stick on "listening…" after a failed engine start.
            endVoiceGateRecordingSession()
            clearPendingHeldCaretSnapshot()
            DispatchQueue.main.async { [weak self] in
                self?.asrSelector.onFailure?(.micStartFailed)
                self?.hud.hide()
            }
        }
    }

    private func startSecureInputPollTimer() {
        invalidateSecureInputPollTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if Self.shouldAbortForSecureInput(
                secureInput: IsSecureEventInputEnabled(),
                isRecording: self.wantsRecording && !self.isStopping
            ) {
                self.abortForSecureInput()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        secureInputPollTimer = timer
    }

    private func invalidateSecureInputPollTimer() {
        secureInputPollTimer?.invalidate()
        secureInputPollTimer = nil
    }

    /// Mid-hold secure-input abort: tear down capture/stream and discard audio.
    /// Must not write a file, transcribe, or retain the recording.
    private func abortForSecureInput() {
        invalidateSecureInputPollTimer()
        // Capture before clearing wantsRecording — a re-press may already own
        // a newer pending hold that must not be wiped with the aborted active.
        let abortWantsRecording = wantsRecording
        let abortActive = activeHeldCaretToken
        let abortPending = pendingHeldCaretToken
        wantsRecording = false
        isStopping = true
        logger.info("Secure input active mid-hold — aborting capture.")
        vlog("abortForSecureInput — tearing down mic + streaming")
        endVoiceGateRecordingSession()
        teardownMicEngine()
        pcmBuffersLock.lock()
        pcmBuffers.removeAll(keepingCapacity: false)
        pcmBuffersLock.unlock()
        streamingCoordinator.cancelAll()
        for token in Self.secureAbortClearTokens(
            active: abortActive,
            pending: abortPending,
            wantsRecording: abortWantsRecording
        ) {
            clearHeldCaretSnapshotMatchingSession(token)
        }
        DispatchQueue.main.async { [weak self] in
            self?.hud.hide()
            self?.asrSelector.onFailure?(.secureInputBlocked)
        }
    }

    private func doStop(capturedGeneration: UInt64) {
        // Re-press may have re-armed wantsRecording (or a newer stop bumped
        // stopGeneration) before this queued stop drains — do not tear down
        // the newer session's mic/stream/hold/cache.
        if Self.shouldSkipStaleDoStop(
            wantsRecording: wantsRecording,
            capturedGeneration: capturedGeneration,
            currentGeneration: stopGeneration
        ) {
            logger.info("doStop skipped — stale generation or recording re-armed")
            vlog("doStop skipped — wantsRecording=\(wantsRecording) gen=\(capturedGeneration)/\(stopGeneration)")
            return
        }
        if isStopping {
            invalidateSecureInputPollTimer()
            logger.info("doStop ignored — stop already in progress")
            vlog("doStop ignored — already stopping")
            return
        }
        isStopping = true
        invalidateSecureInputPollTimer()
        // Belt-and-suspenders: a late doStart/startMicCapture that lost the
        // race to stopRecording may have re-begun the session after the
        // synchronous end in stopRecording. Re-end only when still active so
        // we do not double-publish when stopRecording already cleared it.
        if voiceGateRecordingSession.snapshot().isSessionActive {
            endVoiceGateRecordingSession()
        }

        playFeedbackSound(named: "Pop")
        hud.clearInterimText()
        // Flip to processing immediately at fn-release so the pill shows
        // "working on it" while ASR runs, rather than vanishing abruptly.
        // For the streaming path this is normally near-instant (the ASR
        // already ran during the hold) — still set for visual consistency
        // and to cover the brief finalize step.
        DispatchQueue.main.async { [weak self] in self?.hud.setProcessing() }

        pcmBuffersLock.lock()
        let bufferedAudio = pcmBuffers
        pcmBuffersLock.unlock()
        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0

        // Capture hold before streaming finalize / file-IO Tasks so a rapid
        // re-press cannot poison inject with a newer will-start snapshot.
        let sessionHold = sampleActiveSessionHold()

        if streamingCoordinator.xaiSession != nil || streamingCoordinator.elevenLabsSession != nil {
            teardownMicEngine()
        }

        let streamTextEver = streamingCoordinator.coordinatorEverHadStreamText
            || (streamingCoordinator.xaiSession?.hasEverHadNonEmptyStreamText ?? false)
            || (streamingCoordinator.elevenLabsSession?.hasEverHadNonEmptyStreamText ?? false)

        let xaiContext = StreamingCoordinator.XAIStopContext(
            duration: elapsed,
            hadSpeech: recordingHadSpeech(),
            bufferedAudio: bufferedAudio,
            streamTextEver: streamTextEver
        )
        if streamingCoordinator.handleStopXAI(
            context: xaiContext,
            onSilence: { [weak self] in
                self?.finishDiscardedHold(
                    reason: "silence-guard",
                    engineID: "cloud:xai-streaming",
                    sessionHeldToken: sessionHold.token
                )
            },
            onStreamSuccess: { [weak self] text in
                self?.asrSelector.logStreamedTranscription(
                    text: text,
                    engineID: "cloud:xai-streaming",
                    sessionHeldToken: sessionHold.token,
                    sessionHeldSnapshot: sessionHold.snapshot,
                    sessionHeldFrontmostPID: sessionHold.pid
                ) { [weak self] result in
                    self?.finishHUDAfterPipeline(
                        result: result,
                        sessionHeldToken: sessionHold.token
                    )
                }
            },
            onBatchFallback: { [weak self] buffers, duration in
                guard let self = self else { return }
                guard !buffers.isEmpty else {
                    self.finishDiscardedHold(
                        reason: "empty-buffer-abort",
                        engineID: "cloud:xai-streaming",
                        sessionHeldToken: sessionHold.token
                    )
                    return
                }
                self.writeToFile(
                    duration: duration,
                    buffers: buffers,
                    sessionHeldToken: sessionHold.token,
                    sessionHeldSnapshot: sessionHold.snapshot,
                    sessionHeldFrontmostPID: sessionHold.pid
                )
            }
        ) {
            return
        }

        let elevenLabsContext = StreamingCoordinator.ElevenLabsStopContext(
            duration: elapsed,
            hadSpeech: recordingHadSpeech(),
            bufferedAudio: bufferedAudio,
            streamTextEver: streamTextEver
        )
        if streamingCoordinator.handleStopElevenLabs(
            context: elevenLabsContext,
            onSilence: { [weak self] in
                self?.finishDiscardedHold(
                    reason: "silence-guard",
                    engineID: "cloud:elevenlabs-streaming",
                    sessionHeldToken: sessionHold.token
                )
            },
            onStreamSuccess: { [weak self] text in
                self?.asrSelector.logStreamedTranscription(
                    text: text,
                    engineID: "cloud:elevenlabs-streaming",
                    sessionHeldToken: sessionHold.token,
                    sessionHeldSnapshot: sessionHold.snapshot,
                    sessionHeldFrontmostPID: sessionHold.pid
                ) { [weak self] result in
                    self?.finishHUDAfterPipeline(
                        result: result,
                        sessionHeldToken: sessionHold.token
                    )
                }
            },
            onBatchFallback: { [weak self] buffers, duration in
                guard let self = self else { return }
                guard !buffers.isEmpty else {
                    self.finishDiscardedHold(
                        reason: "empty-buffer-abort",
                        engineID: "cloud:elevenlabs-streaming",
                        sessionHeldToken: sessionHold.token
                    )
                    return
                }
                self.writeToFile(
                    duration: duration,
                    buffers: buffers,
                    sessionHeldToken: sessionHold.token,
                    sessionHeldSnapshot: sessionHold.snapshot,
                    sessionHeldFrontmostPID: sessionHold.pid
                )
            }
        ) {
            return
        }

        if streamingCoordinator.handleStopWhisperKit(
            onEmpty: { [weak self] in
                self?.finishDiscardedHold(
                    reason: "stream-empty",
                    engineID: "whisperKit:streaming",
                    sessionHeldToken: sessionHold.token
                )
            },
            onSuccess: { [weak self] text in
                self?.asrSelector.logStreamedTranscription(
                    text: text,
                    engineID: "whisperKit:streaming",
                    sessionHeldToken: sessionHold.token,
                    sessionHeldSnapshot: sessionHold.snapshot,
                    sessionHeldFrontmostPID: sessionHold.pid
                ) { [weak self] result in
                    self?.finishHUDAfterPipeline(
                        result: result,
                        sessionHeldToken: sessionHold.token
                    )
                }
            }
        ) {
            return
        }

        stopFileBasedCapture(
            sessionHeldToken: sessionHold.token,
            sessionHeldSnapshot: sessionHold.snapshot,
            sessionHeldFrontmostPID: sessionHold.pid,
            everHadStreamText: streamTextEver
                || streamingCoordinator.coordinatorEverHadStreamText
        )
    }

    /// Teardown for the file-based (tap+buffer) path — only touches the
    /// `AVAudioEngine`/tap state if `startFileBasedCapture` actually set it
    /// up, so calling this when a streaming session was active instead is
    /// always safe.
    private func stopFileBasedCapture(
        sessionHeldToken: UInt64?,
        sessionHeldSnapshot: CaretContext.Snapshot?,
        sessionHeldFrontmostPID: pid_t?,
        everHadStreamText: Bool = false
    ) {
        guard isSetUp else {
            finishDiscardedHold(
                reason: "mic-not-setup",
                engineID: "file",
                sessionHeldToken: sessionHeldToken
            )
            return
        }

        teardownMicEngine()

        pcmBuffersLock.lock()
        let capturedBuffers = pcmBuffers
        pcmBuffersLock.unlock()

        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        logger.info("Recording stopped — duration \(String(format: "%.2f", elapsed))s, \(capturedBuffers.count) buffers")

        guard !capturedBuffers.isEmpty else {
            logger.warning("No audio captured.")
            vlog("file path: empty-buffer abort — no pcmBuffers")
            finishDiscardedHold(
                reason: "empty-buffer-abort",
                engineID: "file",
                sessionHeldToken: sessionHeldToken
            )
            return
        }

        // Non-empty pcmBuffers always proceed to writeToFile — RMS silence
        // cancel only applies when buffers are empty (handled above). Logs
        // quiet-mic bypass for VOICE_DEBUG correlation.
        if !recordingHadSpeech() {
            vlog(
                "file path: silence bypass — buffers=\(capturedBuffers.count) everHadStream=\(everHadStreamText) maxRMS below threshold"
            )
        }

        writeToFile(
            duration: elapsed,
            buffers: capturedBuffers,
            sessionHeldToken: sessionHeldToken,
            sessionHeldSnapshot: sessionHeldSnapshot,
            sessionHeldFrontmostPID: sessionHeldFrontmostPID
        )
    }

    /// Tombstone a hold that produced nothing injectable — failed history row
    /// via existing `onTranscriptionLogged` (no parallel HistoryStore write).
    /// Display-only (nil audioPath); does not play failure sound (avoids Basso
    /// on every accidental empty hold).
    private func finishDiscardedHold(
        reason: String,
        engineID: String,
        sessionHeldToken: UInt64?
    ) {
        vlog("discarded hold — reason=\(reason) engine=\(engineID)")
        clearHeldCaretSnapshotMatchingSession(sessionHeldToken)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.asrSelector.onTranscriptionLogged?(
                "",
                engineID,
                false,
                nil,
                true,
                nil
            )
            self.hud.hide()
        }
    }

    /// Stops the engine and removes the mic tap. Shared by the file path's
    /// teardown and the xAI-streaming stop (which needs the tap gone before it
    /// finalizes the socket). Safe to call when no tap is installed.
    private func teardownMicEngine() {
        guard isSetUp else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isSetUp = false
    }

    /// Whether the just-finished recording contained real speech — i.e. its
    /// loudest buffer crossed `speechRMSThreshold`. Used to gate silent holds
    /// out of the ASR entirely (see `maxLevelObserved`). Logs the observed max
    /// each time so the threshold can be calibrated from real recordings.
    private func recordingHadSpeech() -> Bool {
        levelLock.lock()
        let maxLevel = maxLevelObserved
        levelLock.unlock()
        vlog("recording max RMS \(String(format: "%.4f", maxLevel)) (threshold \(String(format: "%.4f", Self.speechRMSThreshold)))")
        return maxLevel >= Self.speechRMSThreshold
    }

    // MARK: - Mic level publishing (audio-reactive waveform)

    /// Called from the realtime audio-tap thread with a raw per-buffer RMS.
    /// Applies a light exponential smoother, guarded by a lock (no
    /// allocation, no AppKit access), then hops to main to push the value
    /// into the HUD's waveform.
    private func publishLevel(_ rawRMS: Float) {
        levelLock.lock()
        // Track the loudest raw buffer of the recording for the silence gate
        // (see maxLevelObserved) — done here under the same lock so the audio
        // thread never takes a second lock.
        if rawRMS > maxLevelObserved { maxLevelObserved = rawRMS }
        // Fast attack / slower decay smoothing done again at the HUD layer;
        // here we just do a light single-pole smoother to de-noise the raw
        // per-buffer RMS before it crosses threads.
        let alpha: Float = rawRMS > smoothedLevel ? 0.6 : 0.3
        smoothedLevel = smoothedLevel + (rawRMS - smoothedLevel) * alpha
        let level = smoothedLevel
        levelLock.unlock()

        // Map smoothed RMS to a 0…1 bar level. This mic runs quiet (measured
        // speech peaks only ~0.02 raw RMS), so subtract a small noise floor to
        // keep room tone flat, then apply a high gain so normal speech clearly
        // drives the bars toward full. Tuned from logged levels; revisit if a
        // hotter mic saturates the bars instantly.
        let normalized = min(1.0, max(0, level - 0.003) * 50)

        DispatchQueue.main.async { [weak self] in
            self?.hud.pushLevel(normalized)
        }
    }

    // MARK: - Write captured audio

    private func writeToFile(
        duration: TimeInterval,
        buffers: [AVAudioPCMBuffer],
        sessionHeldToken: UInt64?,
        sessionHeldSnapshot: CaretContext.Snapshot?,
        sessionHeldFrontmostPID: pid_t?
    ) {
        guard let first = buffers.first else { return }
        let format = first.format
        // Snapshot buffers for the IO queue — do not touch AVAudioFile / retain on main.
        let buffersCopy = buffers
        // Hold triple was sampled at stop (before this async IO). Token alone
        // still scopes write-fail clears if a newer hold already promoted.

        audioIOQueue.async { [weak self] in
            guard let self = self else { return }

            let totalFrames = buffersCopy.reduce(0) { $0 + AVAudioFrameCount($1.frameLength) }

            guard let combined = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
                self.logger.error("Failed to allocate combined buffer (\(totalFrames) frames)")
                DispatchQueue.main.async {
                    self.clearHeldCaretSnapshotMatchingSession(sessionHeldToken)
                    self.asrSelector.onTranscriptionLogged?(
                        "",
                        "file",
                        false,
                        nil,
                        true,
                        nil
                    )
                    self.asrSelector.onFailure?(.audioWriteFailed)
                    self.hud.hide()
                }
                return
            }
            combined.frameLength = 0

            // Concatenate
            if let dst = combined.floatChannelData {
                var offset = AVAudioFrameCount(0)
                for buf in buffersCopy {
                    if let src = buf.floatChannelData {
                        for ch in 0 ..< Int(format.channelCount) {
                            memcpy(
                                dst[ch].advanced(by: Int(offset)),
                                src[ch],
                                Int(buf.frameLength) * MemoryLayout<Float>.size
                            )
                        }
                    }
                    offset += buf.frameLength
                }
                combined.frameLength = offset
            }

            // Write to /tmp
            let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("voice-\(Int(Date().timeIntervalSince1970)).caf")

            do {
                let file = try AVAudioFile(
                    forWriting: tmpURL,
                    settings: format.settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
                try file.write(from: combined)
                self.logger.info("Audio written: \(tmpURL.path) (\(String(format: "%.2f", duration))s)")
                vlog("Audio file: \(tmpURL.path)  duration: \(String(format: "%.2f", duration))s")

                // Copy into Application Support before transcription so failure
                // history rows and retry always reference a stable path — the
                // ephemeral /tmp file is removed in the completion handler.
                let keepPaths = self.protectedAudioPathsProvider?() ?? []
                let maxBytes = self.recordingBudgetBytesProvider?()
                    ?? Int64(RecordingRetention.defaultBudgetMB) * 1024 * 1024
                guard let retainedURL = RecordingRetention.retain(
                    from: tmpURL,
                    keepPaths: keepPaths,
                    maxBytes: maxBytes
                ) else {
                    self.logger.error("Failed to retain recording for transcription.")
                    try? FileManager.default.removeItem(at: tmpURL)
                    DispatchQueue.main.async {
                        self.clearHeldCaretSnapshotMatchingSession(sessionHeldToken)
                        self.asrSelector.onTranscriptionLogged?(
                            "",
                            "file",
                            false,
                            nil,
                            true,
                            nil
                        )
                        self.asrSelector.onFailure?(.audioWriteFailed)
                        self.hud.hide()
                    }
                    return
                }

                DispatchQueue.main.async {
                    self.asrSelector.setLastRetainedRecordingURL(retainedURL)
                    self.asrSelector.transcribeAndLog(
                        audioURL: retainedURL,
                        sessionHeldToken: sessionHeldToken,
                        sessionHeldSnapshot: sessionHeldSnapshot,
                        sessionHeldFrontmostPID: sessionHeldFrontmostPID
                    ) { [weak self] result in
                        try? FileManager.default.removeItem(at: tmpURL)
                        self?.finishHUDAfterPipeline(
                            result: result,
                            sessionHeldToken: sessionHeldToken
                        )
                    }
                }
            } catch {
                self.logger.error("Failed to write audio file: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.clearHeldCaretSnapshotMatchingSession(sessionHeldToken)
                    self.asrSelector.onTranscriptionLogged?(
                        "",
                        "file",
                        false,
                        nil,
                        true,
                        nil
                    )
                    self.asrSelector.onFailure?(.audioWriteFailed)
                    self.hud.hide()
                }
            }
        }
    }

    // MARK: - Feedback sound

    /// Inserted → success checkmark. Dedupe → neutral hide (no fake success).
    /// Failed → hide only when still `.processing` (onFailure may already flash).
    /// All terminal results clear the consumed session hold so the next press
    /// cannot sample a stale active token / cache entry.
    private func finishHUDAfterPipeline(
        result: TranscriptionPipeline.InjectPipelineResult,
        sessionHeldToken: UInt64?
    ) {
        clearConsumedSessionHold(sampledToken: sessionHeldToken)
        switch result {
        case .inserted:
            hud.showSuccessThenHide()
        case .deduped, .failed:
            if hud.isProcessing {
                hud.hide()
            }
        }
    }

    /// Plays the system Basso alert for terminal dictation failures.
    func playFailureSound() {
        guard playDictationSoundProvider?() == true else { return }
        NSSound(named: "Basso")?.play()
    }

    /// Plays a short, distinct built-in system sound if the user has "play
    /// dictation sound" enabled in Settings — `named` a different sound for
    /// start vs stop so the two are distinguishable by ear alone.
    private func playFeedbackSound(named name: NSSound.Name) {
        guard playDictationSoundProvider?() == true else { return }
        NSSound(named: name)?.play()
    }

    // MARK: - Permissions

    private func requestMicrophonePermissionIfNeeded(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                completion(granted)
            }
        case .denied, .restricted:
            logger.error("""
                Microphone permission denied. Go to System Settings → \
                Privacy & Security → Microphone and enable Murmur.
                """)
            completion(false)
        @unknown default:
            completion(false)
        }
    }
}
