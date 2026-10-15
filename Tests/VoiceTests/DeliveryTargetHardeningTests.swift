import ApplicationServices
import XCTest
@testable import Voice

/// Codex P1s on fix/false-field-abort: release classification must use only
/// definite AX answers sampled at release, and relaxed or unbound delivery
/// must land only in a real, non-password text input.
final class DeliveryTargetHardeningTests: XCTestCase {

    private let element = AXUIElementCreateApplication(456)

    /// Answers each attribute from `answers`; anything unlisted is unsupported.
    private func reader(_ answers: [String: (AXError, CFTypeRef?)]) -> CaretContext.AXReader {
        CaretContext.AXReader(
            setTimeout: { _, _ in .success },
            copyAttribute: { _, attribute, output in
                guard let (error, value) = answers[attribute as String] else { return .attributeUnsupported }
                output.pointee = value
                return error
            }
        )
    }

    private var caretRange: CFTypeRef {
        var range = CFRange(location: 3, length: 0)
        return AXValueCreate(.cfRange, &range)!
    }

    // MARK: - Focus read

    func testFocusReadDistinguishesNoFocusFromFailure() {
        func read(_ error: AXError, _ value: CFTypeRef? = nil) -> CaretContext.FocusRead {
            CaretContext.focusRead(frontmostPID: 123,
                reader: reader([kAXFocusedUIElementAttribute: (error, value)]))
        }
        guard case .noFocus = read(.noValue) else { return XCTFail("noValue is a definite no-focus") }
        for failure in [AXError.cannotComplete, .apiDisabled, .failure, .notImplemented, .invalidUIElement] {
            guard case .unknown = read(failure) else { return XCTFail("\(failure.rawValue) must read as unknown") }
        }
        guard case .unknown = read(.success, "not an element" as CFString) else {
            return XCTFail("a malformed focus value is unknown")
        }
        guard case .unknown = CaretContext.focusRead(frontmostPID: nil, reader: reader([:])) else {
            return XCTFail("no PID is unknown")
        }
        guard case .focused = read(.success, element) else { return XCTFail("an element is focused") }
    }

    // MARK: - Release-time sample

    @MainActor
    func testUnboundClassificationUsesReleaseSampleNotLaterState() {
        let hooks = AudioRecorder.MicCaptureTestHooks(schedule: { _, _ in }, now: { Date() })
        let recorder = AudioRecorder(micCaptureTestHooks: hooks)
        let field = CaretContext.FocusedField(element: element, role: kAXTextAreaRole as String, isEditable: true)
        hooks.releaseFrontmostPID = 42
        hooks.releaseFocus = (.focused(field), true)       // released in A's real field
        recorder.stopRecording()
        hooks.releaseFocus = (.noFocus, false)             // A's last window closes before doStop
        let generation = recorder.releaseFocusSample?.generation ?? 0
        XCTAssertFalse(AudioRecorder.isUnboundAtRelease(sample: recorder.releaseFocusSample, generation: generation))

        hooks.releaseFocus = (.noFocus, true)
        recorder.stopRecording()
        let nextGeneration = recorder.releaseFocusSample?.generation ?? 0
        XCTAssertTrue(AudioRecorder.isUnboundAtRelease(sample: recorder.releaseFocusSample, generation: nextGeneration))
        // Another stop's sample, or none, keeps the take bound.
        XCTAssertFalse(AudioRecorder.isUnboundAtRelease(sample: recorder.releaseFocusSample, generation: nextGeneration &+ 1))
        XCTAssertFalse(AudioRecorder.isUnboundAtRelease(sample: nil, generation: nextGeneration))
    }

