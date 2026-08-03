import AVFoundation
import XCTest
@testable import Voice

/// Coverage for the accumulate-then-single-write transcoder path that previously
/// SIGTRAPped inside ExtAudioFile when partial converter packets were written
/// mid-loop during ElevenLabs streaming→buffered fallback.
final class CloudAudioTranscoderTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-transcoder-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func writeAudioFile(
        name: String,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        commonFormat: AVAudioCommonFormat,
        frameCount: AVAudioFrameCount,
        interleaved: Bool
    ) throws -> URL {
        guard let format = AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: interleaved
        ) else {
            XCTFail("failed to build AVAudioFormat")
            throw CloudAudioTranscoderError.formatConstructionFailed
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            XCTFail("failed to allocate PCM buffer")
            throw CloudAudioTranscoderError.bufferAllocationFailed
        }
        buffer.frameLength = frameCount
        // Quiet non-zero tone so converters cannot treat the buffer as empty silence edge.
        if let floatData = buffer.floatChannelData {
            for ch in 0 ..< Int(channels) {
                for i in 0 ..< Int(frameCount) {
                    floatData[ch][i] = 0.05 * sinf(Float(i) * 0.05)
                }
            }
        } else if let int16Data = buffer.int16ChannelData {
            for ch in 0 ..< Int(channels) {
                for i in 0 ..< Int(frameCount) {
                    int16Data[ch][i] = Int16(1600 * sin(Double(i) * 0.05))
                }
            }
        }

        let url = tempDir.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: commonFormat == .pcmFormatInt16 ? 16 : 32,
            AVLinearPCMIsFloatKey: commonFormat == .pcmFormatFloat32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !interleaved
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: commonFormat, interleaved: interleaved)
        try file.write(from: buffer)
        return url
    }

    private func writeZeroLengthCAF(name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        _ = try AVAudioFile(forWriting: url, settings: settings)
        return url
    }

    private func assertIsWAV16kMonoInt16(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(file.length, 0)
        let format = file.processingFormat
        XCTAssertEqual(format.sampleRate, 16_000, accuracy: 0.1)
        XCTAssertEqual(format.channelCount, 1)
    }

    // MARK: - Errors

    func testTranscodeEmptyInputThrowsEmptyInput() throws {
        let empty = try writeZeroLengthCAF(name: "empty.caf")
        XCTAssertThrowsError(try CloudAudioTranscoder.transcodeToWAV16k(empty)) { error in
            guard let typed = error as? CloudAudioTranscoderError else {
                XCTFail("expected CloudAudioTranscoderError, got \(error)")
                return
            }
            guard case .emptyInput = typed else {
                XCTFail("expected emptyInput, got \(typed)")
                return
            }
        }
    }

    // MARK: - Convert path (regression for ExtAudioFile mid-loop write crash)

    func testTranscodeFloat32_48k_ProducesWAVWithoutTrap() throws {
        // Mirrors recording CAF (Float32, often 48 kHz) → 16 kHz Int16 WAV upload.
        let input = try writeAudioFile(
            name: "float48k.caf",
            sampleRate: 48_000,
            channels: 1,
            commonFormat: .pcmFormatFloat32,
            frameCount: 4800,
            interleaved: false
        )
        let out = try CloudAudioTranscoder.transcodeToWAV16k(input)
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertEqual(out.pathExtension.lowercased(), "wav")
        try assertIsWAV16kMonoInt16(out)
    }

    func testTranscodeFloat32Stereo48k_Produces16kMonoWAV() throws {
        let input = try writeAudioFile(
            name: "float48k-stereo.caf",
            sampleRate: 48_000,
            channels: 2,
            commonFormat: .pcmFormatFloat32,
            frameCount: 4800,
            interleaved: false
        )
        let out = try CloudAudioTranscoder.transcodeToWAV16k(input)
        defer { try? FileManager.default.removeItem(at: out) }
        try assertIsWAV16kMonoInt16(out)
    }

    func testTranscodeFloat32_16k_ProducesWAVWithoutTrap() throws {
        let input = try writeAudioFile(
            name: "float16k.caf",
            sampleRate: 16_000,
            channels: 1,
            commonFormat: .pcmFormatFloat32,
            frameCount: 1600,
            interleaved: false
        )
        let out = try CloudAudioTranscoder.transcodeToWAV16k(input)
        defer { try? FileManager.default.removeItem(at: out) }
        try assertIsWAV16kMonoInt16(out)
    }

    func testTranscodeInt16_16k_PassthroughPath() throws {
        let input = try writeAudioFile(
            name: "int16-16k.caf",
            sampleRate: 16_000,
            channels: 1,
            commonFormat: .pcmFormatInt16,
            frameCount: 800,
            interleaved: true
        )
        let out = try CloudAudioTranscoder.transcodeToWAV16k(input)
        defer { try? FileManager.default.removeItem(at: out) }
        try assertIsWAV16kMonoInt16(out)
    }

    // MARK: - Upload payload

    func testWavUploadPayload_mimeAndCleanup() throws {
        let input = try writeAudioFile(
            name: "payload-src.caf",
            sampleRate: 48_000,
            channels: 1,
            commonFormat: .pcmFormatFloat32,
            frameCount: 2400,
            interleaved: false
        )
        let payload = try CloudAudioTranscoder.wavUploadPayload(from: input)
        XCTAssertEqual(payload.fileName, CloudAudioTranscoder.uploadFileName)
        XCTAssertEqual(payload.mimeType, CloudAudioTranscoder.uploadMimeType)
        XCTAssertFalse(payload.data.isEmpty)
        // WAV header starts with RIFF
        XCTAssertEqual(Array(payload.data.prefix(4)), Array("RIFF".utf8))
    }

    func testErrorDescriptionsAreNonEmpty() {
        let cases: [CloudAudioTranscoderError] = [
            .emptyInput,
            .emptyOutput,
            .formatConstructionFailed,
            .converterConstructionFailed,
            .bufferAllocationFailed,
            .conversionFailed,
            .writeFailed
        ]
        for error in cases {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "\(error)")
        }
    }
}
