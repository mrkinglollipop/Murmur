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
        // Punctuation and whitespace never delete beside a bulk swipe insert.
        return 0
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

enum KeyboardBulkEditPolicy {
    static func allowsDeletion(
        count: Int, beforeInput: String, selected: String?,
        recentBulkInsert: String?, textAfterBulkInsert: String
    ) -> Bool {
        guard count > 0, !beforeInput.isEmpty,
              selected == nil || selected == "" else { return false }
        guard recentBulkInsert != nil else { return true }
        // A nil/empty selection is not proof that the host has released its
        // provisional bulk region. Only a matching, locally typed suffix is safe.
        // Spaces and punctuation alone do not establish a new typed token.
        return textAfterBulkInsert.contains { !$0.isWhitespace && !$0.isPunctuation }
            && count <= textAfterBulkInsert.count
            && beforeInput.hasSuffix(textAfterBulkInsert)
    }

    static func candidateSpan(
        beforeInput: String, recentBulkInsert: String?, textAfterBulkInsert: String
    ) -> (word: String, trailing: String)? {
        let active = AutocorrectEngine.wordSpan(beforeInput: beforeInput)
        let span = active.isEmpty
            ? AutocorrectEngine.committedSpan(beforeInput: beforeInput)
            : (word: active, trailing: "")
        let wordContext = String(beforeInput.dropLast(span.trailing.count))
        guard !span.word.isEmpty,
              AutocorrectEngine.autocorrectionSpan(beforeInput: wordContext) == span.word,
              allowsDeletion(
                count: span.word.count + span.trailing.count, beforeInput: beforeInput,
                selected: nil, recentBulkInsert: recentBulkInsert,
                textAfterBulkInsert: textAfterBulkInsert
              ) else { return nil }
        return span
    }

    static func punctuationDeleteCount(trailing: String, recentBulkInsert: String?) -> Int {
        0
    }
}
