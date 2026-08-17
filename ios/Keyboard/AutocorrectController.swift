import UIKit

/// Loads the bundled frequency list once. Unique, lowercased.
enum FrequencyList {
    private static let banned: Set<String> = Set(AutocorrectEngine.commonTypos.keys)

    /// Frequency-file order only. Split confidence uses these ranks so a names
    /// prefix on `words` cannot push `he`/`the` past the force threshold.
    static let frequencyOrder: [String] = uniqued(loadList("en-US-frequency"))

    /// Names first, then frequency. Prefix matches and membership; not split rank.
    static let words: [String] = uniqued(loadList("en-US-names") + loadList("en-US-frequency"))

    static let nameSet: Set<String> = Set(loadList("en-US-names"))

    private static func uniqued(_ words: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for word in words {
            guard word.count >= 2 || word == "a" || word == "i" else { continue }
            guard !banned.contains(word) else { continue }
            guard seen.insert(word).inserted else { continue }
            result.append(word)
        }
        return result
    }

    private static func loadList(_ name: String) -> [String] {
        let url = Bundle.main.url(forResource: name, withExtension: "txt")
            ?? Bundle(for: AutocorrectController.self).url(forResource: name, withExtension: "txt")
            ?? Bundle(for: AutocorrectController.self).url(
                forResource: name,
                withExtension: "txt",
                subdirectory: "Resources"
            )
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let word = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return word.isEmpty ? nil : word
        }
    }
}

/// UITextChecker + lexicon + frequency list. Secure/dictation gating lives in the VC.
final class AutocorrectController {
    private let checker = UITextChecker()
    private let language = "en_US"
    private var lexiconWords: [String] = []
    private var userWords: [String] = []
    private var skipped = Set<String>()
    private(set) var displayed: [String] = []
    private(set) var quoted: Set<String> = []
    private(set) var undoOriginal: String?
    private(set) var lastCorrected: String?
    var suppressUntilWhitespace = false

    /// Swipe/dictation set `suppressUntilWhitespace` so the trailing space that
    /// arrives with the insert does not respell that token. A new typed letter
    /// span is a different word — clear suppress so `i` / `dont` / `hethe` can
    /// still force on the following space.
    func noteIncomingText(_ text: String) {
        guard suppressUntilWhitespace else { return }
        if text.contains(where: \.isLetter) {
            suppressUntilWhitespace = false
        }
    }

    func setLexicon(_ lexicon: UILexicon?) {
        lexiconWords = lexicon?.entries.compactMap { entry in
            let text = entry.documentText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } ?? []
    }

    func ignore(_ word: String) {
        skipped.insert(word.lowercased())
    }

    func clearUndo() {
        undoOriginal = nil
        lastCorrected = nil
        quoted = []
    }

    func seedLearnedSpellings() {
        for word in LearnedWordStore.words() {
            UITextChecker.learnWord(word)
        }
    }

    func setUserWords(_ words: [String]) {
        userWords = words
    }

