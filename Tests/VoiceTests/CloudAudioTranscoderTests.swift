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
        interleaved: Bool,
        tailMarkerFraction: Double? = nil
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
                    let markerStart = tailMarkerFraction.map { Int(Double(frameCount) * $0) } ?? 0
                    floatData[ch][i] = i >= markerStart ? 0.2 * sinf(Float(i) * 0.05) : 0
                }
            }
        } else if let int16Data = buffer.int16ChannelData {
            for ch in 0 ..< Int(channels) {
                for i in 0 ..< Int(frameCount) {
                    let markerStart = tailMarkerFraction.map { Int(Double(frameCount) * $0) } ?? 0
                    int16Data[ch][i] = i >= markerStart ? Int16(6400 * sin(Double(i) * 0.05)) : 0
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
        file.close()
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

    private func assertFrameCoverageAndTailMarker(
        _ url: URL,
        sourceFrames: AVAudioFrameCount,
        sourceRate: Double
    ) throws {
        let file = try AVAudioFile(forReading: url)
        let expectedFrames = Int64((Double(sourceFrames) * 16_000 / sourceRate).rounded())
        XCTAssertLessThanOrEqual(abs(file.length - expectedFrames), 1)

        let frames = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            return XCTFail("failed to allocate output inspection buffer")
        }
        try file.read(into: buffer)
        guard let samples = buffer.floatChannelData?[0] else {
            return XCTFail("missing converted samples")
        }
        let tailStart = max(0, Int(buffer.frameLength) - max(16, Int(buffer.frameLength) / 20))
        let tailPeak = (tailStart ..< Int(buffer.frameLength)).reduce(Float.zero) {
            max($0, abs(samples[$1]))
        }
        XCTAssertGreaterThan(tailPeak, 0.05, "final audio marker was truncated")
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

    func testTranscodeLongProductionRatesPreservesEveryFrameAndTail() throws {
        for rate in [8_000.0, 16_000.0, 44_100.0, 48_000.0] {
            let sourceFrames = AVAudioFrameCount(rate * 2)
            let input = try writeAudioFile(
                name: "long-\(Int(rate)).caf",
                sampleRate: rate,
                channels: 1,
                commonFormat: .pcmFormatFloat32,
                frameCount: sourceFrames,
                interleaved: false,
                tailMarkerFraction: 0.8
            )
            let out = try CloudAudioTranscoder.transcodeToWAV16k(input)
            defer { try? FileManager.default.removeItem(at: out) }
            try assertFrameCoverageAndTailMarker(out, sourceFrames: sourceFrames, sourceRate: rate)
        }
    }

    func testTranscodeShortAndOddFrameInputsPreserveCoverageAndTail() throws {
        for (rate, sourceFrames) in [(48_000.0, AVAudioFrameCount(4_800)),
                                     (44_100.0, AVAudioFrameCount(88_201))] {
            let input = try writeAudioFile(
                name: "edge-\(Int(rate))-\(sourceFrames).caf",
                sampleRate: rate,
                channels: 1,
                commonFormat: .pcmFormatFloat32,
                frameCount: sourceFrames,
                interleaved: false,
                tailMarkerFraction: 0.8
            )
            let out = try CloudAudioTranscoder.transcodeToWAV16k(input)
            defer { try? FileManager.default.removeItem(at: out) }
            try assertFrameCoverageAndTailMarker(out, sourceFrames: sourceFrames, sourceRate: rate)
        }
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

    func testWavUploadPayload_preservesLongTailAndMetadata() throws {
        let sourceFrames: AVAudioFrameCount = 96_000
        let input = try writeAudioFile(
            name: "payload-src.caf",
            sampleRate: 48_000,
            channels: 1,
            commonFormat: .pcmFormatFloat32,
            frameCount: sourceFrames,
            interleaved: false,
            tailMarkerFraction: 0.8
        )
        let payload = try CloudAudioTranscoder.wavUploadPayload(from: input)
        XCTAssertEqual(payload.fileName, CloudAudioTranscoder.uploadFileName)
        XCTAssertEqual(payload.mimeType, CloudAudioTranscoder.uploadMimeType)
        XCTAssertEqual(Array(payload.data.prefix(4)), Array("RIFF".utf8))
        let persistedPayload = tempDir.appendingPathComponent("persisted-payload.wav")
        try payload.data.write(to: persistedPayload)
        try assertFrameCoverageAndTailMarker(
            persistedPayload,
            sourceFrames: sourceFrames,
            sourceRate: 48_000
        )
    }

    func testErrorDescriptionsAreNonEmpty() {
        let cases: [CloudAudioTranscoderError] = [
            .emptyInput,
            .emptyOutput,
            .formatConstructionFailed,
            .converterConstructionFailed,
            .bufferAllocationFailed,
            .conversionFailed,
            .incompleteConversion(expectedFrames: 10, actualFrames: 9),
            .writeFailed
        ]
        for error in cases {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "\(error)")
        }
    }
}
