import XCTest
@testable import Voice

final class SecureInputTests: XCTestCase {

    func testSecureInputActiveNeverLogsAndSurfacesSecureInputBlocked() {
        let outcome = TranscriptionPipeline.secureInputOutcome(
            secureInput: true,
            insertResult: .failed
        )
        XCTAssertFalse(outcome.shouldLog)
        XCTAssertEqual(outcome.failure, .secureInputBlocked)
        XCTAssertEqual(outcome.pipelineResult, .failed)
    }

    /// insertResult.failed + secureInput → secureInputBlocked, shouldLog false
    /// (clipboard / abort path must not override secure-input outcome).
    func testSecureInputOutcomeFailedInsertStillSecureInputBlocked() {
        let outcome = TranscriptionPipeline.secureInputOutcome(
            secureInput: true,
            insertResult: .failed
        )
        XCTAssertFalse(outcome.shouldLog)
        XCTAssertEqual(outcome.failure, .secureInputBlocked)
        XCTAssertNotEqual(outcome.failure, .injectionFailed)
        XCTAssertEqual(outcome.pipelineResult, .failed)
    }

    /// Callers of `shouldLeaveTranscriptOnClipboard` / `finishInjectGate` /
    /// `secureInputOutcome` must pass a **live** secure flag (fresh main-thread
    /// `IsSecureEventInputEnabled()` at the inject gate), not an earlier sample.
    func testShouldLeaveTranscriptOnClipboardAbortWithoutSecure() {
        XCTAssertTrue(
            TranscriptionPipeline.shouldLeaveTranscriptOnClipboard(
                abortForAppSwitch: true,
                secureInput: false
            )
        )
    }

    func testShouldLeaveTranscriptOnClipboardSecureNever() {
        XCTAssertFalse(
            TranscriptionPipeline.shouldLeaveTranscriptOnClipboard(
                abortForAppSwitch: true,
                secureInput: true
            )
        )
        XCTAssertFalse(
            TranscriptionPipeline.shouldLeaveTranscriptOnClipboard(
                abortForAppSwitch: false,
                secureInput: true
            )
        )
    }

    func testShouldLeaveTranscriptOnClipboardNoAbort() {
        XCTAssertFalse(
            TranscriptionPipeline.shouldLeaveTranscriptOnClipboard(
                abortForAppSwitch: false,
                secureInput: false
            )
        )
    }

    /// Live secure at the gate wins over abort (`blockedSecureInput`).
    /// Clipboard leave uses the same `shouldLeave…` helper with a live secure flag
    /// (caller re-reads on main; this test only exercises the pure helper).
    func testFinishInjectGateLiveSecureBlocksEvenWhenAbort() {
        XCTAssertEqual(
            TranscriptionPipeline.finishInjectGate(abortForAppSwitch: true, liveSecure: true),
            .blockedSecureInput
        )
        XCTAssertFalse(
            TranscriptionPipeline.shouldLeaveTranscriptOnClipboard(
                abortForAppSwitch: true,
                secureInput: true
            )
        )
    }

    /// When leave path is given secureInput=true (live flag), must not leave clipboard.
    func testAbortPathLeaveClipboardBlockedWhenLiveSecureTrue() {
        XCTAssertFalse(
            TranscriptionPipeline.shouldLeaveTranscriptOnClipboard(
                abortForAppSwitch: true,
                secureInput: true
            )
        )
        // Gate with secure at sample already blocks before leave.
        XCTAssertEqual(
            TranscriptionPipeline.finishInjectGate(abortForAppSwitch: true, liveSecure: true),
            .blockedSecureInput
        )
    }

    func testFinishInjectGateAbortWithoutLiveSecureLeavesClipboardPath() {
        XCTAssertEqual(
            TranscriptionPipeline.finishInjectGate(abortForAppSwitch: true, liveSecure: false),
            .abortedAppSwitch
        )
        XCTAssertTrue(
            TranscriptionPipeline.shouldLeaveTranscriptOnClipboard(
                abortForAppSwitch: true,
                secureInput: false
            )
        )
    }

    func testFinishInjectGateProceedInsertWhenNeither() {
        XCTAssertEqual(
            TranscriptionPipeline.finishInjectGate(abortForAppSwitch: false, liveSecure: false),
            .proceedInsert
        )
    }

