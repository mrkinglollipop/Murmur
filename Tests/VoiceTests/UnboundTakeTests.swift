import ApplicationServices
import XCTest
@testable import Voice

/// 2026-10-15: the user closed the browser window holding Claude while still
/// holding fn, released, then clicked into another app's text box. Nothing
/// was editable at release, so the take is unbound and goes to the editable
/// field focused at insert. A take released in an editable field keeps the
/// app-switch-to-clipboard rule.
final class UnboundTakeTests: XCTestCase {

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
    private let releasePID: pid_t = 42
    private let otherAppPID: pid_t = 99

    /// Synthetic AX objects stand for fields; distinct PIDs = distinct elements.
    private func field(
        _ value: String = "", selected: Int = 0, element: pid_t, role: String?, editable: Bool?
    ) -> CaretContext.Snapshot {
        CaretContext.Snapshot(value: value, location: 0, selectionLength: .readable(selected),
            precedingChar: .startOfField, isUnknown: false,
            focusedElement: AXUIElementCreateApplication(element),
            focusedRole: role, focusedIsEditable: editable)
    }

    private struct Delivery {
        let typed: String
        let clipboard: String?
        let failures: [DictationFailure]
    }

    /// Real pipeline + injector; AX reads and OS event emission replaced.
    @MainActor
    private func deliver(
        held: CaretContext.Snapshot, unbound: Bool, atInsert fresh: CaretContext.Snapshot,
        frontmostPID: pid_t, secureInput: Bool = false, expectVoiceEditHold: Bool = false,
        expectedOutcome: TranscriptionPipeline.InjectPipelineResult
    ) -> Delivery {
        TextInjector.resetDedupeStateForTesting()
        defer { TextInjector.resetDedupeStateForTesting() }
        let board = NSPasteboard(name: .init("murmur.unbound-take.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        let pipeline = TranscriptionPipeline()
        pipeline.smartLeadingSpaceEnabled = false
        let token = pipeline.test_holdVoiceEditSnapshot(held, frontmostPID: releasePID)
        XCTAssertEqual(pipeline.isVoiceEditHold(token), expectVoiceEditHold)
        if unbound { pipeline.markHoldUnbound(token) }
        pipeline.runVoiceEditTransform = { _, _, _ in
            XCTFail("An unbound take must never run voice edit"); return "edited"
        }
        var failures: [DictationFailure] = []
        pipeline.onFailure = { failures.append($0) }
        let observer = Observer()
        var typed: [UniChar] = []
        pipeline.deliveryHooks = .init(injector: .init(
            pasteboard: board,
            target: { .init(secureInput: secureInput, pid: frontmostPID, bundleIdentifier: "com.example.other") },
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
        pipeline.finishTranscription(text: "Hello there.", hadExplicitTrailingNewline: false,
            engineID: "fixture", audioPath: nil, replaceHistoryEntryID: nil,
            sessionHeldToken: token, sessionHeldSnapshot: held, sessionHeldFrontmostPID: releasePID,
            completion: { XCTAssertEqual($0, expectedOutcome); done.fulfill() })
        wait(for: [done], timeout: 5)
        let flushed = expectation(description: "main queue drained")
        DispatchQueue.main.async { flushed.fulfill() }
        wait(for: [flushed], timeout: 5)
        XCTAssertTrue(pipeline.test_unboundHoldTokens.isEmpty)
        return Delivery(typed: String(decoding: typed, as: UTF16.self),
            clipboard: board.string(forType: .string), failures: failures)
    }

    @MainActor
    func testUnboundTakeTypesIntoEditableFieldInAnotherApp() {
        let result = deliver(
            held: field(element: 501, role: "AXWebArea", editable: false), unbound: true,
            atInsert: field(element: 601, role: textArea, editable: true),
            frontmostPID: otherAppPID, expectedOutcome: .inserted)
        XCTAssertEqual(result.typed, "Hello there.")
        XCTAssertNil(result.clipboard)
    }

    @MainActor
    func testUnboundTakeWithNothingEditableAtInsertLeavesClipboard() {
        let nothingFocused = CaretContext.Snapshot.unknown
        let button = field(element: 602, role: kAXButtonRole as String, editable: false)
        for fresh in [nothingFocused, button] {
            let result = deliver(
                held: field(element: 501, role: "AXWebArea", editable: false), unbound: true,
                atInsert: fresh, frontmostPID: otherAppPID, expectedOutcome: .failed)
            XCTAssertEqual(result.typed, "")
            XCTAssertEqual(result.clipboard, "Hello there.")
        }
    }

    @MainActor
    func testBoundTakeInDifferentAppAtInsertStillLeavesClipboard() {
        let result = deliver(
            held: field(element: 501, role: textArea, editable: true), unbound: false,
            atInsert: field(element: 601, role: textArea, editable: true),
            frontmostPID: otherAppPID, expectedOutcome: .failed)
        XCTAssertEqual(result.typed, "")
        XCTAssertEqual(result.clipboard, "Hello there.")
    }

    /// Terminals report their text area as non-editable; a bound take whose
    /// same element is still focused at insert must be typed, not clipboarded.
    @MainActor
    func testBoundTakeInNonEditableLookingTerminalFieldIsTyped() {
        let terminal = field(element: 501, role: "AXTextArea", editable: false)
        let result = deliver(
            held: terminal, unbound: false, atInsert: terminal,
            frontmostPID: releasePID, expectedOutcome: .inserted)
        XCTAssertEqual(result.typed, "Hello there.")
        XCTAssertNil(result.clipboard)
    }

    @MainActor
    func testUnboundTakeDropsVoiceEditIntentAndTypesDictation() {
        let result = deliver(
            held: field("old words", selected: 9, element: 501, role: textArea, editable: true), unbound: true,
            atInsert: field(element: 601, role: textArea, editable: true),
            frontmostPID: otherAppPID, expectVoiceEditHold: true, expectedOutcome: .inserted)
        XCTAssertEqual(result.typed, "Hello there.")
        XCTAssertNil(result.clipboard)
    }

    @MainActor
    func testUnboundTakeBlockedBySecureInputAtInsert() {
        let result = deliver(
            held: field(element: 501, role: "AXWebArea", editable: false), unbound: true,
            atInsert: field(element: 601, role: kAXTextFieldRole as String, editable: true),
            frontmostPID: otherAppPID, secureInput: true, expectedOutcome: .failed)
        XCTAssertEqual(result.typed, "")
        XCTAssertNil(result.clipboard)
        XCTAssertEqual(result.failures, [.secureInputBlocked])
    }

    func testReleaseTargetRuleIsPure() {
        func focused(_ role: String?, _ editable: Bool?) -> CaretContext.FocusedField {
            .init(element: AXUIElementCreateApplication(501), role: role, isEditable: editable)
        }
        XCTAssertTrue(VoiceEditRouting.isUnboundReleaseTarget(field: nil, appHasWindows: nil))
        XCTAssertTrue(VoiceEditRouting.isUnboundReleaseTarget(field: nil, appHasWindows: true))
        XCTAssertTrue(VoiceEditRouting.isUnboundReleaseTarget(field: focused(textArea, true), appHasWindows: false))
        XCTAssertTrue(VoiceEditRouting.isUnboundReleaseTarget(field: focused("AXWebArea", false), appHasWindows: false))
        // Terminal-like: focused but reads non-editable — stays bound.
        XCTAssertFalse(VoiceEditRouting.isUnboundReleaseTarget(field: focused("AXWebArea", false), appHasWindows: true))
        XCTAssertFalse(VoiceEditRouting.isUnboundReleaseTarget(field: focused("AXGroup", false), appHasWindows: nil))
        XCTAssertFalse(VoiceEditRouting.isUnboundReleaseTarget(field: focused(textArea, true), appHasWindows: true))
        XCTAssertFalse(VoiceEditRouting.isUnboundReleaseTarget(field: focused(textArea, true), appHasWindows: nil))
        // Unreadable editability keeps the release target.
        XCTAssertFalse(VoiceEditRouting.isUnboundReleaseTarget(field: focused("AXGroup", nil), appHasWindows: true))
    }

    func testFocusDiagnosticCarriesNoText() {
        let line = VoiceEditRouting.focusDiagnostic(
            field: .init(element: AXUIElementCreateApplication(501), role: "AXButton", isEditable: false),
            appHasWindows: false, pid: 42, bundle: "com.example.browser")
        XCTAssertEqual(line, "role=AXButton editable=no windows=no pid=42 bundle=com.example.browser")
        XCTAssertEqual(
            VoiceEditRouting.focusDiagnostic(field: nil, appHasWindows: nil, pid: nil, bundle: "nil"),
            "role=none editable=? windows=? pid=nil bundle=nil")
    }
}
