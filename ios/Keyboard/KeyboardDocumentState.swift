import UIKit

/// Only swipe words own a deletable committed span. Dictation never does.
enum KeyboardInsertOrigin: Equatable {
    case dictation
    case swipe(String)

    var swipeWord: String? {
        if case .swipe(let word) = self { return word }
        return nil
    }

    func trailingDeleteCount(beforeInserting text: String, context: String) -> Int {
        guard swipeWord != nil,
              AutocorrectEngine.shouldEatTrailingSwipeSpace(beforeInserting: text),
              context.last == " " else { return 0 }
        return 1
    }

    func backspaceCount(context: String) -> Int {
        guard let word = swipeWord else { return context.isEmpty ? 0 : 1 }
        return AutocorrectEngine.allowedDeleteCount(span: word, inBeforeInput: context)
    }
}

struct KeyboardDocumentFingerprint: Equatable {
    let documentIdentifier: UUID

    func allowsInsertion(into current: Self, isCancelled: Bool) -> Bool {
        !isCancelled && self == current
    }
}

struct KeyboardDictationRequest {
    let id: String
    let document: KeyboardDocumentFingerprint

    func accepts(id: String, document: KeyboardDocumentFingerprint) -> Bool {
        self.id == id && self.document == document
    }
}

enum KeyboardAutocorrectionPolicy {
    static func allowsReplacement(
        autocorrectionType: UITextAutocorrectionType?,
        keyboardType: UIKeyboardType?,
        isSecure: Bool
    ) -> Bool {
        guard !isSecure, autocorrectionType != .no else { return false }
        switch keyboardType ?? .default {
        case .URL, .emailAddress, .numberPad, .phonePad, .namePhonePad,
             .decimalPad, .numbersAndPunctuation, .asciiCapableNumberPad:
            return false
        default:
            return true
        }
    }
}