    func suggestions(for span: String, beforeInput: String = "") -> [String] {
        if span.isEmpty {
            displayed = AutocorrectEngine.idlePunctuation(beforeInput: beforeInput)
            quoted = []
            return displayed
        }
        guard span.count >= 2, !AutocorrectEngine.shouldSkip(span) else {
            displayed = []
            quoted = []
            return []
        }
        let nsWord = span as NSString
        let range = NSRange(location: 0, length: nsWord.length)
        let misspelled = checker.rangeOfMisspelledWord(
            in: span,
            range: range,
            startingAt: 0,
            wrap: false,
            language: language
        )
        let unknown = misspelled.location != NSNotFound
            && !skipped.contains(span.lowercased())
            && !LearnedWordStore.contains(span)
            && !UITextChecker.hasLearnedWord(span)
        quoted = unknown ? [span.lowercased()] : []
        var seeds: [String] = []
        if let contraction = AutocorrectEngine.suggestedContraction(span) {
            seeds.append(contraction)
            quoted.remove(contraction.lowercased())
        }
        if let split = AutocorrectEngine.splitWords(
            span,
            known: FrequencyList.words,
            frequencyOrder: FrequencyList.frequencyOrder
        ) {
            seeds.append(split)
            quoted.remove(split.lowercased())
        }
        seeds.append(span)
        let guesses = checker.guesses(
            forWordRange: range,
            in: span,
            language: language
        ) ?? []
        let completions = checker.completions(
            forPartialWordRange: range,
            in: span,
            language: language
        ) ?? []
        let user = AutocorrectEngine.prefixMatches(
            prefix: span.lowercased(),
            in: userWords,
            limit: 8
        )
        let frequency = AutocorrectEngine.prefixMatches(
            prefix: span.lowercased(),
            in: FrequencyList.words,
            limit: 8
        )
        let lexicon = AutocorrectEngine.prefixMatches(
            prefix: span.lowercased(),
            in: lexiconWords.map { $0.lowercased() },
            limit: 8
        )
        let merged = AutocorrectEngine.uniqued(
            seeds + guesses + completions + user + lexicon + frequency,
            excluding: "",
            limit: 3
        )
        displayed = merged
        return merged
    }

    func correction(for span: String) -> String? {
        guard !suppressUntilWhitespace else { return nil }
        guard !AutocorrectEngine.shouldSkip(span) else { return nil }
        guard !skipped.contains(span.lowercased()) else { return nil }
        guard !LearnedWordStore.contains(span) else { return nil }
        guard !UITextChecker.hasLearnedWord(span) else { return nil }
        if let pronoun = AutocorrectEngine.forcedPronounI(span) {
            return pronoun
        }
        if let contraction = AutocorrectEngine.forcedContraction(span) {
            return contraction
        }
        if let typo = AutocorrectEngine.forcedTypo(span) {
            return typo
        }
        guard span.count >= 2 else { return nil }
        let nsWord = span as NSString
        let full = NSRange(location: 0, length: nsWord.length)
        let misspelled = checker.rangeOfMisspelledWord(
            in: span,
            range: full,
            startingAt: 0,
            wrap: false,
            language: language
        )
        // Valid words stay typed. Splits and fuzzy guesses were eating
        // "therapist" / names / anything UITextChecker merely disliked.
        guard misspelled.location != NSNotFound else { return nil }
        if let split = AutocorrectEngine.forcedSplit(
            span,
            known: FrequencyList.words,
            frequencyOrder: FrequencyList.frequencyOrder
        ) {
            return split
        }
        let guesses = checker.guesses(
            forWordRange: misspelled,
            in: span,
            language: language
        ) ?? []
        guard let first = guesses.first else { return nil }
        guard AutocorrectEngine.shouldForceSpelling(
            span: span,
            guess: first,
            frequencyOrder: FrequencyList.frequencyOrder,
            names: FrequencyList.nameSet
        ) else { return nil }
        return AutocorrectEngine.applyCase(template: span, correction: first)
    }

    func noteAutocorrect(original: String, corrected: String) {
        undoOriginal = original
        lastCorrected = corrected
        displayed = AutocorrectEngine.uniqued(
            [corrected, original],
            excluding: "",
            limit: 3
        )
        quoted = [original.lowercased()]
    }

    func noteSwipe(committed: String, alternatives: [String]) {
        undoOriginal = nil
        lastCorrected = committed
        var slots: [String] = []
        for alt in alternatives where alt.lowercased() != committed.lowercased() {
            slots.append(alt)
            break
        }
        let nsWord = committed as NSString
        let guesses = checker.guesses(
            forWordRange: NSRange(location: 0, length: nsWord.length),
            in: committed,
            language: language
        ) ?? []
        if let guess = guesses.first,
           guess.lowercased() != committed.lowercased(),
           !slots.contains(where: { $0.lowercased() == guess.lowercased() }) {
            if slots.isEmpty { slots.append(guess) }
        }
        slots.append("\(committed).")
        slots.append("?")
        displayed = AutocorrectEngine.uniqued(slots, excluding: "", limit: 3)
        quoted = []
    }
}
