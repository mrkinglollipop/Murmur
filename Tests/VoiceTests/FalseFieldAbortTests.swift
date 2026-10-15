import ApplicationServices
import XCTest
@testable import Voice

/// 2026-10-15 Claude desktop (Electron): dictations landed on the clipboard
/// with no app switch because Chromium recreated the composer's AX element
/// between release and insert, failing the `CFEqual` field identity check.
/// Ordinary dictation now accepts an editable element of the held role in the
/// same app; voice edit keeps its exact-selection rule.
final class FalseFieldAbortTests: XCTestCase {

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

    private let textArea = kAXTextAreaRole as String

    /// Synthetic AX objects stand for fields; distinct PIDs = distinct elements.
    private func field(
        _ value: String, location: Int = 0, selected: Int = 0, element: pid_t,
        role: String?, editable: Bool?
    ) -> CaretContext.Snapshot {
        CaretContext.Snapshot(value: value, location: location, selectionLength: .readable(selected),
            precedingChar: location == 0 ? .startOfField : .known("x"), isUnknown: false,
            focusedElement: AXUIElementCreateApplication(element),
            focusedRole: role, focusedIsEditable: editable)
    }

    /// Real pipeline + injector; AX reads and OS event emission replaced.
    @MainActor
    private func deliver(
        held: CaretContext.Snapshot, fresh: CaretContext.Snapshot,
        frontmostPID: pid_t = 42, voiceEdit: Bool = false,
        text: String = "Hello there.",
        expectedOutcome: TranscriptionPipeline.InjectPipelineResult
    ) -> (typed: String, clipboard: String?) {
        TextInjector.resetDedupeStateForTesting()
        defer { TextInjector.resetDedupeStateForTesting() }
        let board = NSPasteboard(name: .init("murmur.false-field-abort.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        let pipeline = TranscriptionPipeline()
        pipeline.smartLeadingSpaceEnabled = false
        let token = pipeline.test_holdVoiceEditSnapshot(held, frontmostPID: 42)
        XCTAssertEqual(pipeline.isVoiceEditHold(token), voiceEdit)
        pipeline.runVoiceEditTransform = { _, _, _ in "edited" }
        let observer = Observer()
        var typed: [UniChar] = []
        pipeline.deliveryHooks = .init(injector: .init(
            pasteboard: board,
            target: { .init(secureInput: false, pid: frontmostPID, bundleIdentifier: "com.anthropic.claudefordesktop") },
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
        ), snapshot: { fresh })
        let done = expectation(description: "delivery completed")
        pipeline.finishTranscription(text: text, hadExplicitTrailingNewline: false,
            engineID: "fixture", audioPath: nil, replaceHistoryEntryID: nil,
            sessionHeldToken: token, sessionHeldSnapshot: held, sessionHeldFrontmostPID: 42,
            completion: { XCTAssertEqual($0, expectedOutcome); done.fulfill() })
        wait(for: [done], timeout: 5)
        return (String(decoding: typed, as: UTF16.self), board.string(forType: .string))
    }

    @MainActor
    func testSameAppRecreatedElementDelivers() {
        let result = deliver(
            held: field("", element: 501, role: textArea, editable: true),
            fresh: field("", element: 502, role: textArea, editable: true),
            expectedOutcome: .inserted)
        XCTAssertEqual(result.typed, "Hello there.")
        XCTAssertNil(result.clipboard)
    }

    // Electron placeholder/state churn and a caret the user moved inside the
    // field: delivery types at the current caret, as a keyboard would.
    @MainActor
    func testSameAppChangedValueAndCaretDelivers() {
        let result = deliver(
            held: field("", element: 501, role: textArea, editable: true),
            fresh: field("Reply to Claude", location: 5, element: 503, role: textArea, editable: true),
            expectedOutcome: .inserted)
        XCTAssertEqual(result.typed, "Hello there.")
        XCTAssertNil(result.clipboard)
    }

    @MainActor
    func testFocusMovedToNonEditableElementLeavesClipboard() {
        for (role, editable) in [(textArea, false), (kAXButtonRole as String, false), ("AXWebArea", nil as Bool?)] {
            let result = deliver(
                held: field("", element: 501, role: textArea, editable: true),
                fresh: field("", element: 504, role: role, editable: editable),
                expectedOutcome: .failed)
            XCTAssertEqual(result.typed, "", role)
            XCTAssertEqual(result.clipboard, "Hello there.", role)
        }
    }

    @MainActor
    func testDifferentRoleEditableElementLeavesClipboard() {
        let result = deliver(
            held: field("", element: 501, role: textArea, editable: true),
            fresh: field("", element: 505, role: kAXTextFieldRole as String, editable: true),
            expectedOutcome: .failed)
        XCTAssertEqual(result.typed, "")
        XCTAssertEqual(result.clipboard, "Hello there.")
    }

    @MainActor
    func testDifferentAppLeavesClipboard() {
        let result = deliver(
            held: field("", element: 501, role: textArea, editable: true),
            fresh: field("", element: 502, role: textArea, editable: true),
            frontmostPID: 99, expectedOutcome: .failed)
        XCTAssertEqual(result.typed, "")
        XCTAssertEqual(result.clipboard, "Hello there.")
    }

    // An unread held role cannot prove "same kind of field": strict identity.
    @MainActor
    func testUnknownHeldRoleKeepsStrictIdentity() {
        let result = deliver(
            held: field("", element: 501, role: nil, editable: nil),
            fresh: field("", element: 502, role: textArea, editable: true),
            expectedOutcome: .failed)
        XCTAssertEqual(result.typed, "")
    }

    @MainActor
    func testVoiceEditWithChangedSelectionStillAborts() {
        let held = field("old words", selected: 9, element: 501, role: textArea, editable: true)
        // Same element, different selection.
        let moved = CaretContext.Snapshot(value: "old words", location: 4, selectionLength: .readable(5),
            precedingChar: .known(" "), isUnknown: false, focusedElement: held.focusedElement,
            focusedRole: textArea, focusedIsEditable: true)
        let sameElement = deliver(held: held, fresh: moved, voiceEdit: true,
            text: "make it shorter", expectedOutcome: .failed)
        XCTAssertEqual(sameElement.typed, "")
        // Recreated element with an identical selection: still not the same selection.
        let recreated = deliver(held: held,
            fresh: field("old words", selected: 9, element: 502, role: textArea, editable: true),
            voiceEdit: true, text: "make it shorter", expectedOutcome: .failed)
        XCTAssertEqual(recreated.typed, "")
    }

    func testOrdinaryFieldRuleIsPure() {
        let held = AXUIElementCreateApplication(501)
        func fresh(_ pid: pid_t, _ role: String?, _ editable: Bool?) -> CaretContext.FocusedField {
            .init(element: AXUIElementCreateApplication(pid), role: role, isEditable: editable)
        }
        XCTAssertTrue(VoiceEditRouting.ordinaryDeliveryFieldMatches(held: held, heldRole: nil, fresh: fresh(501, nil, nil)))
        XCTAssertTrue(VoiceEditRouting.ordinaryDeliveryFieldMatches(held: held, heldRole: textArea, fresh: fresh(502, textArea, true)))
        XCTAssertFalse(VoiceEditRouting.ordinaryDeliveryFieldMatches(held: held, heldRole: textArea, fresh: fresh(502, textArea, nil)))
        XCTAssertFalse(VoiceEditRouting.ordinaryDeliveryFieldMatches(held: held, heldRole: textArea, fresh: fresh(502, "AXGroup", true)))
        XCTAssertFalse(VoiceEditRouting.ordinaryDeliveryFieldMatches(held: held, heldRole: nil, fresh: fresh(502, textArea, true)))
    }

    func testDiagnosticCarriesCountsAndRolesButNoText() {
        let held = field("secret words", location: 12, element: 501, role: textArea, editable: true)
        let fresh = field("other secret", location: 3, selected: 2, element: 502, role: "AXButton", editable: false)
        let line = VoiceEditRouting.deliveryCheckDiagnostic(check: "dictation field", held: held, fresh: fresh, pid: 42)
        XCTAssertFalse(line.contains("secret"), line)
        XCTAssertTrue(line.contains("identity=differs"), line)
        XCTAssertTrue(line.contains("role=AXTextArea→AXButton"), line)
        XCTAssertTrue(line.contains("freshEditable=no"), line)
        XCTAssertTrue(line.contains("valueLen=12→12"), line)
        XCTAssertTrue(line.contains("selection=12+0→3+2"), line)
        XCTAssertTrue(line.contains("pid=42"), line)
    }
}
