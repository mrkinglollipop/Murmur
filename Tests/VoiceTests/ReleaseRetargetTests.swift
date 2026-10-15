import ApplicationServices
import XCTest
@testable import Voice

/// Release-time targeting: ordinary dictation goes to the app frontmost at
/// hotkey RELEASE. A hold-start selection edit never follows the release to
/// another app; the retarget drops it and the take is delivered as dictation.
final class ReleaseRetargetTests: XCTestCase {

    private final class Observer: TextInjectionObserver {
        var observedUTF16Units = 0
        var observedPasteChordCount = 0
        var keycodeZeroKeyDownCount = 0
        var canaryObservedCount = 0
        var wentBlind = false
        func resetObservedCount() { observedUTF16Units = 0 }
        func resetCanaryCount() { canaryObservedCount = 0 }
        func stop() {}
    }

    private func caret(_ value: String, selected: Int, element pid: pid_t) -> CaretContext.Snapshot {
        CaretContext.Snapshot(value: value, location: 0, selectionLength: .readable(selected),
            precedingChar: .startOfField, isUnknown: false,
            focusedElement: AXUIElementCreateApplication(pid))
    }

    /// Real pipeline + injector; AX reads and OS event emission replaced.
    /// `retargetTo` mirrors AudioRecorder's release re-anchor (new snapshot +
    /// PID, edit intent dropped); `frontmostPID` is the app frontmost at insert.
    @MainActor
    private func deliver(
        holdStart: CaretContext.Snapshot, holdStartPID: pid_t,
        retargetTo release: (snapshot: CaretContext.Snapshot, pid: pid_t)?,
        frontmostPID: pid_t,
        text: String = "Hello there.",
        expectedOutcome: TranscriptionPipeline.InjectPipelineResult
    ) -> (typed: String, clipboard: String?, transformCalls: Int) {
        TextInjector.resetDedupeStateForTesting()
        defer { TextInjector.resetDedupeStateForTesting() }
        let board = NSPasteboard(name: .init("murmur.release-retarget.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        let pipeline = TranscriptionPipeline()
        pipeline.smartLeadingSpaceEnabled = false
        let token = pipeline.test_holdVoiceEditSnapshot(holdStart, frontmostPID: holdStartPID)
        var hold = (snapshot: holdStart, pid: holdStartPID)
        if let release {
            XCTAssertTrue(AudioRecorder.shouldRetargetSessionHoldAtRelease(
                startPID: holdStartPID, releasePID: release.pid))
            pipeline.dropVoiceEditIntent(matching: token)
            hold = release
        }
        var transformCalls = 0
        pipeline.runVoiceEditTransform = { _, _, _ in transformCalls += 1; return "edited" }
        let observer = Observer()
        var typed: [UniChar] = []
        pipeline.deliveryHooks = .init(injector: .init(
            pasteboard: board,
            target: { .init(secureInput: false, pid: frontmostPID, bundleIdentifier: "fixture") },
            createObserver: { observer },
            postUnicode: { text in
                let units = Array(text.utf16)
                typed += units
                observer.observedUTF16Units += units.count
                return units.count
            },
            postPasteChord: { XCTFail("Confirmed dictation must not paste"); return false },
            postCanary: { XCTFail("Confirmed dictation must not probe"); return false },
            waitForConfirmation: { _, _ in observer.observedUTF16Units }
        ), snapshot: { hold.snapshot })
        let done = expectation(description: "delivery completed")
        pipeline.finishTranscription(text: text, hadExplicitTrailingNewline: false,
            engineID: "fixture", audioPath: nil, replaceHistoryEntryID: nil,
            sessionHeldToken: token, sessionHeldSnapshot: hold.snapshot,
            sessionHeldFrontmostPID: hold.pid,
            completion: { XCTAssertEqual($0, expectedOutcome); done.fulfill() })
        wait(for: [done], timeout: 5)
        return (String(decoding: typed, as: UTF16.self), board.string(forType: .string), transformCalls)
    }

    // 2026-10-15 live aborts (Khipu / gear-tracker → Claude): the app changed
    // during the hold, so the text belongs in the release app, not the clipboard.
    @MainActor
    func testAppChangedDuringHoldInjectsIntoReleaseApp() {
        let result = deliver(
            holdStart: caret("", selected: 0, element: 42), holdStartPID: 42,
            retargetTo: (caret("", selected: 0, element: 99), 99),
            frontmostPID: 99, expectedOutcome: .inserted)
        XCTAssertEqual(result.typed, "Hello there.")
        XCTAssertNil(result.clipboard)
    }

    // The post-release guard is unchanged: focus moving after release aborts.
    @MainActor
    func testAppChangedAfterReleaseLeavesTextOnClipboard() {
        let result = deliver(
            holdStart: caret("", selected: 0, element: 42), holdStartPID: 42,
            retargetTo: (caret("", selected: 0, element: 99), 99),
            frontmostPID: 7, expectedOutcome: .failed)
        XCTAssertEqual(result.typed, "")
        XCTAssertEqual(result.clipboard, "Hello there.")
    }

    // 3ab6d7a's protection: an edit captured over app A's selection never
    // reaches app B. The intent is dropped, the model never runs, and B gets
    // the spoken words as dictation, even when B has identical text selected.
    @MainActor
    func testEditIntentDroppedWhenAppChangedDuringHold() {
        let result = deliver(
            holdStart: caret("old words", selected: 9, element: 42), holdStartPID: 42,
            retargetTo: (caret("old words", selected: 9, element: 99), 99),
            frontmostPID: 99, text: "make it shorter", expectedOutcome: .inserted)
        XCTAssertEqual(result.transformCalls, 0)
        XCTAssertTrue(result.typed.lowercased().contains("make it shorter"), result.typed)
        XCTAssertNil(result.clipboard)
    }

    // Same app at press and release: the hold-start edit still applies.
    @MainActor
    func testSameAppHoldKeepsEditIntent() {
        let result = deliver(
            holdStart: caret("old words", selected: 9, element: 42), holdStartPID: 42,
            retargetTo: nil, frontmostPID: 42, text: "make it shorter", expectedOutcome: .inserted)
        XCTAssertEqual(result.transformCalls, 1)
        XCTAssertEqual(result.typed, "edited")
    }

    // Without a retarget, an edit bound to A still refuses B at insert.
    @MainActor
    func testUnretargetedEditNeverInjectsIntoAnotherApp() {
        let result = deliver(
            holdStart: caret("old words", selected: 9, element: 42), holdStartPID: 42,
            retargetTo: nil, frontmostPID: 99, text: "make it shorter", expectedOutcome: .failed)
        XCTAssertEqual(result.typed, "")
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

    // Same app at press and release → the hold-start path, unchanged.
    func testNoRetargetWhenAppUnchanged() {
        XCTAssertFalse(
            AudioRecorder.shouldRetargetSessionHoldAtRelease(startPID: 42, releasePID: 42)
        )
    }

    func testRetargetsWhenAppChangedDuringHold() {
        XCTAssertTrue(
            AudioRecorder.shouldRetargetSessionHoldAtRelease(startPID: 1, releasePID: 2)
        )
    }

    // Unknown start identity is fail-open at insert; anchoring to the known
    // release app adds the post-release guard. Any edit intent is dropped.
    func testRetargetsWhenStartPIDUnknownButReleaseKnown() {
        XCTAssertTrue(
            AudioRecorder.shouldRetargetSessionHoldAtRelease(startPID: nil, releasePID: 7)
        )
    }

    // Codex P2: frontmost must be sampled at release, not when the queued
    // doStop runs. A switch to B in that gap leaves the release target at A.
    @MainActor
    func testReleaseTargetIsSampledBeforeStopHop() {
        let hooks = AudioRecorder.MicCaptureTestHooks(
            schedule: { _, _ in }, now: { Date() })
        let recorder = AudioRecorder(micCaptureTestHooks: hooks)
        hooks.releaseFrontmostPID = 42       // app A at fn release
        recorder.stopRecording()
        hooks.releaseFrontmostPID = 99       // user switches to B before doStop drains
        let generation = recorder.releaseSample?.generation ?? 0
        let pid = AudioRecorder.resolvedReleasePID(
            sample: recorder.releaseSample, generation: generation,
            live: { hooks.releaseFrontmostPID })
        XCTAssertEqual(pid, 42)
        // A sample from another generation is ignored in favor of a live read.
        XCTAssertEqual(AudioRecorder.resolvedReleasePID(
            sample: recorder.releaseSample, generation: generation &+ 1,
            live: { 99 }), 99)
        XCTAssertTrue(AudioRecorder.shouldRetargetSessionHoldAtRelease(startPID: 7, releasePID: pid))
    }

    // With the target anchored at A, B being frontmost at insert trips the
    // existing release→insert clipboard guard.
    @MainActor
    func testLaterAppAfterSampledReleaseTriggersClipboardGuard() {
        let result = deliver(
            holdStart: caret("", selected: 0, element: 7), holdStartPID: 7,
            retargetTo: (caret("", selected: 0, element: 42), 42),
            frontmostPID: 99, expectedOutcome: .failed)
        XCTAssertEqual(result.typed, "")
        XCTAssertEqual(result.clipboard, "Hello there.")
    }

    @MainActor
    func testDropVoiceEditIntentIsTokenScoped() {
        let pipeline = TranscriptionPipeline()
        let older = pipeline.test_holdVoiceEditSnapshot(caret("a b", selected: 3, element: 42), frontmostPID: 42)
        let newer = pipeline.test_holdVoiceEditSnapshot(caret("c d", selected: 3, element: 42), frontmostPID: 42)
        pipeline.dropVoiceEditIntent(matching: older)
        XCTAssertFalse(pipeline.isVoiceEditHold(older))
        XCTAssertTrue(pipeline.isVoiceEditHold(newer))
    }
}
