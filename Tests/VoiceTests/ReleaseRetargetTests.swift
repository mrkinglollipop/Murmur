import XCTest
@testable import Voice

/// Release-time targeting (2026-08-10): the app frontmost at hotkey RELEASE
/// is the inject destination; the hold-start app is only kept when the
/// release sample has no identity or the app never changed. Covers the pure
/// seam behind `retargetedSessionHoldAtRelease` — the AX/NSWorkspace shell
/// stays thin and untested by design (same pattern as the mic-watchdog
/// seams).
final class ReleaseRetargetTests: XCTestCase {

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

    // The live 2026-08-10 abort: hold started in one app, released in the
    // intended one. Release wins.
    func testRetargetsWhenAppChangedDuringHold() {
        XCTAssertTrue(
            AudioRecorder.shouldRetargetSessionHoldAtRelease(startPID: 1, releasePID: 2)
        )
    }

    // Start-time identity missing but release known → adopt the release app
    // (strictly more information than the fail-open nil-held path had).
    func testRetargetsWhenStartPIDUnknownButReleaseKnown() {
        XCTAssertTrue(
            AudioRecorder.shouldRetargetSessionHoldAtRelease(startPID: nil, releasePID: 7)
        )
    }
}
