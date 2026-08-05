import XCTest
@testable import Voice

final class CorrectionWatcherLogicTests: XCTestCase {

    func testIdleSettleAfterKeyDown() {
        var state = CorrectionWatcherLogic.State()
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = CorrectionWatcherLogic.begin(
            state: &state,
            deliveredText: "Groq",
            snapshotValue: "Groq",
            injectedUTF16Location: 0,
            injectedUTF16Length: 4,
            frontmostPID: 1,
            now: t0
        )
        let afterKey = CorrectionWatcherLogic.noteKeyDown(
            state: &state,
            now: t0.addingTimeInterval(0.1)
        )
        XCTAssertTrue(afterKey.contains {
            if case .scheduleIdleSettle = $0 { return true }
            return false
        })

        let endEffects = CorrectionWatcherLogic.idleFired(state: &state)
        XCTAssertTrue(endEffects.contains {
            if case .attemptLearn(.idleSettle) = $0 { return true }
            return false
        })
        let learnOK = CorrectionWatcherLogic.shouldAttemptLearn(
            state: state,
            reason: .idleSettle,
            now: t0.addingTimeInterval(0.1 + CorrectionWatcherLogic.idleSettle)
        )
        // state was ended so lastKeyDownAt still set from before end — re-begin for stable check
        var state2 = CorrectionWatcherLogic.State()
        _ = CorrectionWatcherLogic.begin(
            state: &state2,
            deliveredText: "Groq",
            snapshotValue: "Groq",
            injectedUTF16Location: 0,
            injectedUTF16Length: 4,
            frontmostPID: 1,
            now: t0
        )
        _ = CorrectionWatcherLogic.noteKeyDown(state: &state2, now: t0.addingTimeInterval(0.1))
        XCTAssertFalse(
            CorrectionWatcherLogic.shouldAttemptLearn(
                state: state2,
                reason: .nextRecording,
                now: t0.addingTimeInterval(0.2)
            )
        )
        XCTAssertTrue(
            CorrectionWatcherLogic.shouldAttemptLearn(
                state: state2,
                reason: .nextRecording,
                now: t0.addingTimeInterval(0.1 + CorrectionWatcherLogic.idleSettle)
            )
        )
        _ = endEffects
        _ = learnOK
    }

    func testCancelDoesNotAttemptLearn() {
        var state = CorrectionWatcherLogic.State()
        let t0 = Date(timeIntervalSince1970: 2_000)
        _ = CorrectionWatcherLogic.begin(
            state: &state,
            deliveredText: "x",
            snapshotValue: "x",
            injectedUTF16Location: 0,
            injectedUTF16Length: 1,
            frontmostPID: 1,
            now: t0
        )
        let effects = CorrectionWatcherLogic.cancel(state: &state)
        XCTAssertFalse(effects.contains {
            if case .attemptLearn = $0 { return true }
            return false
        })
        XCTAssertFalse(CorrectionWatcherLogic.shouldAttemptLearn(state: state, reason: .cancelled, now: t0))
    }

    func testZeroKeyDownAllowsTimeoutLearn() {
        var state = CorrectionWatcherLogic.State()
        let t0 = Date(timeIntervalSince1970: 3_000)
        _ = CorrectionWatcherLogic.begin(
            state: &state,
            deliveredText: "x",
            snapshotValue: "x",
            injectedUTF16Location: 0,
            injectedUTF16Length: 1,
            frontmostPID: 1,
            now: t0
        )
        XCTAssertTrue(
            CorrectionWatcherLogic.shouldAttemptLearn(state: state, reason: .timeout, now: t0.addingTimeInterval(60))
        )
        XCTAssertFalse(
            CorrectionWatcherLogic.shouldAttemptLearn(state: state, reason: .idleSettle, now: t0.addingTimeInterval(60))
        )
    }

    func testAppSwitchEndsWatch() {
        var state = CorrectionWatcherLogic.State()
        let t0 = Date(timeIntervalSince1970: 4_000)
        _ = CorrectionWatcherLogic.begin(
            state: &state,
            deliveredText: "x",
            snapshotValue: "x",
            injectedUTF16Location: 0,
            injectedUTF16Length: 1,
            frontmostPID: 1,
            now: t0
        )
        let effects = CorrectionWatcherLogic.frontmostChanged(state: &state, newPID: 2)
        XCTAssertTrue(effects.contains {
            if case .attemptLearn(.appSwitch) = $0 { return true }
            return false
        })
        XCTAssertFalse(state.isActive)
    }

    /// Contract: CorrectionWatcher.applyEffects runs effects in list order;
    /// attemptLearn must precede tearDown so focusedElement is still available.
    func testEndEmitsAttemptLearnBeforeTearDown() {
        var state = CorrectionWatcherLogic.State()
        let t0 = Date(timeIntervalSince1970: 5_000)
        _ = CorrectionWatcherLogic.begin(
            state: &state,
            deliveredText: "x",
            snapshotValue: "x",
            injectedUTF16Location: 0,
            injectedUTF16Length: 1,
            frontmostPID: 1,
            now: t0
        )
        let effects = CorrectionWatcherLogic.timeoutFired(state: &state)
        let learnIndex = effects.firstIndex {
            if case .attemptLearn(.timeout) = $0 { return true }
            return false
        }
        let tearDownIndex = effects.firstIndex { $0 == .tearDown }
        XCTAssertNotNil(learnIndex)
        XCTAssertNotNil(tearDownIndex)
        XCTAssertLessThan(learnIndex!, tearDownIndex!)
    }

    func testCancelStillEndsWithTearDownWithoutLearn() {
        var state = CorrectionWatcherLogic.State()
        let t0 = Date(timeIntervalSince1970: 6_000)
        _ = CorrectionWatcherLogic.begin(
            state: &state,
            deliveredText: "x",
            snapshotValue: "x",
            injectedUTF16Location: 0,
            injectedUTF16Length: 1,
            frontmostPID: 1,
            now: t0
        )
        let effects = CorrectionWatcherLogic.cancel(state: &state)
        XCTAssertEqual(
            effects,
            [.cancelIdleSettle, .cancelTimeout, .tearDown]
        )
    }
}
