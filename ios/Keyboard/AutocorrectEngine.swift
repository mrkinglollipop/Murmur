import Foundation

/// Pure autocorrect helpers. No UIKit so unit tests can run without the appex.
enum AutocorrectEngine {
    struct Replacement: Equatable {
        var deleteCount: Int
        var insert: String
    }

    /// Letters and apostrophes at the end of `beforeInput`. Empty if the caret
    /// follows whitespace or punctuation.
    static func wordSpan(beforeInput: String) -> String {
        var index = beforeInput.endIndex
        while index > beforeInput.startIndex {
            let previous = beforeInput.index(before: index)
            let character = beforeInput[previous]
            if character.isLetter || character == "'" || character == "’" {
                index = previous
            } else {
                break
            }
        }
        return String(beforeInput[index...])
    }

    /// Space, return, or punctuation commits a word. Apostrophe stays in the span.
    static func isCommitText(_ text: String) -> Bool {
        guard text.count == 1, let character = text.first else { return false }
        if character == "'" || character == "’" { return false }
        return character.isWhitespace || character.isPunctuation || character.isNewline
    }

    static func shouldSkip(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed.contains(where: \.isNumber) { return true }
        if trimmed.count >= 2, trimmed == trimmed.uppercased(), trimmed.allSatisfy(\.isLetter) {
            return true
        }
        let lowered = trimmed.lowercased()
        if lowered.contains("://") || lowered.hasPrefix("www.") { return true }
        if trimmed.contains("."), trimmed.contains(where: \.isLetter) { return true }
        return false
    }

    static func applyCase(template: String, correction: String) -> String {
        if template.count > 1, template == template.uppercased() {
            return correction.uppercased()
        }
        if let first = template.first, first.isUppercase {
            let rest = correction.dropFirst()
            return String(correction.prefix(1)).uppercased() + rest
        }
        return correction
    }

    static func replacement(span: String, correction: String) -> Replacement {
        Replacement(deleteCount: span.count, insert: applyCase(template: span, correction: correction))
    }

    static func uniqued(_ words: [String], excluding: String, limit: Int) -> [String] {
        let skip = excluding.lowercased()
        var seen = Set<String>()
        var result: [String] = []
        for word in words {
            let key = word.lowercased()
            guard key != skip, seen.insert(key).inserted else { continue }
            result.append(word)
            if result.count == limit { break }
        }
        return result
    }

    static func prefixMatches(prefix: String, in list: [String], limit: Int) -> [String] {
        let needle = prefix.lowercased()
        guard !needle.isEmpty else { return [] }
        var result: [String] = []
        for word in list {
            let lowered = word.lowercased()
            if lowered.hasPrefix(needle), lowered != needle {
                result.append(word)
                if result.count == limit { break }
            }
        }
        return result
    }

    /// Word immediately before trailing whitespace. Empty if the caret follows punctuation.
    static func committedSpan(beforeInput: String) -> (word: String, trailing: String) {
        var end = beforeInput.endIndex
        while end > beforeInput.startIndex {
            let previous = beforeInput.index(before: end)
            if beforeInput[previous].isWhitespace {
                end = previous
            } else {
                break
            }
        }
        let trailing = String(beforeInput[end...])
        let word = wordSpan(beforeInput: String(beforeInput[..<end]))
        return (word, trailing)
    }
}
