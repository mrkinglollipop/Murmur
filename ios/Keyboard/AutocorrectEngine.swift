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

    static func stripApostrophes(_ word: String) -> String {
        word.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
    }

    /// `ill` → `I'll`, `hes` → `he's`. Unknown words return unchanged.
    static func restoreContraction(_ word: String) -> String {
        let key = stripApostrophes(word).lowercased()
        return contractions[key] ?? word
    }

    /// Offer the apostrophe form while typing `ill` / `hes`.
    static func suggestedContraction(_ span: String) -> String? {
        let restored = restoreContraction(span)
        let same = stripApostrophes(restored).lowercased()
            == stripApostrophes(span).lowercased()
        guard same, restored.lowercased() != span.lowercased() else { return nil }
        return capitalizedIContraction(applyCase(template: span, correction: restored))
    }

    /// English `I` contractions are always capital (`I'll`, not `i'll`).
    static func capitalizedIContraction(_ word: String) -> String {
        let lower = word.lowercased()
        guard lower.hasPrefix("i'") else { return word }
        return "I" + word.dropFirst()
    }

    /// Spacebar replacement. Skip real words (`ill`, `hell`, `its`) unless noted.
    static func forcedContraction(_ span: String) -> String? {
        guard let restored = suggestedContraction(span) else { return nil }
        let stripped = stripApostrophes(span).lowercased()
        if suggestOnly.contains(stripped) { return nil }
        if forceWhenCapitalized.contains(stripped) {
            guard let first = span.first, first.isUppercase else { return nil }
        }
        return restored
    }

    /// Mid-sentence pronoun. `"i "` → `"I"`. Already-capital `I` is left alone.
    static func forcedPronounI(_ span: String) -> String? {
        span == "i" ? "I" : nil
    }

    /// Swipe commit: keep real words (`hell`, `its`); put the contraction in slot 2.
    static func swipePresentation(for word: String) -> (primary: String, extra: String?) {
        let restored = capitalizedIContraction(restoreContraction(word))
        let key = stripApostrophes(word).lowercased()
        if suggestOnly.contains(key), restored.lowercased() != word.lowercased() {
            return (word, restored)
        }
        return (restored, nil)
    }

    /// `hethe` → `he the`, `imgoing` → `I'm going`. Nil when the span is already a word.
    ///
    /// `frequencyOrder` is unigram rank (first occurrence). Pass the frequency
    /// list, not a names-prefixed merge — merged indices push `he`/`the` past
    /// the force threshold.
    static func splitWords(
        _ span: String,
        known: [String],
        frequencyOrder: [String]? = nil
    ) -> String? {
        splitResult(span, known: known, frequencyOrder: frequencyOrder)?.text
    }

    /// Spacebar split when both pieces are common (`hethe` → `he the`).
    static func forcedSplit(
        _ span: String,
        known: [String],
        frequencyOrder: [String]? = nil
    ) -> String? {
        guard let result = splitResult(span, known: known, frequencyOrder: frequencyOrder),
              result.highConfidence else { return nil }
        return result.text
    }

    private struct WordSplit {
        var text: String
        var highConfidence: Bool
    }

    private static func splitResult(
        _ span: String,
        known: [String],
        frequencyOrder: [String]?
    ) -> WordSplit? {
        let lower = span.lowercased()
        guard lower.count >= 4, lower.count <= 22 else { return nil }
        guard lower.allSatisfy(\.isLetter) else { return nil }
        var knownSet = Set<String>()
        knownSet.reserveCapacity(min(known.count, 8_192))
        for word in known {
            knownSet.insert(word.lowercased())
        }
        if knownSet.contains(lower) { return nil }

        var rank: [String: Int] = [:]
        rank.reserveCapacity(min(known.count, 8_192))
        let order = frequencyOrder ?? known
        for (index, word) in order.enumerated() {
            let key = word.lowercased()
            if rank[key] == nil { rank[key] = index }
        }
        for key in knownSet where rank[key] == nil {
            rank[key] = 8_000
        }

        var best: (score: Int, left: String, right: String)?
        for leftLen in 1..<(lower.count - 1) {
            let splitIndex = lower.index(lower.startIndex, offsetBy: leftLen)
            let left = String(lower[..<splitIndex])
            let right = String(lower[splitIndex...])
            if left.count == 1, left != "a", left != "i" { continue }
            guard right.count >= 2 else { continue }
            guard let leftHit = resolveSplitPart(left, rank: rank) else { continue }
            guard let rightHit = resolveSplitPart(right, rank: rank) else { continue }
            let score = leftHit.rank + rightHit.rank
            if best == nil || score < best!.score {
                best = (score, leftHit.display, rightHit.display)
            }
        }
        guard let best else { return nil }
        let text = applyCase(template: span, correction: "\(best.left) \(best.right)")
        return WordSplit(text: text, highConfidence: best.score < 500)
    }

    private static func resolveSplitPart(
        _ part: String,
        rank: [String: Int]
    ) -> (display: String, rank: Int)? {
        if let index = rank[part] {
            return (part, index)
        }
        if suggestOnly.contains(part) { return nil }
        if let restored = contractions[part], restored.lowercased() != part {
            return (capitalizedIContraction(restored), 120)
        }
        return nil
    }

    /// Sentence autocap. Whitespace-only context is not a new sentence.
    static func shouldCapitalizeSentence(beforeInput: String) -> Bool {
        if beforeInput.isEmpty { return true }
        if beforeInput.last == "\n" { return true }
        let trimmed = beforeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        return ".!?".contains(last)
    }

    private static let forceWhenCapitalized: Set<String> = ["ill", "id"]
    /// Real words. Suggest the apostrophe form; never replace on space or swipe.
    private static let suggestOnly: Set<String> = [
        "hell", "well", "wed", "shed", "shell", "its", "were", "lets"
    ]

    static let contractions: [String: String] = [
        "dont": "don't",
        "cant": "can't",
        "wont": "won't",
        "isnt": "isn't",
        "arent": "aren't",
        "wasnt": "wasn't",
        "werent": "weren't",
        "didnt": "didn't",
        "doesnt": "doesn't",
        "havent": "haven't",
        "hasnt": "hasn't",
        "hadnt": "hadn't",
        "wouldnt": "wouldn't",
        "couldnt": "couldn't",
        "shouldnt": "shouldn't",
        "mustnt": "mustn't",
        "thats": "that's",
        "whats": "what's",
        "whos": "who's",
        "hows": "how's",
        "whens": "when's",
        "whys": "why's",
        "theyre": "they're",
        "youre": "you're",
        "youve": "you've",
        "youll": "you'll",
        "youd": "you'd",
        "theyll": "they'll",
        "theyd": "they'd",
        "thatll": "that'll",
        "itll": "it'll",
        "im": "I'm",
        "ive": "I've",
        "id": "I'd",
        "ill": "I'll",
        "lets": "let's",
        "theres": "there's",
        "heres": "here's",
        "wheres": "where's",
        "hes": "he's",
        "shes": "she's",
        "hell": "he'll",
        "shell": "she'll",
        "well": "we'll",
        "weve": "we've",
        "theyve": "they've",
        "hed": "he'd",
        "wed": "we'd",
        "itd": "it'd",
        "thatd": "that'd",
        "whod": "who'd",
        "whatd": "what'd",
        "whered": "where'd",
        "howd": "how'd",
        "thered": "there'd",
        "its": "it's",
        "were": "we're",
        "aint": "ain't",
        "yall": "y'all",
        "wouldve": "would've",
        "couldve": "could've",
        "shouldve": "should've",
        "mustve": "must've",
        "mightve": "might've",
        "oclock": "o'clock",
        "maam": "ma'am"
    ]

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

    /// Basic Latin + Latin-1 letters and apostrophes. Drops CJK/Arabic/etc.
    static func isLatinScriptWord(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            if scalar == "'" || scalar == "’" { return true }
            guard CharacterSet.letters.contains(scalar) else { return false }
            return scalar.value < 0x0250
                || (0x0300...0x036F).contains(scalar.value)
        }
    }

    /// Contacts/shortcuts in the swipe list: English frequency, or a longer name.
    static func allowLexiconInSwipe(_ word: String, frequency: Set<String>) -> Bool {
        guard isLatinScriptWord(word) else { return false }
        let key = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if frequency.contains(key) { return true }
        return key.count >= 4
    }

    /// Persist a keyboard-taught word. Frequency-list English is already known.
    static func shouldTeach(_ raw: String, known: [String]) -> Bool {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard word.count >= 2 else { return false }
        guard isLatinScriptWord(word) else { return false }
        guard !shouldSkip(word) else { return false }
        let key = word.lowercased()
        return !known.contains { $0.lowercased() == key }
    }

    /// User/lexicon/learned words first so names beat the frequency tail.
    static func prioritizedLexicon(priority: [String], frequency: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        func add(_ raw: String) {
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard word.count >= 2 || word.lowercased() == "a" || word.lowercased() == "i" else { return }
            let key = word.lowercased()
            guard key.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return }
            guard seen.insert(key).inserted else { return }
            result.append(key)
        }
        for word in priority { add(word) }
        for word in frequency { add(word) }
        for contraction in contractions.values { add(contraction) }
        return result
    }

    static func preferredCasing(_ words: [String]) -> [String: String] {
        var map: [String: String] = [:]
        for raw in words {
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            let key = word.lowercased()
            if map[key] == nil { map[key] = capitalizedIContraction(word) }
        }
        return map
    }

    static func isPunctuationSuggestion(_ text: String) -> Bool {
        guard text.count == 1, let character = text.first else { return false }
        return ".,?!;:".contains(character)
    }

    static func periodAttachedWord(_ suggestion: String) -> String? {
        guard suggestion.hasSuffix("."), suggestion.count > 1 else { return nil }
        let stem = String(suggestion.dropLast())
        guard stem.contains(where: \.isLetter) else { return nil }
        guard stem.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return nil }
        return stem
    }

    static func idlePunctuation(beforeInput: String) -> [String] {
        let committed = committedSpan(beforeInput: beforeInput)
        guard !committed.word.isEmpty else { return [] }
        return [".", "?", "!"]
    }

    static func prefixMatches(prefix: String, in list: [String], limit: Int) -> [String] {
        let needle = prefix.lowercased()
        guard !needle.isEmpty else { return [] }
        let strippedNeedle = stripApostrophes(needle)
        var result: [String] = []
        for word in list {
            let lowered = word.lowercased()
            guard lowered != needle else { continue }
            let stripped = stripApostrophes(lowered)
            if lowered.hasPrefix(needle) || stripped.hasPrefix(strippedNeedle) {
                result.append(word)
                if result.count == limit { break }
            }
        }
        return result
    }

    /// Insert a space before a swipe word when the caret follows a letter or closer.
    static func needsLeadingSpace(beforeInput: String) -> Bool {
        guard let last = beforeInput.last else { return false }
        if last.isWhitespace || last.isNewline { return false }
        return !"([{\"'“‘".contains(last)
    }

    /// Period, comma, and friends replace the automatic trailing space after a swipe.
    static func shouldEatTrailingSwipeSpace(beforeInserting text: String) -> Bool {
        if text == "\n" { return true }
        guard text.count == 1, let character = text.first else { return false }
        return ".,!?;:)]}…".contains(character)
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
