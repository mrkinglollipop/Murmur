import XCTest
@testable import Voice

final class FnActivationLogicTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func t(_ offset: TimeInterval) -> Date {
        t0.addingTimeInterval(offset)
    }

  // MARK: - Helpers

    private func down(
        _ state: inout FnActivationLogic.State,
        toggleLock: Bool,
        at offset: TimeInterval
    ) -> [FnActivationLogic.Effect] {
        FnActivationLogic.handle(
            state: &state,
            fnDown: true,
            useToggleLock: toggleLock,
            now: t(offset)
        )
    }

    private func up(
        _ state: inout FnActivationLogic.State,
        toggleLock: Bool,
        at offset: TimeInterval
    ) -> [FnActivationLogic.Effect] {
        FnActivationLogic.handle(
            state: &state,
            fnDown: false,
            useToggleLock: toggleLock,
            now: t(offset)
        )
    }

    private func timerFired(
        _ state: inout FnActivationLogic.State,
        toggleLock: Bool = true,
        at offset: TimeInterval
    ) -> [FnActivationLogic.Effect] {
        FnActivationLogic.handleHoldTimerFired(
            state: &state,
            useToggleLock: toggleLock,
            now: t(offset)
        )
    }

    // MARK: - §2 scenarios

    func testHoldToTalk_toggleLockOff() {
        var state = FnActivationLogic.State()

        let start = down(&state, toggleLock: false, at: 0)
        XCTAssertEqual(start, [.startRecording])
        XCTAssertTrue(state.isRecording)
        XCTAssertFalse(state.isToggleLocked)

        let stop = up(&state, toggleLock: false, at: 0.5)
        XCTAssertEqual(stop, [.stopRecording])
        XCTAssertFalse(state.isRecording)
    }

    func testFirstTapPreservesAnchorWithoutRecording() {
        var state = FnActivationLogic.State()

        let effects = down(&state, toggleLock: true, at: 0)
        XCTAssertEqual(effects.count, 1)
        guard case .scheduleHoldTimer(let deadline) = effects[0] else {
            XCTFail("expected scheduleHoldTimer")
            return
        }
        XCTAssertEqual(deadline, t(FnActivationLogic.holdThreshold))
        XCTAssertFalse(state.isRecording)
        XCTAssertFalse(state.isToggleLocked)
        XCTAssertEqual(state.firstTapAnchor, t(0))
        XCTAssertTrue(state.fnPhysicallyDown)
    }

    func testFnUpBeforeHoldThresholdCancelsTimerKeepsAnchor() {
        var state = FnActivationLogic.State()
        _ = down(&state, toggleLock: true, at: 0)

        let effects = up(&state, toggleLock: true, at: 0.05)
        XCTAssertEqual(effects, [.cancelHoldTimer])
        XCTAssertFalse(state.isRecording)
        XCTAssertEqual(state.firstTapAnchor, t(0))
        XCTAssertNil(state.holdDeadline)
        XCTAssertFalse(state.fnPhysicallyDown)
    }

    func testSecondTapInside400msLocksAndStartsOnce() {
        var state = FnActivationLogic.State()
        _ = down(&state, toggleLock: true, at: 0)
        _ = up(&state, toggleLock: true, at: 0.05)

        let effects = down(&state, toggleLock: true, at: 0.1)
        XCTAssertEqual(effects, [.startRecording, .cancelHoldTimer])
        XCTAssertTrue(state.isRecording)
        XCTAssertTrue(state.isToggleLocked)
        XCTAssertNil(state.firstTapAnchor)
        XCTAssertNil(state.holdDeadline)
    }

    func testSecondFnDownDoesNotScheduleHoldTimer() {
        var state = FnActivationLogic.State()
        _ = down(&state, toggleLock: true, at: 0)
        _ = up(&state, toggleLock: true, at: 0.05)

        let effects = down(&state, toggleLock: true, at: 0.1)
        XCTAssertFalse(effects.contains { effect in
            if case .scheduleHoldTimer = effect { return true }
            return false
        })
    }

    func testReleaseWhileLockedDoesNotStop() {
        var state = FnActivationLogic.State()
        _ = down(&state, toggleLock: true, at: 0)
        _ = up(&state, toggleLock: true, at: 0.05)
        _ = down(&state, toggleLock: true, at: 0.1)

        let effects = up(&state, toggleLock: true, at: 0.2)
        XCTAssertEqual(effects, [.cancelHoldTimer])
        XCTAssertTrue(state.isRecording)
        XCTAssertTrue(state.isToggleLocked)
    }

    func testFirstTapExpiryAfter400ms() {
        var state = FnActivationLogic.State()
        _ = down(&state, toggleLock: true, at: 0)
        _ = up(&state, toggleLock: true, at: 0.05)

        let noop = FnActivationLogic.handle(
            state: &state,
            fnDown: false,
            useToggleLock: true,
            now: t(0.4)
        )
        XCTAssertTrue(noop.isEmpty)
        XCTAssertFalse(state.isRecording)
        XCTAssertNil(state.firstTapAnchor)

        let rearm = down(&state, toggleLock: true, at: 0.41)
        XCTAssertEqual(rearm.count, 1)
        guard case .scheduleHoldTimer(let deadline) = rearm[0] else {
            XCTFail("expected scheduleHoldTimer after expiry re-arm")
            return
        }
        XCTAssertEqual(deadline, t(0.41 + FnActivationLogic.holdThreshold))
        XCTAssertFalse(state.isRecording)
        XCTAssertEqual(state.firstTapAnchor, t(0.41))
    }

    func testHoldPast150msStartsPTT_releaseStops() {
        var state = FnActivationLogic.State()
        _ = down(&state, toggleLock: true, at: 0)

        let timerEffects = timerFired(&state, at: FnActivationLogic.holdThreshold)
        XCTAssertEqual(timerEffects, [.startRecording])
        XCTAssertTrue(state.isRecording)
        XCTAssertFalse(state.isToggleLocked)
        XCTAssertNil(state.firstTapAnchor)

        let stop = up(&state, toggleLock: true, at: 0.3)
        XCTAssertEqual(stop, [.cancelHoldTimer, .stopRecording])
        XCTAssertFalse(state.isRecording)
    }

    func testFirstEventWins_secondTapBeforeHoldFire_lockWins() {
        var state = FnActivationLogic.State()
        _ = down(&state, toggleLock: true, at: 0)
        _ = up(&state, toggleLock: true, at: 0.05)

        let lockEffects = down(&state, toggleLock: true, at: 0.1)
        XCTAssertEqual(lockEffects, [.startRecording, .cancelHoldTimer])
        XCTAssertTrue(state.isToggleLocked)

        let timerEffects = timerFired(&state, at: FnActivationLogic.holdThreshold)
        XCTAssertTrue(timerEffects.isEmpty)
        XCTAssertTrue(state.isRecording)
        XCTAssertTrue(state.isToggleLocked)
    }

    func testFirstEventWins_holdFireBeforeSecondTap_PTTWins() {
        var state = FnActivationLogic.State()
        _ = down(&state, toggleLock: true, at: 0)

        let timerEffects = timerFired(&state, at: FnActivationLogic.holdThreshold)
        XCTAssertEqual(timerEffects, [.startRecording])
        XCTAssertFalse(state.isToggleLocked)

        let stillHolding = down(&state, toggleLock: true, at: FnActivationLogic.holdThreshold + 0.05)
        XCTAssertTrue(stillHolding.isEmpty)
        XCTAssertTrue(state.isRecording)
        XCTAssertFalse(state.isToggleLocked)
    }

    func testTapWhileLockedStops() {
        var state = FnActivationLogic.State()
        _ = down(&state, toggleLock: true, at: 0)
        _ = up(&state, toggleLock: true, at: 0.05)
        _ = down(&state, toggleLock: true, at: 0.1)
        _ = up(&state, toggleLock: true, at: 0.15)

        let effects = down(&state, toggleLock: true, at: 0.2)
        XCTAssertEqual(effects, [.stopRecording, .cancelHoldTimer])
        XCTAssertFalse(state.isRecording)
        XCTAssertFalse(state.isToggleLocked)
    }

    func testResyncAfterTapReenable_clearsAnchorsAndCancelsHoldTimer() {
        var state = FnActivationLogic.State()
        state.firstTapAnchor = t(0)
        state.holdDeadline = t(FnActivationLogic.holdThreshold)
        state.fnPhysicallyDown = true

        let effects = FnActivationLogic.resyncAfterTapReenable(state: &state, fnHeld: true)

        XCTAssertEqual(effects, [.cancelHoldTimer])
        XCTAssertNil(state.firstTapAnchor)
        XCTAssertNil(state.holdDeadline)
        XCTAssertTrue(state.fnPhysicallyDown)
    }

    func testResyncAfterTapReenable_stopsStuckPTTWhenFnNotHeld() {
        var state = FnActivationLogic.State()
        state.isRecording = true
        state.isToggleLocked = false
        state.fnPhysicallyDown = true

        let effects = FnActivationLogic.resyncAfterTapReenable(state: &state, fnHeld: false)

        XCTAssertEqual(effects, [.cancelHoldTimer, .stopStuckPTTRecording])
        XCTAssertFalse(state.isRecording)
        XCTAssertFalse(state.fnPhysicallyDown)
    }

    func testResyncAfterTapReenable_doesNotStopLockedRecordingWhenFnNotHeld() {
        var state = FnActivationLogic.State()
        state.isRecording = true
        state.isToggleLocked = true
        state.fnPhysicallyDown = true

        let effects = FnActivationLogic.resyncAfterTapReenable(state: &state, fnHeld: false)

        XCTAssertEqual(effects, [.cancelHoldTimer, .logStuckToggleLockRecording])
        XCTAssertTrue(state.isRecording)
        XCTAssertTrue(state.isToggleLocked)
        XCTAssertFalse(state.fnPhysicallyDown)
    }

    func testReconcilePhysicalDownAfterRestart_syncsWithoutStartingRecording() {
        var state = FnActivationLogic.State()
        state.isRecording = false

        FnActivationLogic.reconcilePhysicalDownAfterRestart(state: &state, fnHeld: true)
        XCTAssertTrue(state.fnPhysicallyDown)
        XCTAssertFalse(state.isRecording)

        FnActivationLogic.reconcilePhysicalDownAfterRestart(state: &state, fnHeld: false)
        XCTAssertFalse(state.fnPhysicallyDown)
        XCTAssertFalse(state.isRecording)
    }

    func testReconcilePhysicalDownAfterRestart_edgeUpAfterHeldRestartCanStop() {
        var state = FnActivationLogic.State()
        FnActivationLogic.reconcilePhysicalDownAfterRestart(state: &state, fnHeld: true)
        state.isRecording = true

        let effects = up(&state, toggleLock: true, at: 0)
        XCTAssertEqual(effects, [.cancelHoldTimer, .stopRecording])
        XCTAssertFalse(state.isRecording)
        XCTAssertFalse(state.fnPhysicallyDown)
    }

    func testNoDuplicateStartStopEffects() {
        var classic = FnActivationLogic.State()
        let classicStart = down(&classic, toggleLock: false, at: 0)
        XCTAssertEqual(classicStart.filter { $0 == .startRecording }.count, 1)
        let classicStop = up(&classic, toggleLock: false, at: 0.5)
        XCTAssertEqual(classicStop.filter { $0 == .stopRecording }.count, 1)

        var lock = FnActivationLogic.State()
        _ = down(&lock, toggleLock: true, at: 0)
        _ = up(&lock, toggleLock: true, at: 0.05)
        let lockStart = down(&lock, toggleLock: true, at: 0.1)
        XCTAssertEqual(lockStart.filter { $0 == .startRecording }.count, 1)

        _ = up(&lock, toggleLock: true, at: 0.15)
        let stopLocked = down(&lock, toggleLock: true, at: 0.2)
        XCTAssertEqual(stopLocked.filter { $0 == .stopRecording }.count, 1)
    }
}
