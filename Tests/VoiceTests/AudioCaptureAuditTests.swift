import AVFoundation
import XCTest
@testable import Voice

/// Guards for the mid-hold device-reroute failure modes: mixed-format buffers
/// in `pcmBuffers`, a release racing a restart, and the enrollment tap on a
/// dead default input.
final class AudioCaptureAuditTests: XCTestCase {

    private func makeBuffer(sampleRate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount, value: Float = 0.25) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0 ..< Int(channels) {
            for i in 0 ..< Int(frames) { buffer.floatChannelData![ch][i] = value }
        }
        return buffer
    }

    // MARK: - combine(buffers:)

    func testCombineEmptyReturnsNil() {
        XCTAssertNil(AudioRecorder.combine(buffers: []))
    }

    func testCombineUniformFormatConcatenatesExactly() throws {
        let a = makeBuffer(sampleRate: 48_000, channels: 1, frames: 480)
        let b = makeBuffer(sampleRate: 48_000, channels: 1, frames: 240)
        let combined = try XCTUnwrap(AudioRecorder.combine(buffers: [a, b]))
        XCTAssertEqual(combined.frameLength, 720)
        XCTAssertEqual(combined.format.sampleRate, 48_000)
    }

    func testCombineMixedSampleRateResamplesToFirstFormat() throws {
        // 0.1 s at 48 kHz then 0.1 s at 16 kHz: total should be ~0.2 s at 48 kHz.
        let a = makeBuffer(sampleRate: 48_000, channels: 1, frames: 4_800)
        let b = makeBuffer(sampleRate: 16_000, channels: 1, frames: 1_600)
        let combined = try XCTUnwrap(AudioRecorder.combine(buffers: [a, b]))
        XCTAssertEqual(combined.format.sampleRate, 48_000)
        XCTAssertEqual(Double(combined.frameLength), 9_600, accuracy: 9_600 * 0.1)
    }

    func testCombineStereoThenMonoDoesNotReadOutOfBounds() throws {
        let stereo = makeBuffer(sampleRate: 48_000, channels: 2, frames: 480)
        let mono = makeBuffer(sampleRate: 48_000, channels: 1, frames: 480)
        let combined = try XCTUnwrap(AudioRecorder.combine(buffers: [stereo, mono]))
        XCTAssertEqual(combined.format.channelCount, 2)
        XCTAssertEqual(combined.frameLength, 960)
    }

    func testCombineMonoThenStereoDownmixesToFirstFormat() throws {
        let mono = makeBuffer(sampleRate: 48_000, channels: 1, frames: 480)
        let stereo = makeBuffer(sampleRate: 48_000, channels: 2, frames: 480)
        let combined = try XCTUnwrap(AudioRecorder.combine(buffers: [mono, stereo]))
        XCTAssertEqual(combined.format.channelCount, 1)
        XCTAssertEqual(combined.frameLength, 960)
    }

    // MARK: - shouldDiscardAsMicNotSetup

    func testDiscardAsMicNotSetupTruthTable() {
        XCTAssertTrue(AudioRecorder.shouldDiscardAsMicNotSetup(isSetUp: false, bufferCount: 0))
        XCTAssertFalse(AudioRecorder.shouldDiscardAsMicNotSetup(isSetUp: false, bufferCount: 5))
        XCTAssertFalse(AudioRecorder.shouldDiscardAsMicNotSetup(isSetUp: true, bufferCount: 0))
        XCTAssertFalse(AudioRecorder.shouldDiscardAsMicNotSetup(isSetUp: true, bufferCount: 5))
    }

    // MARK: - EnrollmentCapture.shouldAttemptTap

    func testEnrollmentRejectsDeadFormats() {
        XCTAssertFalse(EnrollmentCapture.shouldAttemptTap(sampleRate: 0, channelCount: 1))
        XCTAssertFalse(EnrollmentCapture.shouldAttemptTap(sampleRate: 48_000, channelCount: 0))
        XCTAssertFalse(EnrollmentCapture.shouldAttemptTap(sampleRate: 0, channelCount: 0))
        XCTAssertTrue(EnrollmentCapture.shouldAttemptTap(sampleRate: 48_000, channelCount: 1))
    }
}
