// Local WhisperKit streaming is disabled in production: `ASREngineSelector.streamingEnabled`
// is `false`, so `AudioRecorder` always uses the file-based capture path. This file is
// kept intact for a future revisit (e.g. live preview during speech) once the sub-second
// tail-drop issue in WhisperKit's `AudioStreamTranscriber` is addressed.

import Foundation
import os.log
import WhisperKit

// MARK: - Streaming transcription session

/// Wraps WhisperKit's `AudioStreamTranscriber` to transcribe DURING the
/// push-to-talk hold, so the text is (nearly) ready the instant fn is
/// released instead of waiting for a post-release file-transcribe pass.
///
/// MIC OWNERSHIP: `AudioStreamTranscriber.startStreamTranscription()` calls
/// `audioProcessor.startRecordingLive` internally — it is not fed external
/// PCM buffers, it captures the mic itself via the `WhisperKitEngine`'s own
/// `AudioProcessor`. That is confirmed directly in WhisperKit's source
/// (`AudioStreamTranscriber.swift`):
///
///     public func startStreamTranscription() async throws {
///         ...
///         try audioProcessor.startRecordingLive { ... }
///         await realtimeLoop()
///     }
///
/// So for the duration of a streaming session THIS class is the sole mic
/// owner — `AudioRecorder` must not also run its `AVAudioEngine` tap
/// concurrently (see `AudioRecorder.doStart()`, which only falls back to its
/// own tap when this session fails to start).
///
/// VU LEVEL: `AudioProcessor.startRecordingLive`'s callback delivers raw
/// `[Float]` PCM samples per buffer (see `AudioStreamTranscriber`'s own use
/// of `audioProcessor.relativeEnergy`/`audioSamples`) — there is no separate
/// "level" callback exposed, so this class computes its own RMS over each
/// delivered sample batch, mirroring the smoothing `AudioRecorder` already
/// does, and republishes it through the same `levelCallback` contract so the
/// HUD wiring in `AudioRecorder` doesn't need to change shape.
final class StreamingTranscriber {

    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "streaming-asr")

    private var transcriber: AudioStreamTranscriber?
    private var loopTask: Task<Void, Never>?

    /// Latest accumulated text (confirmed + unconfirmed segments), updated
    /// from the transcriber's state-change callback. Read on finalize.
    private var latestText: String = ""
    private let textLock = NSLock()

    /// Smoothed mic level, called back on EVERY delivered audio buffer while
    /// streaming — same shape/units `AudioRecorder.publishLevel` already
    /// produces (0...1, post exponential-smoothing) so `RecordingHUD.pushLevel`
    /// wiring is unchanged.
    var levelCallback: ((Float) -> Void)?

    private var smoothedLevel: Float = 0

    private var streamStartedAt: Date?
    private var firstPartialLoggedAt: Date?

    /// Set by `finalize()`/`cancel()` if either runs while `start()` is still
    /// awaiting model load / transcriber construction (a very short window —
    /// fn released almost instantly after fn-down). Guards against the mic
    /// being opened AFTER the caller already gave up on this session and
    /// moved on, which would otherwise leave an orphaned live capture.
    private var abandoned = false

    /// Starts a streaming session against `engine`'s already-loaded
    /// WhisperKit instance. Throws if the model isn't loaded/ready or the mic
    /// can't be captured (permission, engine setup) — callers should fall
    /// back to the file-based path on any failure.
    func start(engine: WhisperKitEngine) async throws {
        latestText = ""
        firstPartialLoggedAt = nil
        abandoned = false
        streamStartedAt = Date()
        vlog("streaming: starting session")

        let transcriber = try await engine.makeStreamTranscriber { [weak self] oldState, newState in
            guard let self else { return }
            self.handleStateChange(old: oldState, new: newState)
        }

        guard !abandoned else {
            // finalize()/cancel() already ran before we finished spinning up
            // (fn released mid-load) — don't open the mic for a session
            // nobody is waiting on.
            vlog("streaming: start completed after abandonment — not starting mic capture")
            return
        }

        self.transcriber = transcriber

        // `startStreamTranscription()` internally runs its own realtime loop
        // (`while state.isRecording { ... }`) for as long as the session is
        // active, so it must be launched as a background task rather than
        // awaited here — awaiting it would block until `stop()` is called.
        loopTask = Task {
            do {
                try await transcriber.startStreamTranscription()
            } catch {
                vlog("streaming: session loop ended with error: \(error.localizedDescription)")
            }
        }

        vlog("streaming: session started in \(String(format: "%.2f", Date().timeIntervalSince(streamStartedAt!)))s")
    }

    /// Stops mic capture and returns the final accumulated transcript. Safe
    /// to call even if `start` never fully spun up (returns whatever text, if
    /// any, was accumulated).
    func finalize() async -> String {
        abandoned = true
        let finalizeStart = Date()
        if let transcriber {
            await transcriber.stopStreamTranscription()
        }
        loopTask?.cancel()
        loopTask = nil
        transcriber = nil

        textLock.lock()
        let text = latestText
        textLock.unlock()

        vlog("streaming: finalize took \(String(format: "%.3f", Date().timeIntervalSince(finalizeStart)))s, \(text.count) chars ready at release")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Hard stop with no text read-back — used when a session needs to be
    /// abandoned (e.g. falling back mid-flight is not a supported transition
    /// today, but this exists for symmetry / future use).
    func cancel() {
        abandoned = true
        loopTask?.cancel()
        loopTask = nil
        if let transcriber {
            Task { await transcriber.stopStreamTranscription() }
        }
        transcriber = nil
    }

    // MARK: - State-change handling

    private func handleStateChange(old: AudioStreamTranscriber.State, new: AudioStreamTranscriber.State) {
        // Combine confirmed + in-flight unconfirmed segments into one running
        // transcript — mirrors how AudioStreamTranscriber's own reference
        // usage displays live text (confirmed segments are stable, the
        // unconfirmed tail keeps getting rewritten as more audio arrives).
        let confirmed = new.confirmedSegments.map { $0.text }.joined(separator: " ")
        let unconfirmed = new.unconfirmedSegments.map { $0.text }.joined(separator: " ")
        let combined = [confirmed, unconfirmed]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // Fall back to currentText (in-progress decode before any segment is
        // seeked) so the transcript isn't empty during the very first buffer.
        let raw = combined.isEmpty ? new.currentText : combined
        // Safety net: strip any Whisper special tokens (<|...|>) that slip
        // through. The decoder is configured with skipSpecialTokens, but the
        // in-progress currentText path can still surface them before a segment
        // is sealed. Collapse any whitespace the removal leaves behind.
        let effective = raw
            .replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)

        textLock.lock()
        latestText = effective
        textLock.unlock()

        if firstPartialLoggedAt == nil, !effective.isEmpty, let started = streamStartedAt {
            firstPartialLoggedAt = Date()
            vlog("streaming: first partial at \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        }

        // Derive a VU level from bufferEnergy (relative energy WhisperKit's
        // own AudioProcessor already computes per buffer) rather than raw
        // samples — cheaper than re-deriving RMS ourselves and keeps this
        // class from needing its own copy of the sample buffer.
        if let energy = new.bufferEnergy.last {
            publishLevel(energy)
        }
    }

    private func publishLevel(_ rawEnergy: Float) {
        let clamped = max(0, min(1, rawEnergy))
        let alpha: Float = clamped > smoothedLevel ? 0.6 : 0.3
        smoothedLevel = smoothedLevel + (clamped - smoothedLevel) * alpha
        let normalized = min(1.0, smoothedLevel * 1.4)
        levelCallback?(normalized)
    }
}
