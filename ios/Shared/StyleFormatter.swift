import Foundation

/// Wispr-style formatting: capitalization, punctuation, spacing.
/// Does not rewrite grammar, word choice, or tone.
enum StyleFormatter {

    /// Short dictations (≤2 sentences) lose a trailing period in Casual.
    static let casualShortSentenceLimit = 2

    static func apply(
        _ text: String,
        profile: StyleProfile,
        preserveTerms: [String] = []
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        switch profile {
        case .formal:
            return ensureTrailingPeriod(sentenceCase(trimmed, preserveTerms: preserveTerms))
        case .casual:
            let capped = sentenceCase(trimmed, preserveTerms: preserveTerms)
            return sentenceCount(capped) <= casualShortSentenceLimit
                ? stripTrailingPeriod(capped)
                : capped
        case .veryCasual:
            return stripTrailingPeriod(lowercasePreserving(trimmed, preserveTerms: preserveTerms))
        }
    }

    static func sentenceCase(_ text: String, preserveTerms: [String]) -> String {
        let restored = restoreTerms(text, preserveTerms: preserveTerms)
        var output = ""
        var capitalizeNext = true
        for character in restored {
            if character.isNewline {
                output.append(character)
                capitalizeNext = true
                continue
            }
            if capitalizeNext, character.isLetter {
                output.append(contentsOf: String(character).uppercased())
                capitalizeNext = false
                continue
            }
            output.append(character)
            if character == "." || character == "!" || character == "?" {
                capitalizeNext = true
            } else if !character.isWhitespace {
                capitalizeNext = false
            }
        }
        return restoreTerms(output, preserveTerms: preserveTerms)
    }

    static func lowercasePreserving(_ text: String, preserveTerms: [String]) -> String {
        restoreTerms(text.lowercased(), preserveTerms: preserveTerms)
    }

    static func stripTrailingPeriod(_ text: String) -> String {
        var result = text
        while result.hasSuffix(".") {
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    static func ensureTrailingPeriod(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return text }
        if last == "." || last == "!" || last == "?" { return trimmed }
        return trimmed + "."
    }

    static func sentenceCount(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let chunks = trimmed.components(separatedBy: CharacterSet(charactersIn: ".!?")).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return max(chunks.count, 1)
    }

    private static func restoreTerms(_ text: String, preserveTerms: [String]) -> String {
        var result = text
        let longestFirst = preserveTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        for term in longestFirst {
            let pattern = PhraseBoundaryPattern.wholePhrase(for: term)
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: nsRange,
                withTemplate: NSRegularExpression.escapedTemplate(for: term)
            )
        }
        return result
    }
}