    func testFinishInjectGateLiveSecureAloneBlocks() {
        XCTAssertEqual(
            TranscriptionPipeline.finishInjectGate(abortForAppSwitch: false, liveSecure: true),
            .blockedSecureInput
        )
    }

    /// PID abort plan is decided before fresh AX / inject transforms.
    func testInjectAXPlanAbortPrecedesTransformsWhenPIDsMismatch() {
        XCTAssertEqual(
            TranscriptionPipeline.injectAXPlan(
                replaceHistoryEntryID: nil,
                heldPID: 1,
                currentPID: 2
            ),
            .abortWithoutFreshAX
        )
    }

    func testInjectAXPlanResolveWhenPIDsMatch() {
        XCTAssertEqual(
            TranscriptionPipeline.injectAXPlan(
                replaceHistoryEntryID: nil,
                heldPID: 7,
                currentPID: 7
            ),
            .resolveWithOptionalFresh
        )
    }

    func testInjectAXPlanHistoryRetryNeverAborts() {
        XCTAssertEqual(
            TranscriptionPipeline.injectAXPlan(
                replaceHistoryEntryID: UUID(),
                heldPID: 1,
                currentPID: 2
            ),
            .resolveWithOptionalFresh
        )
    }

    func testInjectAXPlanNilPIDFailOpenResolves() {
        XCTAssertEqual(
            TranscriptionPipeline.injectAXPlan(
                replaceHistoryEntryID: nil,
                heldPID: nil,
                currentPID: 2
            ),
            .resolveWithOptionalFresh
        )
    }

    /// Late pre-insert PID check mirrors injectAXPlan abort rules.
    func testShouldAbortInjectAfterTransformsMismatchAborts() {
        XCTAssertTrue(
            TranscriptionPipeline.shouldAbortInjectAfterTransforms(
                replaceHistoryEntryID: nil,
                heldPID: 1,
                latePID: 2
            )
        )
    }

    func testShouldAbortInjectAfterTransformsMatchAllows() {
        XCTAssertFalse(
            TranscriptionPipeline.shouldAbortInjectAfterTransforms(
                replaceHistoryEntryID: nil,
                heldPID: 7,
                latePID: 7
            )
        )
    }

    func testShouldAbortInjectAfterTransformsHistoryRetryNeverAborts() {
        XCTAssertFalse(
            TranscriptionPipeline.shouldAbortInjectAfterTransforms(
                replaceHistoryEntryID: UUID(),
                heldPID: 1,
                latePID: 2
            )
        )
    }

    func testShouldAbortInjectAfterTransformsNilPIDFailOpen() {
        XCTAssertFalse(
            TranscriptionPipeline.shouldAbortInjectAfterTransforms(
                replaceHistoryEntryID: nil,
                heldPID: nil,
                latePID: 2
            )
        )
        XCTAssertFalse(
            TranscriptionPipeline.shouldAbortInjectAfterTransforms(
                replaceHistoryEntryID: nil,
                heldPID: 1,
                latePID: nil
            )
        )
    }

    /// Carbon cannot flip secure in unit tests — exercise the pure re-read seam
    /// that wires proceedInsert-failed → secureInputBlocked.
    func testOutcomeSecureAfterInsertElevatesWhenProceedFailedAndLiveSecure() {
        XCTAssertTrue(
            TranscriptionPipeline.outcomeSecureAfterInsert(
                proceeded: true,
                insertFailed: true,
                liveSecureAtGate: false,
                liveSecureAfterInsert: true
            )
        )
    }

    func testOutcomeSecureAfterInsertKeepsGateWhenInsertDidNotFailSecure() {
        XCTAssertFalse(
            TranscriptionPipeline.outcomeSecureAfterInsert(
                proceeded: true,
                insertFailed: true,
                liveSecureAtGate: false,
                liveSecureAfterInsert: false
            )
        )
        XCTAssertTrue(
            TranscriptionPipeline.outcomeSecureAfterInsert(
                proceeded: false,
                insertFailed: true,
                liveSecureAtGate: true,
                liveSecureAfterInsert: false
            )
        )
        XCTAssertFalse(
            TranscriptionPipeline.outcomeSecureAfterInsert(
                proceeded: true,
                insertFailed: false,
                liveSecureAtGate: false,
                liveSecureAfterInsert: true
            )
        )
    }

