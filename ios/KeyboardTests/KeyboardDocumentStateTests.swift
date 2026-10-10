import XCTest
import UIKit

final class KeyboardDocumentStateTests: XCTestCase {
    func testDictationBackspaceRequestsOnlyOneCharacter() {
        let transcript = "A whole dictated sentence with several words "
        XCTAssertEqual(KeyboardInsertOrigin.dictation.backspaceCount(context: transcript), 1)
    }

    func testDictationPeriodAndReturnAreInsertOnly() {
        let transcript = "A whole dictated sentence "
        for text in [".", "\n", " "] {
            XCTAssertEqual(
                KeyboardInsertOrigin.dictation.trailingDeleteCount(beforeInserting: text, context: transcript),
                0
            )
        }
    }

    func testSwipeWordBackspaceCountKeepsPunctuationInsertOnly() {
        let origin = KeyboardInsertOrigin.swipe("hello ")
        XCTAssertEqual(origin.backspaceCount(context: "say hello "), 6)
        XCTAssertEqual(origin.trailingDeleteCount(beforeInserting: ".", context: "say hello "), 0)
        XCTAssertEqual(origin.trailingDeleteCount(beforeInserting: "\n", context: "say hello "), 0)
    }

    func testDisabledAutocorrectionNeverReplaces() {
        XCTAssertFalse(KeyboardAutocorrectionPolicy.allowsReplacement(
            autocorrectionType: .no, keyboardType: .default, isSecure: false
        ))
        XCTAssertFalse(KeyboardAutocorrectionPolicy.allowsReplacement(
            autocorrectionType: .yes, keyboardType: .default, isSecure: true
        ))
    }

    func testIdentifierAndNumericFieldsNeverReplace() {
        let types: [UIKeyboardType] = [.URL, .emailAddress, .numberPad, .phonePad,
                                      .namePhonePad, .decimalPad, .numbersAndPunctuation,
                                      .asciiCapableNumberPad]
        for type in types {
            XCTAssertFalse(KeyboardAutocorrectionPolicy.allowsReplacement(
                autocorrectionType: .yes, keyboardType: type, isSecure: false
            ))
        }
        XCTAssertTrue(KeyboardAutocorrectionPolicy.allowsReplacement(
            autocorrectionType: nil, keyboardType: nil, isSecure: false
        ))
    }

    func testHandoffAcceptsOnlyRequestedTakeInOriginalDocument() {
        let document = KeyboardDocumentFingerprint(documentIdentifier: UUID())
        let other = KeyboardDocumentFingerprint(documentIdentifier: UUID())
        let request = KeyboardDictationRequest(id: "keyboard-take", document: document)
        XCTAssertTrue(request.accepts(id: "keyboard-take", document: document))
        XCTAssertFalse(request.accepts(id: "keyboard-take", document: other))
        XCTAssertFalse(request.accepts(id: "action-button-take", document: document))
    }

    func testGIFDocumentFingerprintChangesOnFieldSwitch() {
        let first = KeyboardDocumentFingerprint(documentIdentifier: UUID())
        let second = KeyboardDocumentFingerprint(documentIdentifier: UUID())
        XCTAssertTrue(first.allowsInsertion(into: first, isCancelled: false))
        XCTAssertFalse(first.allowsInsertion(into: second, isCancelled: false))
        XCTAssertFalse(first.allowsInsertion(into: first, isCancelled: true))
    }
}
