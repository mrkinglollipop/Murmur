import AVFoundation
import os.log

/// Owns xAI / WhisperKit streaming session state and the start/stop decision
/// logic extracted from `AudioRecorder`. File-based capture stays in the
/// recorder; this type decides whether to open a streaming session and
/// handles finalize-at-release for both streaming backends.
final class StreamingCoordinator {

    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "streaming")

    /// Non-nil while a WhisperKit streaming session owns transcription.
    private(set) var whisperSession: StreamingTranscriber?

    /// Non-nil while an xAI Grok streaming session is active. Read from the
    /// audio-tap thread to fork per-buffer sends; set/cleared on main.
    private(set) var xaiSession: XAIStreamingTranscriber?

    /// Non-nil while an ElevenLabs Scribe v2 Realtime streaming session is
    /// active. Read from the audio-tap thread to fork per-buffer sends;
    /// set/cleared on main. Mutually exclusive with `xaiSession` (both are
    /// gated on the same `cloudModel` selection, which is a single value).
    private(set) var elevenLabsSession: ElevenLabsRealtimeTranscriber?

    /// Soft floor for "looks truncated" — only force batch fallback when text
    /// is extremely short relative to hold length (false positives at 8 cps
    /// discarded good streams). Empty text already falls back separately.
    private static let streamMinCharsPerSecond: Double = 2.0
    private static let streamTruncationCheckMinDuration: TimeInterval = 8.0

    // MARK: - Start

    /// Attempts xAI Grok streaming. Returns `true` when a session was opened
    /// (caller should start mic capture). On start failure the session is
    /// cleared and `false` is returned so the caller falls through to file mode.
    func tryStartXAI(
        asrSelector: ASREngineSelector,
        startMicCapture: @escaping () -> Void
    ) -> Bool {
        guard let session = asrSelector.makeXAIStreamingSession() else { return false }

        session.onInterim = { text in
            asrSelector.onInterimTranscript?(text)
        }
        xaiSession = session
        vlog("doStart — attempting xAI streaming transcription")
        Task {
            do {
                try await session.start()
            } catch {
                vlog("xai streaming: start failed (\(error.localizedDescription)) — continuing in file-buffer mode")
                session.cancel()
                DispatchQueue.main.async {
                    if self.xaiSession === session {
                        self.xaiSession = nil
                    }
                }
            }
        }
        startMicCapture()
        return true
    }

    /// Attempts ElevenLabs Scribe v2 Realtime streaming. Returns `true` when
    /// a session was opened (caller should start mic capture). On start
    /// failure the session is cleared and `false` is returned so the caller
    /// falls through to file mode. Mirrors `tryStartXAI`.
    func tryStartElevenLabs(
        asrSelector: ASREngineSelector,
        startMicCapture: @escaping () -> Void
    ) -> Bool {
        guard let session = asrSelector.makeElevenLabsStreamingSession() else { return false }

        session.onInterim = { text in
            asrSelector.onInterimTranscript?(text)
        }
        elevenLabsSession = session
        vlog("doStart — attempting ElevenLabs Scribe RT streaming transcription")
        Task {
            do {
                try await session.start()
            } catch {
                vlog("elevenlabs streaming: start failed (\(error.localizedDescription)) — continuing in file-buffer mode")
                session.cancel()
                DispatchQueue.main.async {
                    if self.elevenLabsSession === session {
                        self.elevenLabsSession = nil
                    }
                }
            }
        }
        startMicCapture()
        return true
    }

    /// Attempts WhisperKit streaming. Returns `true` when a session was
    /// opened (mic capture is NOT started here — streaming owns the mic).
    /// On failure, calls `fallbackToFileBased` on main if recording is still wanted.
    func tryStartWhisperKit(
        asrSelector: ASREngineSelector,
        wantsRecording: @escaping () -> Bool,
        levelCallback: @escaping (Float) -> Void,
        fallbackToFileBased: @escaping () -> Void
    ) -> Bool {
        guard asrSelector.streamingEligible,
              let wkEngine = asrSelector.makeWhisperKitEngineForStreaming() else {
            return false
        }

        let session = StreamingTranscriber()
        session.levelCallback = levelCallback
        whisperSession = session
        vlog("doStart — attempting streaming transcription")
        Task {
            do {
                try await session.start(engine: wkEngine)
            } catch {
                vlog("streaming: start failed (\(error.localizedDescription)) — falling back to file-based path")
                self.whisperSession = nil
                DispatchQueue.main.async {
                    guard wantsRecording() else { return }
                    fallbackToFileBased()
                }
            }
        }
        return true
    }

    /// Sends a captured buffer to the active xAI session, if any.
    func sendToXAI(_ buffer: AVAudioPCMBuffer) {
        xaiSession?.send(buffer)
    }

    /// Sends a captured buffer to the active ElevenLabs session, if any.
    func sendToElevenLabs(_ buffer: AVAudioPCMBuffer) {
        elevenLabsSession?.send(buffer)
    }

    /// Aborts any in-flight streaming session and drops the reference without
    /// waiting for a final transcript — used when the capture is abandoned
    /// (secure input activated mid-hold) and the audio must not be used.
    func cancelAll() {
        xaiSession?.cancel()
        xaiSession = nil
        elevenLabsSession?.cancel()
        elevenLabsSession = nil
    }

    // MARK: - Stop (xAI)

    struct XAIStopContext {
        let duration: TimeInterval
        let hadSpeech: Bool
        let bufferedAudio: [AVAudioPCMBuffer]
    }

    /// Handles xAI streaming stop. Returns `true` when this path consumed the stop.
    func handleStopXAI(
        context: XAIStopContext,
        onSilence: @escaping () -> Void,
        onStreamSuccess: @escaping (String) -> Void,
        onBatchFallback: @escaping ([AVAudioPCMBuffer], TimeInterval) -> Void
    ) -> Bool {
        guard let session = xaiSession else { return false }

        xaiSession = nil

        guard context.hadSpeech else {
            vlog("xai streaming: no speech — skipping (silence guard)")
            session.cancel()
            onSilence()
            return true
        }

        let releaseAt = Date()
        Task {
            let text = await session.finalize(recordingDuration: context.duration)
            vlog("xai streaming: finalize-at-release \(String(format: "%.3f", Date().timeIntervalSince(releaseAt)))s")
            let truncated = Self.streamResultLooksTruncated(text: text, duration: context.duration)
            if truncated {
                vlog("xai streaming: truncated (\(text.count) chars / \(String(format: "%.1f", context.duration))s) — batch fallback")
            }
            if !text.isEmpty, !truncated {
                onStreamSuccess(text)
            } else {
                if text.isEmpty {
                    self.logger.warning("xAI streaming produced no text — falling back to buffered audio.")
                } else {
                    self.logger.warning("xAI streaming looks truncated — falling back to buffered audio.")
                }
                vlog("xai streaming: fallback to buffered audio (\(context.bufferedAudio.count) buffers)")
                DispatchQueue.main.async {
                    onBatchFallback(context.bufferedAudio, context.duration)
                }
            }
        }
        return true
    }

    // MARK: - Stop (ElevenLabs)

    struct ElevenLabsStopContext {
        let duration: TimeInterval
        let hadSpeech: Bool
        let bufferedAudio: [AVAudioPCMBuffer]
    }

    /// Handles ElevenLabs Scribe RT streaming stop. Returns `true` when this
    /// path consumed the stop. Mirrors `handleStopXAI`.
    func handleStopElevenLabs(
        context: ElevenLabsStopContext,
        onSilence: @escaping () -> Void,
        onStreamSuccess: @escaping (String) -> Void,
        onBatchFallback: @escaping ([AVAudioPCMBuffer], TimeInterval) -> Void
    ) -> Bool {
        guard let session = elevenLabsSession else { return false }

        elevenLabsSession = nil

        guard context.hadSpeech else {
            vlog("elevenlabs streaming: no speech — skipping (silence guard)")
            session.cancel()
            onSilence()
            return true
        }

        let releaseAt = Date()
        Task {
            let text = await session.finalize(recordingDuration: context.duration)
            vlog("elevenlabs streaming: finalize-at-release \(String(format: "%.3f", Date().timeIntervalSince(releaseAt)))s")
            let truncated = Self.streamResultLooksTruncated(text: text, duration: context.duration)
            if truncated {
                vlog("elevenlabs streaming: truncated (\(text.count) chars / \(String(format: "%.1f", context.duration))s) — batch fallback")
            }
            if !text.isEmpty, !truncated {
                onStreamSuccess(text)
            } else {
                if text.isEmpty {
                    self.logger.warning("ElevenLabs streaming produced no text — falling back to buffered audio.")
                } else {
                    self.logger.warning("ElevenLabs streaming looks truncated — falling back to buffered audio.")
                }
                vlog("elevenlabs streaming: fallback to buffered audio (\(context.bufferedAudio.count) buffers)")
                DispatchQueue.main.async {
                    onBatchFallback(context.bufferedAudio, context.duration)
                }
            }
        }
        return true
    }

    // MARK: - Stop (WhisperKit)

    /// Handles WhisperKit streaming stop. Returns `true` when this path consumed the stop.
    func handleStopWhisperKit(
        onEmpty: @escaping () -> Void,
        onSuccess: @escaping (String) -> Void
    ) -> Bool {
        guard let session = whisperSession else { return false }

        whisperSession = nil
        let releaseAt = Date()
        Task {
            let text = await session.finalize()
            vlog("streaming: finalize-at-release total \(String(format: "%.3f", Date().timeIntervalSince(releaseAt)))s")
            guard !text.isEmpty else {
                self.logger.warning("Streaming session produced no text.")
                DispatchQueue.main.async { onEmpty() }
                return
            }
            onSuccess(text)
        }
        return true
    }

    static func streamResultLooksTruncated(text: String, duration: TimeInterval) -> Bool {
        guard duration >= streamTruncationCheckMinDuration else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return Double(trimmed.count) < duration * streamMinCharsPerSecond
    }
}
