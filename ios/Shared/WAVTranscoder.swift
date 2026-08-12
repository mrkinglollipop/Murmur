import AVFoundation
import Foundation

/// 16-bit / 16 kHz mono WAV for cloud batch. Do not upload raw CAF.
enum WAVTranscoder {
    static let uploadMimeType = "audio/wav"
    static let uploadFileName = "audio.wav"

    static func wavUploadPayload(from input: URL) throws -> (data: Data, fileName: String, mimeType: String) {
        let wavURL = try transcodeToWAV16k(input)
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let data = try Data(contentsOf: wavURL)
        return (data, uploadFileName, uploadMimeType)
    }

    static func transcodeToWAV16k(_ input: URL) throws -> URL {
        let inputFile = try AVAudioFile(forReading: input)
        guard inputFile.length > 0 else { throw WAVTranscoderError.emptyInput }

        let inputFormat = inputFile.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw WAVTranscoderError.formatFailed
        }

        let frameCount = AVAudioFrameCount(inputFile.length)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            throw WAVTranscoderError.bufferFailed
        }
        try inputFile.read(into: inputBuffer)

        let framesToWrite: AVAudioPCMBuffer
        if inputFormat.sampleRate == outputFormat.sampleRate,
           inputFormat.channelCount == outputFormat.channelCount,
           inputFormat.commonFormat == outputFormat.commonFormat {
            framesToWrite = inputBuffer
        } else {
            framesToWrite = try convert(inputBuffer, from: inputFormat, to: outputFormat)
        }
        guard framesToWrite.frameLength > 0 else { throw WAVTranscoderError.emptyOutput }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-ios-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        do {
            let outputFile = try AVAudioFile(
                forWriting: outURL,
                settings: settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            try outputFile.write(from: framesToWrite)
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            throw WAVTranscoderError.writeFailed
        }
        return outURL
    }

    private static func convert(
        _ inputBuffer: AVAudioPCMBuffer,
        from inputFormat: AVAudioFormat,
        to outputFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw WAVTranscoderError.convertFailed
        }
        let ratio = outputFormat.sampleRate / max(inputFormat.sampleRate, 1)
        let outCapacity = max(AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 32, 4096)
        guard let accumulated = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity),
              let packet = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else {
            throw WAVTranscoderError.bufferFailed
        }

        var error: NSError?
        var inputProvided = false
        var total: AVAudioFrameCount = 0
        conversionLoop: while true {
            packet.frameLength = 0
            let status = converter.convert(to: packet, error: &error) { _, outStatus in
                if inputProvided {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                inputProvided = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            if error != nil { throw WAVTranscoderError.convertFailed }
            switch status {
            case .error:
                throw WAVTranscoderError.convertFailed
            case .haveData, .inputRanDry, .endOfStream:
                if packet.frameLength > 0 {
                    guard let src = packet.int16ChannelData, let dst = accumulated.int16ChannelData else {
                        throw WAVTranscoderError.convertFailed
                    }
                    let next = total + packet.frameLength
                    guard next <= accumulated.frameCapacity else { throw WAVTranscoderError.bufferFailed }
                    let count = Int(packet.frameLength) * Int(packet.format.channelCount)
                    dst[0].advanced(by: Int(total) * Int(packet.format.channelCount))
                        .update(from: src[0], count: count)
                    total = next
                }
                if status == .endOfStream { break conversionLoop }
            @unknown default:
                throw WAVTranscoderError.convertFailed
            }
        }
        accumulated.frameLength = total
        return accumulated
    }
}

enum WAVTranscoderError: Error, LocalizedError {
    case emptyInput, emptyOutput, formatFailed, bufferFailed, convertFailed, writeFailed

    var errorDescription: String? {
        switch self {
        case .emptyInput: return "Empty recording"
        case .emptyOutput: return "Transcode produced no audio"
        case .formatFailed: return "Could not build 16 kHz WAV format"
        case .bufferFailed: return "Audio buffer allocation failed"
        case .convertFailed: return "WAV transcode failed"
        case .writeFailed: return "Could not write WAV"
        }
    }
}