    /// Outcome seam must receive the same liveSecure as the inject gate (or the
    /// elevated flag from `outcomeSecureAfterInsert` / abort-leave re-read).
    func testSecureInputOutcomeUsesLiveFlagNotStaleSemantics() {
        // Gate blocked with liveSecure=true → outcome must be secureInputBlocked
        // even though insertResult is .failed (same as abort path's insertResult).
        let liveBlocked = TranscriptionPipeline.secureInputOutcome(
            secureInput: true,
            insertResult: .failed
        )
        XCTAssertEqual(liveBlocked.failure, .secureInputBlocked)
        XCTAssertFalse(liveBlocked.shouldLog)

        // Same insertResult with liveSecure=false → injectionFailed (abort/fail path).
        let liveClear = TranscriptionPipeline.secureInputOutcome(
            secureInput: false,
            insertResult: .failed
        )
        XCTAssertEqual(liveClear.failure, .injectionFailed)
        XCTAssertTrue(liveClear.shouldLog)
    }

    func testInjectionFailedWithoutSecureInputLogsAndSurfacesInjectionFailed() {
        let outcome = TranscriptionPipeline.secureInputOutcome(
            secureInput: false,
            insertResult: .failed
        )
        XCTAssertTrue(outcome.shouldLog)
        XCTAssertEqual(outcome.failure, .injectionFailed)
        XCTAssertEqual(outcome.pipelineResult, .failed)
    }

    func testSuccessfulInjectionWithoutSecureInputLogsWithNoFailure() {
        let outcome = TranscriptionPipeline.secureInputOutcome(
            secureInput: false,
            insertResult: .inserted(deliveredText: "hi")
        )
        XCTAssertTrue(outcome.shouldLog)
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(outcome.pipelineResult, .inserted)
    }

    func testDedupedSkipsHistoryAndDoesNotSurfaceInjectionFailed() {
        let outcome = TranscriptionPipeline.secureInputOutcome(
            secureInput: false,
            insertResult: .deduped
        )
        XCTAssertFalse(outcome.shouldLog)
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(outcome.pipelineResult, .deduped)
    }

    func testShouldAbortInjectForFrontmostMismatchBothKnownUnequal() {
        XCTAssertTrue(
            TranscriptionPipeline.shouldAbortInjectForFrontmostMismatch(held: 1, current: 2)
        )
    }

    func testShouldAbortInjectForFrontmostMismatchNilFailOpen() {
        XCTAssertFalse(
            TranscriptionPipeline.shouldAbortInjectForFrontmostMismatch(held: nil, current: 2)
        )
        XCTAssertFalse(
            TranscriptionPipeline.shouldAbortInjectForFrontmostMismatch(held: 1, current: nil)
        )
        XCTAssertFalse(
            TranscriptionPipeline.shouldAbortInjectForFrontmostMismatch(held: nil, current: nil)
        )
    }

    func testShouldAbortInjectForFrontmostMismatchEqualAllows() {
        XCTAssertFalse(
            TranscriptionPipeline.shouldAbortInjectForFrontmostMismatch(held: 42, current: 42)
        )
    }

    func testInsertResultWasInjectedForHistoryOnlyInserted() {
        XCTAssertTrue(TextInjector.InsertResult.inserted(deliveredText: "x").wasInjectedForHistory)
        XCTAssertFalse(TextInjector.InsertResult.deduped.wasInjectedForHistory)
        XCTAssertFalse(TextInjector.InsertResult.failed.wasInjectedForHistory)
    }

    func testShouldAbortWhenSecureInputActivatesWhileRecording() {
        XCTAssertTrue(
            AudioRecorder.shouldAbortForSecureInput(secureInput: true, isRecording: true)
        )
    }

    func testShouldNotAbortWhenNotRecording() {
        XCTAssertFalse(
            AudioRecorder.shouldAbortForSecureInput(secureInput: true, isRecording: false)
        )
    }

    func testShouldNotAbortWhenSecureInputInactive() {
        XCTAssertFalse(
            AudioRecorder.shouldAbortForSecureInput(secureInput: false, isRecording: true)
        )
    }
}
