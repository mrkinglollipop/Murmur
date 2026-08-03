import AVFoundation
import Foundation

/// Standalone mic capture for voice enrollment — owns its own `AVAudioEngine`,
/// separate from `AudioRecorder`. Never throws across the public boundary.
final class EnrollmentCapture {

    private let engine = AVAudioEngine()
    private var isCapturing = false
    private var accumulatedSamples: [Float] = []
    private var smoothedLevel: Float = 0

    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private static let windowSampleCount = 16_000
    private static let minimumPartialWindow = 8_000

    func requestPermissionAndStart(
        levelCallback: @escaping (Float) -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            startCapture(levelCallback: levelCallback, completion: completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.startCapture(levelCallback: levelCallback, completion: completion)
                    } else {
                        completion(false)
                    }
                }
            }
        default:
            completion(false)
        }
    }

    func stopCapture() -> [[Float]] {
        stopEngine()
        let windows = chunkIntoWindows(accumulatedSamples)
        resetCaptureState()
        return windows
    }

    // MARK: - Private

    private func startCapture(
        levelCallback: @escaping (Float) -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        resetCaptureState()

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.removeTap(onBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }

            if let channelData = buffer.floatChannelData {
                let frameCount = Int(buffer.frameLength)
                if frameCount > 0 {
                    var sum: Float = 0
                    let samples = channelData[0]
                    for index in 0 ..< frameCount {
                        let sample = samples[index]
                        sum += sample * sample
                    }
                    let rawRMS = sqrt(sum / Float(frameCount))
                    let alpha: Float = rawRMS > self.smoothedLevel ? 0.6 : 0.3
                    self.smoothedLevel = self.smoothedLevel + (rawRMS - self.smoothedLevel) * alpha
                    let normalized = min(1.0, max(0, self.smoothedLevel - 0.003) * 50)
                    DispatchQueue.main.async {
                        levelCallback(normalized)
                    }
                }
            }

            if let resampled = self.resampleTo16kMonoFloat(buffer) {
                self.accumulatedSamples.append(contentsOf: resampled)
            }
        }

        do {
            try engine.start()
            isCapturing = true
            completion(true)
        } catch {
            inputNode.removeTap(onBus: 0)
            resetCaptureState()
            completion(false)
        }
    }

    private func stopEngine() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
    }

    private func resetCaptureState() {
        accumulatedSamples.removeAll(keepingCapacity: false)
        smoothedLevel = 0
    }

    private func chunkIntoWindows(_ samples: [Float]) -> [[Float]] {
        guard !samples.isEmpty else { return [] }

        var windows: [[Float]] = []
        var offset = 0
        while offset + Self.windowSampleCount <= samples.count {
            windows.append(Array(samples[offset ..< offset + Self.windowSampleCount]))
            offset += Self.windowSampleCount
        }

        let remaining = samples.count - offset
        if remaining >= Self.minimumPartialWindow {
            var tail = Array(samples[offset ..< samples.count])
            let padding = Self.windowSampleCount - tail.count
            if padding > 0 {
                tail.append(contentsOf: [Float](repeating: 0, count: padding))
            }
            windows.append(tail)
        }

        return windows
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
