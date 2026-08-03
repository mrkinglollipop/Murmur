import XCTest
@testable import Voice

final class ActivationControllerHoldTimerTests: XCTestCase {

    func testShouldFireHoldTimer_acceptsCurrentUncancelledWorkWithLiveTap() {
        let work = DispatchWorkItem {}
        XCTAssertTrue(
            ActivationController.shouldFireHoldTimer(
                work: work,
                current: work,
                tapAlive: true
            )
        )
    }

    func testShouldFireHoldTimer_rejectsWhenCurrentIsNil() {
        let work = DispatchWorkItem {}
        XCTAssertFalse(
            ActivationController.shouldFireHoldTimer(
                work: work,
                current: nil,
                tapAlive: true
            )
        )
    }

    func testShouldFireHoldTimer_rejectsWhenCurrentDiffers() {
        let scheduled = DispatchWorkItem {}
        let other = DispatchWorkItem {}
        XCTAssertFalse(
            ActivationController.shouldFireHoldTimer(
                work: scheduled,
                current: other,
                tapAlive: true
            )
        )
    }

    func testShouldFireHoldTimer_rejectsCancelledWork() {
        let work = DispatchWorkItem {}
        work.cancel()
        XCTAssertFalse(
            ActivationController.shouldFireHoldTimer(
                work: work,
                current: work,
                tapAlive: true
            )
        )
    }

    func testShouldFireHoldTimer_rejectsWhenTapNotAlive() {
        let work = DispatchWorkItem {}
        XCTAssertFalse(
            ActivationController.shouldFireHoldTimer(
                work: work,
                current: work,
                tapAlive: false
            )
        )
    }
}
