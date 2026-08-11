import XCTest
@testable import Voice

/// Decision logic for the mic zero-buffer watchdog and dead-format probe —
/// the guards behind the post-route-change wedge fix (a dictation hold whose
/// engine "started" but whose tap delivered zero buffers, observed 2026-08-09
/// as `max RMS 0.0000 … buffers=0` after another app's voice session).
final class MicWatchdogTests: XCTestCase {

    // MARK: - Dead-mic reporting
    //
    // A wedged input device (another app taking Sound input — observed
    // 2026-08-11 with Jump Desktop) delivers zero buffers while the engine and
    // socket both report success. The RMS silence guard cannot tell that from
    // a quiet room, so the hold used to be discarded with no visible sign.

    func testReportsDeadMicWhenNoBuffersOverARealHold() {
        XCTAssertTrue(AudioRecorder.shouldReportDeadMic(buffersSeen: 0, holdDuration: 3.0))
    }

    func testDeadMicBoundaryIsInclusive() {
        XCTAssertTrue(AudioRecorder.shouldReportDeadMic(buffersSeen: 0, holdDuration: 1.0))
    }

    /// 0.1.32 shipped a floor so an accidental split-second tap is ignored
    /// rather than erroring. A dead-mic report must not undo that.
    func testAccidentalTapStaysSilent() {
        XCTAssertFalse(AudioRecorder.shouldReportDeadMic(buffersSeen: 0, holdDuration: 0.2))
        XCTAssertFalse(AudioRecorder.shouldReportDeadMic(buffersSeen: 0, holdDuration: 0.9))
    }

    /// Buffers arrived and were merely quiet — that is the silence guard's
    /// job, and it must stay silent.
    func testQuietRoomIsNotReportedAsDeadMic() {
        XCTAssertFalse(AudioRecorder.shouldReportDeadMic(buffersSeen: 42, holdDuration: 3.0))
    }

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

    // MARK: - Mid-hold configuration-change restart

    func testConfigChangeRestartsMidHold() {
        XCTAssertTrue(
            AudioRecorder.shouldRestartCaptureOnConfigChange(
                stillWanted: true, tapInstalled: true, alreadyRetried: false
            )
        )
    }

    func testConfigChangeOnlyFlagsWhenIdle() {
        XCTAssertFalse(
            AudioRecorder.shouldRestartCaptureOnConfigChange(
                stillWanted: false, tapInstalled: false, alreadyRetried: false
            )
        )
    }

    func testConfigChangeRespectsSharedRetryBudget() {
        XCTAssertFalse(
            AudioRecorder.shouldRestartCaptureOnConfigChange(
                stillWanted: true, tapInstalled: true, alreadyRetried: true
            )
        )
    }

    func testConfigChangeDoesNotRestartAfterTeardown() {
        XCTAssertFalse(
            AudioRecorder.shouldRestartCaptureOnConfigChange(
                stillWanted: true, tapInstalled: false, alreadyRetried: false
            )
        )
    }

    // MARK: - Model-load deadline

    func testDeadlineReturnsValueWhenOperationFinishesFirst() async throws {
        let value = try await WhisperKitEngine.withDeadline(
            5,
            timeoutError: { WhisperKitEngineError.modelLoadTimedOut("test", 5) },
            operation: { "loaded" }
        )
        XCTAssertEqual(value, "loaded")
    }

    func testDeadlineThrowsWhenOperationParksForever() async {
        do {
            _ = try await WhisperKitEngine.withDeadline(
                0.1,
                timeoutError: { WhisperKitEngineError.modelLoadTimedOut("test-model", 0.1) },
                operation: { () -> String in
                    // Parked await that honors cancellation, standing in for a
                    // model load that never returns.
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    return "never"
                }
            )
            XCTFail("expected modelLoadTimedOut")
        } catch let error as WhisperKitEngineError {
            guard case .modelLoadTimedOut(let name, _) = error else {
                XCTFail("wrong case: \(error)")
                return
            }
            XCTAssertEqual(name, "test-model")
            XCTAssertTrue(error.localizedDescription.contains("retry"), "user-facing message must mention retry")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testDeadFormatDetection() {
        XCTAssertTrue(AudioRecorder.inputFormatLooksDead(sampleRate: 0, channelCount: 1))
        XCTAssertTrue(AudioRecorder.inputFormatLooksDead(sampleRate: 48_000, channelCount: 0))
        XCTAssertTrue(AudioRecorder.inputFormatLooksDead(sampleRate: 0, channelCount: 0))
        XCTAssertFalse(AudioRecorder.inputFormatLooksDead(sampleRate: 48_000, channelCount: 1))
        XCTAssertFalse(AudioRecorder.inputFormatLooksDead(sampleRate: 16_000, channelCount: 2))
    }
}
