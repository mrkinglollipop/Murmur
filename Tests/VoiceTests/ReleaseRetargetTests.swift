import XCTest
@testable import Voice

/// Hold-start targeting applies to both voice edits and ordinary dictation.
final class ReleaseRetargetTests: XCTestCase {

    func testEditCapturedInAReleasedOverBDoesNotInjectIntoB() {
        let held = CaretContext.Snapshot(value: "old words", location: 0,
            selectionLength: .readable(9), precedingChar: .startOfField, isUnknown: false)
        XCTAssertEqual(VoiceEditRouting.decide(snapshot: held, enabled: true, shiftHeld: false),
                       .edit(selection: "old words"))
        XCTAssertTrue(VoiceEditRouting.resultLooksUsable("new words", over: "old words"))
        let deliveryPID: pid_t = AudioRecorder.shouldRetargetSessionHoldAtRelease(startPID: 42, releasePID: 99) ? 99 : 42
        XCTAssertTrue(TranscriptionPipeline.shouldAbortInjectForFrontmostMismatch(held: deliveryPID, current: 99))
    }

    // Unknown release identity → keep the start-time hold (fail toward the
    // long-verified behavior, never toward a nil-anchored inject).
    func testNoRetargetWhenReleasePIDUnknown() {
        XCTAssertFalse(
            AudioRecorder.shouldRetargetSessionHoldAtRelease(startPID: 1, releasePID: nil)
        )
        XCTAssertFalse(
            AudioRecorder.shouldRetargetSessionHoldAtRelease(startPID: nil, releasePID: nil)
        )
    }

    // Same app at press and release → byte-for-byte the old code path.
    func testNoRetargetWhenAppUnchanged() {
        XCTAssertFalse(
            AudioRecorder.shouldRetargetSessionHoldAtRelease(startPID: 42, releasePID: 42)
        )
    }

    // Switching apps during a hold does not authorize a new destination.
    func testKeepsOriginalTargetWhenAppChangedDuringHold() {
        XCTAssertFalse(
            AudioRecorder.shouldRetargetSessionHoldAtRelease(startPID: 1, releasePID: 2)
        )
    }

    // Missing hold-start identity cannot be repaired by adopting another app.
    func testDoesNotAdoptReleaseAppWhenStartPIDUnknown() {
        XCTAssertFalse(
            AudioRecorder.shouldRetargetSessionHoldAtRelease(startPID: nil, releasePID: 7)
        )
    }
}
