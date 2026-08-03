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

    /// Pure decision seam for the mid-hold secure-input abort — extracted so
    /// it can be exercised in unit tests, since `IsSecureEventInputEnabled`
    /// (Carbon) cannot be forced on in a test.
    ///
    /// Returns true when an in-flight capture must be aborted: secure input
    /// became active while we were already recording.
    static func shouldAbortForSecureInput(secureInput: Bool, isRecording: Bool) -> Bool {
        secureInput && isRecording
    }

    // MARK: - Public interface

    func startRecording() {
        if IsSecureEventInputEnabled() {
            logger.info("Secure input active — refusing to start capture.")
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
                DispatchQueue.main.async {
                    self?.asrSelector.onFailure?(.micStartFailed)
                }
                return
            }
            DispatchQueue.main.async {
                guard self.wantsRecording else {
                    self.logger.info("Mic permission resolved after stopRecording() — skipping start.")
                    return
                }
                self.doStart()
            }
        }
    }

    func stopRecording() {
        wantsRecording = false
        invalidateSecureInputPollTimer()
        endVoiceGateRecordingSession()
        DispatchQueue.main.async { [weak self] in self?.doStop() }
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
            return
        }
        isStopping = false
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
            startSecureInputPollTimer()
        } catch {
            logger.error("AVAudioEngine start failed: \(error.localizedDescription)")
            invalidateSecureInputPollTimer()
            // beginRecordingSession already ran above — clear so Settings does
            // not stick on "listening…" after a failed engine start.
            endVoiceGateRecordingSession()
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
        DispatchQueue.main.async { [weak self] in
            self?.hud.hide()
            self?.asrSelector.onFailure?(.secureInputBlocked)
        }
    }

    private func doStop() {
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

        if streamingCoordinator.xaiSession != nil || streamingCoordinator.elevenLabsSession != nil {
            teardownMicEngine()
        }

        let xaiContext = StreamingCoordinator.XAIStopContext(
            duration: elapsed,
            hadSpeech: recordingHadSpeech(),
            bufferedAudio: bufferedAudio
        )
        if streamingCoordinator.handleStopXAI(
            context: xaiContext,
            onSilence: { [weak self] in
                DispatchQueue.main.async { self?.hud.hide() }
            },
            onStreamSuccess: { [weak self] text in
                self?.asrSelector.logStreamedTranscription(text: text, engineID: "cloud:xai-streaming") { [weak self] injected in
                    self?.finishHUDAfterPipeline(injected: injected)
                }
            },
            onBatchFallback: { [weak self] buffers, duration in
                guard let self = self else { return }
                guard !buffers.isEmpty else { self.hud.hide(); return }
                self.writeToFile(duration: duration, buffers: buffers)
            }
        ) {
            return
        }

        let elevenLabsContext = StreamingCoordinator.ElevenLabsStopContext(
            duration: elapsed,
            hadSpeech: recordingHadSpeech(),
            bufferedAudio: bufferedAudio
        )
        if streamingCoordinator.handleStopElevenLabs(
            context: elevenLabsContext,
            onSilence: { [weak self] in
                DispatchQueue.main.async { self?.hud.hide() }
            },
            onStreamSuccess: { [weak self] text in
                self?.asrSelector.logStreamedTranscription(text: text, engineID: "cloud:elevenlabs-streaming") { [weak self] injected in
                    self?.finishHUDAfterPipeline(injected: injected)
                }
            },
            onBatchFallback: { [weak self] buffers, duration in
                guard let self = self else { return }
                guard !buffers.isEmpty else { self.hud.hide(); return }
                self.writeToFile(duration: duration, buffers: buffers)
            }
        ) {
            return
        }

        if streamingCoordinator.handleStopWhisperKit(
            onEmpty: { [weak self] in
                DispatchQueue.main.async { self?.hud.hide() }
            },
            onSuccess: { [weak self] text in
                self?.asrSelector.logStreamedTranscription(text: text, engineID: "whisperKit:streaming") { [weak self] injected in
                    self?.finishHUDAfterPipeline(injected: injected)
                }
            }
        ) {
            return
        }

        stopFileBasedCapture()
    }

    /// Teardown for the file-based (tap+buffer) path — only touches the
    /// `AVAudioEngine`/tap state if `startFileBasedCapture` actually set it
    /// up, so calling this when a streaming session was active instead is
    /// always safe.
    private func stopFileBasedCapture() {
        guard isSetUp else {
            DispatchQueue.main.async { [weak self] in self?.hud.hide() }
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
            DispatchQueue.main.async { [weak self] in self?.hud.hide() }
            return
        }

        // Silence guard: skip transcription entirely when no real speech was
        // present, so Whisper can't hallucinate a stock caption on silence.
        guard recordingHadSpeech() else {
            vlog("no speech — skipping transcription (silence guard)")
            DispatchQueue.main.async { [weak self] in self?.hud.hide() }
            return
        }

        writeToFile(duration: elapsed, buffers: capturedBuffers)
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

    private func writeToFile(duration: TimeInterval, buffers: [AVAudioPCMBuffer]) {
        guard let first = buffers.first else { return }
        let format = first.format
        // Snapshot buffers for the IO queue — do not touch AVAudioFile / retain on main.
        let buffersCopy = buffers

        audioIOQueue.async { [weak self] in
            guard let self = self else { return }

            let totalFrames = buffersCopy.reduce(0) { $0 + AVAudioFrameCount($1.frameLength) }

            guard let combined = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
                self.logger.error("Failed to allocate combined buffer (\(totalFrames) frames)")
                DispatchQueue.main.async {
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
                        self.asrSelector.onFailure?(.audioWriteFailed)
                        self.hud.hide()
                    }
                    return
                }

                DispatchQueue.main.async {
                    self.asrSelector.setLastRetainedRecordingURL(retainedURL)
                    self.asrSelector.transcribeAndLog(audioURL: retainedURL) { [weak self] injected in
                        try? FileManager.default.removeItem(at: tmpURL)
                        self?.finishHUDAfterPipeline(injected: injected)
                    }
                }
            } catch {
                self.logger.error("Failed to write audio file: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.asrSelector.onFailure?(.audioWriteFailed)
                    self.hud.hide()
                }
            }
        }
    }

    // MARK: - Feedback sound

    /// Success-path pipeline completions flash a checkmark; silent failures hide
    /// only when the HUD is still in `.processing` (onFailure already set state).
    private func finishHUDAfterPipeline(injected: Bool) {
        if injected {
            hud.showSuccessThenHide()
        } else if hud.isProcessing {
            hud.hide()
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