    @MainActor
    func testTimedOutReleaseFocusReadKeepsTakeBound() {
        let hooks = AudioRecorder.MicCaptureTestHooks(schedule: { _, _ in }, now: { Date() })
        let recorder = AudioRecorder(micCaptureTestHooks: hooks)
        hooks.releaseFrontmostPID = 42
        hooks.releaseFocus = (.unknown, nil)
        recorder.stopRecording()
        let generation = recorder.releaseFocusSample?.generation ?? 0
        XCTAssertFalse(AudioRecorder.isUnboundAtRelease(sample: recorder.releaseFocusSample, generation: generation))
    }

    // MARK: - Editable text

    func testWritableValueControlsAreNotText() {
        for role in [kAXCheckBoxRole, kAXSliderRole, kAXIncrementorRole, kAXPopUpButtonRole, kAXRadioButtonRole] {
            // Even a control that answers a text-range read never qualifies.
            let r = reader([kAXSelectedTextRangeAttribute: (.success, caretRange)])
            XCTAssertEqual(CaretContext.isEditableText(element, role: role as String, reader: r), false, role as String)
        }
        // A writable-value element with no caret attributes is not text.
        XCTAssertEqual(CaretContext.isEditableText(element, role: "AXGroup", reader: reader([
            kAXValueAttribute: (.success, 1 as NSNumber),
            kAXSelectedTextRangeAttribute: (.noValue, nil),
        ])), false)
    }

    func testTextRolesAndCaretBearingElementsAreText() {
        for role in [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String, "AXSearchField"] {
            XCTAssertEqual(CaretContext.isEditableText(element, role: role, reader: reader([:])), true, role)
        }
        XCTAssertEqual(CaretContext.isEditableText(element, role: "AXGroup",
            reader: reader([kAXSelectedTextRangeAttribute: (.success, caretRange)])), true)
        XCTAssertEqual(CaretContext.isEditableText(element, role: "AXWebArea",
            reader: reader([kAXInsertionPointLineNumberAttribute: (.success, 0 as NSNumber)])), true)
        // A timed-out caret read is unknown, never editable.
        XCTAssertNil(CaretContext.isEditableText(element, role: "AXGroup",
            reader: reader([kAXSelectedTextRangeAttribute: (.cannotComplete, nil)])))
    }

    func testPasswordFieldsAreNeverEditableText() {
        let secure = CaretContext.secureTextFieldRole
        XCTAssertEqual(CaretContext.isEditableText(element, role: kAXTextFieldRole as String,
            reader: reader([kAXSubroleAttribute: (.success, secure as CFString)])), false)
        XCTAssertEqual(CaretContext.isEditableText(element, role: secure, reader: reader([:])), false)
        // An unreadable subrole could hide a password field.
        XCTAssertNil(CaretContext.isEditableText(element, role: kAXTextFieldRole as String,
            reader: reader([kAXSubroleAttribute: (.cannotComplete, nil)])))
        let password = CaretContext.FocusedField(element: element, role: secure, isEditable: true)
        XCTAssertFalse(password.acceptsRelaxedDelivery)
    }

    /// Same app, ordinary field held, a different password field focused at
    /// insert with Secure Input clear: the real AX read rejects it.
    func testRelaxedRuleRejectsPasswordFieldFromRealRead() {
        let held = AXUIElementCreateApplication(501)
        let passwordElement = AXUIElementCreateApplication(502)
        let r = CaretContext.AXReader(
            setTimeout: { _, _ in .success },
            copyAttribute: { _, attribute, output in
                switch attribute as String {
                case kAXFocusedUIElementAttribute: output.pointee = passwordElement
                case kAXRoleAttribute: output.pointee = kAXTextFieldRole as CFString
                case kAXSubroleAttribute: output.pointee = kAXSecureTextFieldSubrole as CFString
                default: return .attributeUnsupported
                }
                return .success
            }
        )
        guard let fresh = CaretContext.focusedField(frontmostPID: 123, reader: r) else { return XCTFail("focused") }
        XCTAssertFalse(VoiceEditRouting.ordinaryDeliveryFieldMatches(
            held: held, heldRole: kAXTextFieldRole as String, fresh: fresh))
    }
}
