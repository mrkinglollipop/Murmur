import XCTest
@testable import Voice

/// Decision logic for the mic zero-buffer watchdog and dead-format probe —
/// the guards behind the post-route-change wedge fix (a dictation hold whose
/// engine "started" but whose tap delivered zero buffers, observed 2026-08-09
/// as `max RMS 0.0000 … buffers=0` after another app's voice session).
final class MicWatchdogTests: XCTestCase {

    func testRestartsWhenTakeLiveAndNoBuffers() {
        XCTAssertTrue(
            AudioRecorder.watchdogShouldRestartCapture(
                generationMatches: true,
                stillWanted: true,
                tapInstalled: true,
                buffersSeen: 0,
                alreadyRetried: false
            )
        )
    }

    func testNoRestartOnceBuffersFlow() {
        XCTAssertFalse(
            AudioRecorder.watchdogShouldRestartCapture(
                generationMatches: true,
                stillWanted: true,
                tapInstalled: true,
                buffersSeen: 5,
                alreadyRetried: false
            )
        )
    }

    func testNoRestartForStaleGeneration() {
        XCTAssertFalse(
            AudioRecorder.watchdogShouldRestartCapture(
                generationMatches: false,
                stillWanted: true,
                tapInstalled: true,
                buffersSeen: 0,
                alreadyRetried: false
            )
        )
    }

    func testNoRestartAfterHoldReleased() {
        XCTAssertFalse(
            AudioRecorder.watchdogShouldRestartCapture(
                generationMatches: true,
                stillWanted: false,
                tapInstalled: true,
                buffersSeen: 0,
                alreadyRetried: false
            )
        )
    }

    func testNoRestartWithTapAlreadyTornDown() {
        XCTAssertFalse(
            AudioRecorder.watchdogShouldRestartCapture(
                generationMatches: true,
                stillWanted: true,
                tapInstalled: false,
                buffersSeen: 0,
                alreadyRetried: false
            )
        )
    }

    func testSingleRetryPerHold() {
        XCTAssertFalse(
            AudioRecorder.watchdogShouldRestartCapture(
                generationMatches: true,
                stillWanted: true,
                tapInstalled: true,
                buffersSeen: 0,
                alreadyRetried: true
            )
        )
    }

    func testDeadFormatDetection() {
        XCTAssertTrue(AudioRecorder.inputFormatLooksDead(sampleRate: 0, channelCount: 1))
        XCTAssertTrue(AudioRecorder.inputFormatLooksDead(sampleRate: 48_000, channelCount: 0))
        XCTAssertTrue(AudioRecorder.inputFormatLooksDead(sampleRate: 0, channelCount: 0))
        XCTAssertFalse(AudioRecorder.inputFormatLooksDead(sampleRate: 48_000, channelCount: 1))
        XCTAssertFalse(AudioRecorder.inputFormatLooksDead(sampleRate: 16_000, channelCount: 2))
    }
}
