import Foundation

/// Conservative local removal of spoken hesitation tokens. This deliberately
/// runs only when the existing filler-word preference is on: it is not an AI
/// rewrite and never changes code-aware text or quoted speech.
enum HesitationNormalizer {

    /// `language` is the selected dictation language (ISO code). "um" is a real
    /// word outside English (Portuguese/German article, "eu tenho um carro"),
    /// so it is only a hesitation when the language is English. Nil resolves
    /// the persisted language setting, defaulting to English when unset.
    static func normalize(
        _ text: String,
        codeAware: Bool,
        enabled: Bool,
        language: String? = nil
    ) -> String {
        guard enabled, !codeAware else { return text }

        let hesitations = hesitationTokens(language: language ?? persistedLanguage())
        let tokens = wordTokens(in: text)
        let nonHesitationCount = tokens.filter { token in
            !hesitations.contains(String(text[token]).lowercased())
        }.count
        // A bare "uh", "um okay", and other short utterances may be
        // intentional. Require a real prose run around the hesitation.
        guard nonHesitationCount >= 3 else { return text }

        let quotedRanges = quotedRanges(in: text)
        let candidates = removableCandidates(
            tokens: tokens,
            quotedRanges: quotedRanges,
            hesitations: hesitations,
            in: text
        )
        guard !candidates.isEmpty else { return text }

        let removals = merged(removals: candidates.map { removalRange(for: $0, in: text) })
        var result = ""
        var cursor = text.startIndex
        for removal in removals {
            result.append(contentsOf: text[cursor..<removal.lowerBound])
            cursor = removal.upperBound
        }
        result.append(contentsOf: text[cursor...])

        if let first = removals.first,
           text[..<first.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           text[first.lowerBound].isUppercase {
            result = capitalizeFirstLetter(in: result)
        }
        return result
    }

    private static func removableCandidates(
        tokens: [Range<String.Index>],
        quotedRanges: [Range<String.Index>],
        hesitations: Set<String>,
        in text: String
    ) -> [Range<String.Index>] {
        tokens.enumerated().compactMap { index, token in
            let lower = String(text[token]).lowercased()
            guard hesitations.contains(lower) else { return nil }
            guard !quotedRanges.contains(where: { $0.contains(token.lowerBound) }) else { return nil }
            guard isStandalone(token, in: text) else { return nil }
            guard !isDeliberateLetterSpelling(token, prior: index > 0 ? tokens[index - 1] : nil, in: text) else { return nil }
            return token
        }
    }

    private static func hesitationTokens(language: String) -> Set<String> {
        let iso = language.split(separator: "-").first.map { $0.lowercased() } ?? "en"
        return iso == "en" ? ["uh", "um"] : ["uh"]
    }

    private static func persistedLanguage() -> String {
        let stored = VoiceDefaults.shared.string(forKey: "voice.settings.selectedLanguage")
        return (stored?.isEmpty == false ? stored : nil) ?? "en"
    }

    private static func wordTokens(in text: String) -> [Range<String.Index>] {
        guard let expression = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}']+", options: []) else {
            return []
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, options: [], range: nsRange).compactMap { Range($0.range, in: text) }
    }

    private static func removalRange(for range: Range<String.Index>, in text: String) -> Range<String.Index> {
        var start = range.lowerBound
        var end = range.upperBound

        // At the beginning, consume a following comma and its spacing. In the
        // middle, retaining a preceding comma produces normal prose:
        // "as an, uh, complete" -> "as an, complete".
        if text[..<start].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            while end < text.endIndex, text[end].isWhitespace { end = text.index(after: end) }
            if end < text.endIndex, text[end] == "," {
                end = text.index(after: end)
                while end < text.endIndex, text[end].isWhitespace { end = text.index(after: end) }
            }
            return start..<end
        }

        var after = end
        while after < text.endIndex, text[after].isWhitespace { after = text.index(after: after) }
        if after < text.endIndex, text[after] == "," {
            end = text.index(after: after)
            while end < text.endIndex, text[end].isWhitespace { end = text.index(after: end) }
        } else if end < text.endIndex, text[end].isWhitespace {
            // Consume one trailing separator; the preceding one keeps words
            // apart without rewriting any unrelated punctuation.
            end = text.index(after: end)
        } else if start > text.startIndex {
            let previous = text.index(before: start)
            if text[previous].isWhitespace {
                start = previous
                if start > text.startIndex {
                    let separator = text.index(before: start)
                    if text[separator] == ",", after < text.endIndex,
                       ".!?".contains(text[after]) {
                        start = separator
                    }
                }
            }
        }
        return start..<end
    }

    private static func isStandalone(_ range: Range<String.Index>, in text: String) -> Bool {
        func isIdentifierOrPathCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "_" || character == "-" || character == "/"
        }
        if range.lowerBound > text.startIndex,
           isIdentifierOrPathCharacter(text[text.index(before: range.lowerBound)]) {
            return false
        }
        if range.upperBound < text.endIndex,
           isIdentifierOrPathCharacter(text[range.upperBound]) {
            return false
        }
        return true
    }

    private static func isDeliberateLetterSpelling(
        _ range: Range<String.Index>,
        prior: Range<String.Index>?,
        in text: String
    ) -> Bool {
        guard let prior else { return false }
        switch String(text[prior]).lowercased() {
        case "letter", "letters", "spell", "spelled", "spelling":
            return true
        default:
            return false
        }
    }

    private static func quotedRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var doubleQuoted = false
        var singleQuoted = false
        var doubleQuoteStart: String.Index?
        var singleQuoteStart: String.Index?
        var codeStart: String.Index?
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "`" {
                if let start = codeStart {
                    ranges.append(start..<text.index(after: cursor))
                    codeStart = nil
                } else {
                    codeStart = cursor
                }
            } else if codeStart == nil, character == "\"" || character == "“" || character == "”" {
                if doubleQuoted {
                    if let doubleQuoteStart { ranges.append(doubleQuoteStart..<text.index(after: cursor)) }
                    doubleQuoteStart = nil
                } else {
                    doubleQuoteStart = cursor
                }
                doubleQuoted.toggle()
            } else if character == "'" || character == "‘" || character == "’" {
                let previous = cursor > text.startIndex ? text[text.index(before: cursor)] : nil
                let next = text.index(after: cursor) < text.endIndex ? text[text.index(after: cursor)] : nil
                // Apostrophes in contractions are not quote delimiters.
                if !(previous?.isLetter == true && next?.isLetter == true) {
                    if singleQuoted {
                        if let singleQuoteStart { ranges.append(singleQuoteStart..<text.index(after: cursor)) }
                        singleQuoteStart = nil
                    } else {
                        singleQuoteStart = cursor
                    }
                    singleQuoted.toggle()
                }
            }
            cursor = text.index(after: cursor)
        }
        if let doubleQuoteStart { ranges.append(doubleQuoteStart..<text.endIndex) }
        if let singleQuoteStart { ranges.append(singleQuoteStart..<text.endIndex) }
        if let codeStart { ranges.append(codeStart..<text.endIndex) }
        return ranges
    }

    private static func merged(removals: [Range<String.Index>]) -> [Range<String.Index>] {
        let sorted = removals.sorted { $0.lowerBound < $1.lowerBound }
        var result: [Range<String.Index>] = []
        for removal in sorted {
            guard let prior = result.last else {
                result.append(removal)
                continue
            }
            if removal.lowerBound <= prior.upperBound {
                result[result.count - 1] = prior.lowerBound..<max(prior.upperBound, removal.upperBound)
            } else {
                result.append(removal)
            }
        }
        return result
    }

    private static func capitalizeFirstLetter(in text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        var result = String(first).uppercased()
        result.append(contentsOf: text.dropFirst())
        return result
    }
}
