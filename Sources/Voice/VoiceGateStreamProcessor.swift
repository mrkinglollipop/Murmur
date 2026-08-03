import AVFoundation
import Foundation

/// Buffers mic tap audio into ~1s 16kHz mono windows for async gate evaluation,
/// while synchronously applying the latched decision to the native-format buffer
/// before downstream pcmBuffers / streaming consumption. Never blocks the audio
/// realtime thread on embedding work.
final class VoiceGateStreamProcessor {

    private let gate: VoiceGate
    private let recordingSession: VoiceGateRecordingSession
    private let onTelemetryUpdate: (() -> Void)?
    private let evaluationQueue = DispatchQueue(
        label: "com.matt.voice-dictation.voice-gate-eval",
        qos: .userInitiated
    )
    private let runEvaluation: (@escaping () -> Void) -> Void

    private let decisionLock = NSLock()
    private var currentDecision: VoiceGateDecision = .pass

    private let accumulatorLock = NSLock()
    private var embeddingAccumulator: [Float] = []
    private let windowSampleCount = 16_000

    private let evaluationCompletionLock = NSLock()
    private var evaluationCompletionCount = 0

    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    var isActive = true

    init(
        gate: VoiceGate,
        recordingSession: VoiceGateRecordingSession,
        onTelemetryUpdate: (() -> Void)? = nil,
        runEvaluation: ((@escaping () -> Void) -> Void)? = nil
    ) {
        self.gate = gate
        self.recordingSession = recordingSession
        self.onTelemetryUpdate = onTelemetryUpdate
        if let runEvaluation {
            self.runEvaluation = runEvaluation
        } else {
            self.runEvaluation = { [evaluationQueue] work in
                evaluationQueue.async(execute: work)
            }
        }
    }

    func updateSensitivity(_ sensitivity: VoiceGateSensitivity) {
        gate.updateSensitivity(sensitivity)
    }

    /// Applies the latched gate decision to `buffer`, then feeds the embedding
    /// path asynchronously. Call from the mic tap thread only.
    func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isActive else { return }

        applyCurrentDecision(to: buffer)
        appendResampledSamples(from: buffer)
    }

    /// Clears latch state and the embedding accumulator without discarding
    /// session telemetry (shown in Settings after the recording ends).
    func resetProcessingState() {
        decisionLock.lock()
        currentDecision = .pass
        decisionLock.unlock()
        accumulatorLock.lock()
        embeddingAccumulator.removeAll(keepingCapacity: false)
        accumulatorLock.unlock()
    }

    /// Starts a new recording session — fresh token, cleared telemetry, reset latch.
    func beginRecordingSession() {
        recordingSession.begin()
        resetProcessingState()
        publishTelemetry()
    }

    /// Ends the recording session; invalidates the token so trailing async work cannot commit.
    func endRecordingSession() {
        recordingSession.end()
        resetProcessingState()
        publishTelemetry()
    }

    internal var latchedDecisionForTesting: VoiceGateDecision {
        decisionLock.lock()
        defer { decisionLock.unlock() }
        return currentDecision
    }

    internal func evaluateWindowForTesting(_ window: [Float]) {
        dispatchEvaluation(for: window)
    }

    internal var evaluationCompletionCountForTesting: Int {
        evaluationCompletionLock.lock()
        defer { evaluationCompletionLock.unlock() }
        return evaluationCompletionCount
    }

    private func noteEvaluationCompleted() {
        evaluationCompletionLock.lock()
        evaluationCompletionCount += 1
        evaluationCompletionLock.unlock()
    }

    private func publishTelemetry() {
        guard let onTelemetryUpdate else { return }
        DispatchQueue.main.async(execute: onTelemetryUpdate)
    }

    // MARK: - Attenuation (sync, realtime thread)

    private func applyCurrentDecision(to buffer: AVAudioPCMBuffer) {
        decisionLock.lock()
        let decision = currentDecision
        decisionLock.unlock()
        guard decision == .attenuate else { return }
        guard let channelData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)
        for channel in 0 ..< channelCount {
            var samples = Array(UnsafeBufferPointer(start: channelData[channel], count: frameCount))
            VoiceGate.attenuate(&samples)
            samples.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                channelData[channel].update(from: base, count: frameCount)
            }
        }
    }

    // MARK: - Embedding window (sync accumulate, async evaluate)

    private func appendResampledSamples(from buffer: AVAudioPCMBuffer) {
        guard let samples = resampleTo16kMonoFloat(buffer), !samples.isEmpty else { return }

        var windows: [[Float]] = []
        accumulatorLock.lock()
        embeddingAccumulator.append(contentsOf: samples)
        while embeddingAccumulator.count >= windowSampleCount {
            windows.append(Array(embeddingAccumulator.prefix(windowSampleCount)))
            embeddingAccumulator.removeFirst(windowSampleCount)
        }
        accumulatorLock.unlock()

        for window in windows {
            dispatchEvaluation(for: window)
        }
    }

    private func dispatchEvaluation(for window: [Float]) {
        guard let token = recordingSession.tokenForDispatch() else { return }
        runEvaluation { [weak self] in
            defer { self?.noteEvaluationCompleted() }
            guard let self, self.isActive else { return }
            let evaluation = self.gate.evaluate(window: window)
            let committed = self.recordingSession.commit(token: token, evaluation: evaluation) { decision in
                self.decisionLock.lock()
                self.currentDecision = decision
                self.decisionLock.unlock()
            }
            guard committed else { return }
            self.publishTelemetry()
        }
    }

    private func resampleTo16kMonoFloat(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let inputFormat = buffer.format
        if converter == nil || converterInputFormat != inputFormat {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
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
        guard status != .error, error == nil else { return nil }
        guard let floatData = outputBuffer.floatChannelData else { return nil }

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: floatData[0], count: frameCount))
    }
}
