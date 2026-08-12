import UIKit

/// Loads the bundled frequency list once. Unique, lowercased.
enum FrequencyList {
    static let words: [String] = {
        let url = Bundle.main.url(forResource: "en-US-frequency", withExtension: "txt")
            ?? Bundle(for: AutocorrectController.self).url(forResource: "en-US-frequency", withExtension: "txt")
            ?? Bundle(for: AutocorrectController.self).url(
                forResource: "en-US-frequency",
                withExtension: "txt",
                subdirectory: "Resources"
            )
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let banned: Set<String> = [
            "teh", "adn", "taht", "hte", "recieve", "seperate", "occured",
            "definately", "untill", "wich", "whihc", "thier", "woudl", "jsut", "becuase"
        ]
        var seen = Set<String>()
        var result: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let word = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard word.count >= 2 || word == "a" || word == "i" else { continue }
            guard !banned.contains(word) else { continue }
            guard seen.insert(word).inserted else { continue }
            result.append(word)
        }
        return result
    }()
}

/// UITextChecker + lexicon + frequency list. Secure/dictation gating lives in the VC.
final class AutocorrectController {
    private let checker = UITextChecker()
    private let language = "en_US"
    private var lexiconWords: [String] = []
    private var skipped = Set<String>()
    private(set) var displayed: [String] = []
    private(set) var undoOriginal: String?
    private(set) var lastCorrected: String?
    var suppressUntilWhitespace = false

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
    }

    func suggestions(for span: String) -> [String] {
        guard span.count >= 2, !AutocorrectEngine.shouldSkip(span) else {
            displayed = []
            return []
        }
        let nsWord = span as NSString
        let range = NSRange(location: 0, length: nsWord.length)
        let completions = checker.completions(
            forPartialWordRange: range,
            in: span,
            language: language
        ) ?? []
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
            completions + frequency + lexicon,
            excluding: span,
            limit: 3
        )
        displayed = merged
        return merged
    }

    func correction(for span: String) -> String? {
        guard !suppressUntilWhitespace else { return nil }
        guard span.count >= 2 else { return nil }
        guard !AutocorrectEngine.shouldSkip(span) else { return nil }
        guard !skipped.contains(span.lowercased()) else { return nil }
        let nsWord = span as NSString
        let full = NSRange(location: 0, length: nsWord.length)
        let misspelled = checker.rangeOfMisspelledWord(
            in: span,
            range: full,
            startingAt: 0,
            wrap: false,
            language: language
        )
        guard misspelled.location != NSNotFound else { return nil }
        let guesses = checker.guesses(
            forWordRange: misspelled,
            in: span,
            language: language
        ) ?? []
        guard let first = guesses.first, first.lowercased() != span.lowercased() else { return nil }
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
    }
}
