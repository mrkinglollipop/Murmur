import AVFoundation
import Foundation

/// Converts recorded CAF (or any AVAudioFile-readable) audio to 16-bit PCM
/// WAV at 16 kHz mono for cloud batch uploads. Recording stays CAF on disk;
/// transcoding happens only at the upload boundary (plan 010).
enum CloudAudioTranscoder {

    /// Output format accepted by cloud STT batch endpoints.
    static let uploadMimeType = "audio/wav"
    static let uploadFileName = "audio.wav"

    /// Transcodes `input` to a unique temp `.wav` (16-bit LE PCM, 16 kHz, mono).
    /// Caller owns the returned URL and should delete it when done.
    ///
    /// Conversion accumulates into a single PCM buffer, then performs one
    /// `AVAudioFile.write`. Writing partial converter packets in a loop
    /// previously triggered an ExtAudioFile assertion (SIGTRAP) on edge audio
    /// during ElevenLabs streaming→buffered fallback.
    static func transcodeToWAV16k(_ input: URL) throws -> URL {
        let inputFile = try AVAudioFile(forReading: input)
        guard inputFile.length > 0 else {
            throw CloudAudioTranscoderError.emptyInput
        }

        let inputFormat = inputFile.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw CloudAudioTranscoderError.formatConstructionFailed
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-cloud-\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let framesToWrite: AVAudioPCMBuffer
        if inputFormat.sampleRate == outputFormat.sampleRate,
           inputFormat.channelCount == outputFormat.channelCount,
           inputFormat.commonFormat == outputFormat.commonFormat {
            let frameCount = AVAudioFrameCount(inputFile.length)
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
                throw CloudAudioTranscoderError.bufferAllocationFailed
            }
            try inputFile.read(into: inputBuffer)
            framesToWrite = inputBuffer
        } else {
            framesToWrite = try convertToOutputBuffer(
                inputFile: inputFile,
                inputFormat: inputFormat,
                outputFormat: outputFormat
            )
        }

        guard framesToWrite.frameLength > 0 else {
            throw CloudAudioTranscoderError.emptyOutput
        }

        let expectedOutputFrames = Int64(
            (Double(inputFile.length) * outputFormat.sampleRate / inputFormat.sampleRate).rounded()
        )
        let actualOutputFrames = Int64(framesToWrite.frameLength)
        guard abs(actualOutputFrames - expectedOutputFrames) <= 1 else {
            throw CloudAudioTranscoderError.incompleteConversion(
                expectedFrames: expectedOutputFrames,
                actualFrames: actualOutputFrames
            )
        }

        do {
            // processingFormat must match the buffer we write. Opening with
            // settings alone defaults to Float32 and ExtAudioFile asserts
            // (SIGTRAP) inside WriteInputProc when fed Int16 PCM.
            let outputFile = try AVAudioFile(
                forWriting: outURL,
                settings: settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            try outputFile.write(from: framesToWrite)
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            throw CloudAudioTranscoderError.writeFailed
        }

        return outURL
    }

    /// Drains `AVAudioConverter` into one contiguous Int16 buffer (no per-packet writes).
    private static func convertToOutputBuffer(
        inputFile: AVAudioFile,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CloudAudioTranscoderError.converterConstructionFailed
        }

        let ratio = outputFormat.sampleRate / max(inputFormat.sampleRate, 1)
        let outCapacity = max(AVAudioFrameCount(Double(inputFile.length) * ratio) + 32, 4096)
        guard let accumulated = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else {
            throw CloudAudioTranscoderError.bufferAllocationFailed
        }
        guard let packetBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else {
            throw CloudAudioTranscoderError.bufferAllocationFailed
        }

        var error: NSError?
        var inputReadError: Error?
        var totalInputFrames: AVAudioFramePosition = 0
        var totalOutputFrames: AVAudioFrameCount = 0

        // Drain until endOfStream. Accumulate packets in memory; never write
        // partial packets to ExtAudioFile mid-loop (assertion on edge audio).
        conversionLoop: while true {
            packetBuffer.frameLength = 0
            let status = converter.convert(to: packetBuffer, error: &error) { requestedPackets, outStatus in
                guard totalInputFrames < inputFile.length else {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                // AVAudioConverter may consume only the packet count it requested.
                // Returning the entire recording and then end-of-stream silently
                // discards the unconsumed suffix. Read exactly the requested slice
                // and advance AVAudioFile's frame position on every callback.
                let remaining = inputFile.length - totalInputFrames
                let requestedFrames = min(AVAudioFramePosition(requestedPackets), remaining)
                guard requestedFrames > 0,
                      let inputChunk = AVAudioPCMBuffer(
                          pcmFormat: inputFormat,
                          frameCapacity: AVAudioFrameCount(requestedFrames)
                      ) else {
                    inputReadError = CloudAudioTranscoderError.bufferAllocationFailed
                    outStatus.pointee = .noDataNow
                    return nil
                }

                do {
                    try inputFile.read(into: inputChunk, frameCount: AVAudioFrameCount(requestedFrames))
                } catch {
                    inputReadError = error
                    outStatus.pointee = .noDataNow
                    return nil
                }
                guard inputChunk.frameLength > 0 else {
                    inputReadError = CloudAudioTranscoderError.conversionFailed
                    outStatus.pointee = .noDataNow
                    return nil
                }
                totalInputFrames += AVAudioFramePosition(inputChunk.frameLength)
                outStatus.pointee = .haveData
                return inputChunk
            }
            if inputReadError != nil { throw CloudAudioTranscoderError.conversionFailed }
            if error != nil { throw CloudAudioTranscoderError.conversionFailed }

            switch status {
            case .error:
                throw CloudAudioTranscoderError.conversionFailed
            case .haveData, .inputRanDry:
                if packetBuffer.frameLength > 0 {
                    try appendInt16Frames(
                        from: packetBuffer,
                        into: accumulated,
                        atFrameOffset: totalOutputFrames
                    )
                    totalOutputFrames += packetBuffer.frameLength
                }
            case .endOfStream:
                if packetBuffer.frameLength > 0 {
                    try appendInt16Frames(
                        from: packetBuffer,
                        into: accumulated,
                        atFrameOffset: totalOutputFrames
                    )
                    totalOutputFrames += packetBuffer.frameLength
                }
                break conversionLoop
            @unknown default:
                throw CloudAudioTranscoderError.conversionFailed
            }
        }

        guard totalInputFrames == inputFile.length else {
            throw CloudAudioTranscoderError.incompleteConversion(
                expectedFrames: inputFile.length,
                actualFrames: totalInputFrames
            )
        }
        accumulated.frameLength = totalOutputFrames
        return accumulated
    }

    private static func appendInt16Frames(
        from source: AVAudioPCMBuffer,
        into destination: AVAudioPCMBuffer,
        atFrameOffset: AVAudioFrameCount
    ) throws {
        let frames = source.frameLength
        guard frames > 0 else { return }
        guard atFrameOffset + frames <= destination.frameCapacity else {
            throw CloudAudioTranscoderError.bufferAllocationFailed
        }
        guard let src = source.int16ChannelData,
              let dst = destination.int16ChannelData else {
            throw CloudAudioTranscoderError.conversionFailed
        }
        // Interleaved mono Int16 — one channel pointer, frames samples.
        let channelCount = Int(source.format.channelCount)
        let samplesToCopy = Int(frames) * channelCount
        dst[0].advanced(by: Int(atFrameOffset) * channelCount)
            .update(from: src[0], count: samplesToCopy)
    }

    /// Transcodes and reads WAV bytes for upload; deletes the temp file.
    /// Prefer this at service call sites so CAF is never uploaded.
    static func wavUploadPayload(from audioURL: URL) throws -> (data: Data, fileName: String, mimeType: String) {
        let wavURL = try transcodeToWAV16k(audioURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let data = try Data(contentsOf: wavURL)
        return (data, uploadFileName, uploadMimeType)
    }
}

enum CloudAudioTranscoderError: Error, LocalizedError {
    case emptyInput
    case emptyOutput
    case formatConstructionFailed
    case converterConstructionFailed
    case bufferAllocationFailed
    case conversionFailed
    case incompleteConversion(expectedFrames: Int64, actualFrames: Int64)
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Cloud audio transcode: empty or zero-length input"
        case .emptyOutput:
            return "Cloud audio transcode: conversion produced no PCM frames"
        case .formatConstructionFailed:
            return "Cloud audio transcode: failed to build 16 kHz mono PCM format"
        case .converterConstructionFailed:
            return "Cloud audio transcode: AVAudioConverter construction failed"
        case .bufferAllocationFailed:
            return "Cloud audio transcode: buffer allocation failed"
        case .conversionFailed:
            return "Cloud audio transcode: conversion failed"
        case let .incompleteConversion(expectedFrames, actualFrames):
            return "Cloud audio transcode: incomplete conversion (expected \(expectedFrames) frames, produced \(actualFrames))"
        case .writeFailed:
            return "Cloud audio transcode: failed to write WAV output"
        }
    }
}
