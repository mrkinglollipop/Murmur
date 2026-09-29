import Foundation

/// Deterministic spoken capitalization pass. Always runs before cleanup so
/// commands like `capital X` / `caps kilo` apply even when cleanup is off.
/// When no command applies, the input is returned unchanged (commas, newlines,
/// spacing preserved). Commas in command phrases are treated as whitespace
/// only while parsing those phrases.
enum SpokenCapitalization {

    private static let commandVerbs: Set<String> = ["capital", "caps", "uppercase"]

    /// ICAO NATO A–Z. Homonyms only count as letters inside a capital frame.
    private static let natoLetters: [String: Character] = [
        "alpha": "A", "bravo": "B", "charlie": "C", "delta": "D",
        "echo": "E", "foxtrot": "F", "golf": "G", "hotel": "H",
        "india": "I", "juliet": "J", "kilo": "K", "lima": "L",
        "mike": "M", "november": "N", "oscar": "O", "papa": "P",
        "quebec": "Q", "romeo": "R", "sierra": "S", "tango": "T",
        "uniform": "U", "victor": "V", "whiskey": "W", "xray": "X",
        "yankee": "Y", "zulu": "Z",
    ]

    private struct Token {
        var text: String
        /// Where the token sits in the original string, so output can be
        /// rebuilt from the source and keep its punctuation and newlines.
        let range: Range<String.Index>
        /// True when this token was used as a capitalization target (kept in output).
        var usedAsTarget: Bool = false
        /// True when this token is part of a consumed `capital X` command (dropped).
        var isCommand: Bool = false
    }

    /// Word-start targets ("capital J" → John) must be at most this many
    /// non-command tokens before the verb; farther is a coincidence, not intent.
    private static let wordTargetWindow = 3
    /// A lone spoken letter ("x ... capital x") is unambiguous, so it may sit
    /// farther back than a word-start match.
    private static let letterTargetWindow = 6
    /// Shorter words ("in", "is") are too likely to be stray matches for the
    /// pronoun "I" or other common letters.
    private static let minWordTargetLength = 3

    static func apply(_ text: String) -> String {
        var tokens = tokenize(text)
        guard !tokens.isEmpty else { return text }

        // Collect command spans (verbIndex, letterIndex) left-to-right, apply RTL.
        var commands: [(verb: Int, letter: Int)] = []
        var i = 0
        while i + 1 < tokens.count {
            if isCommandVerb(tokens[i].text),
               letterFromCommandWord(tokens[i + 1].text) != nil {
                commands.append((verb: i, letter: i + 1))
                i += 2
            } else {
                i += 1
            }
        }

        // Command phrases never count as targets or toward the target window.
        var commandPhraseIndices = Set<Int>()
        for cmd in commands {
            commandPhraseIndices.insert(cmd.verb)
            commandPhraseIndices.insert(cmd.letter)
        }

        var consumed: [(verb: Int, letter: Int)] = []
        for cmd in commands.reversed() {
            guard let targetLetter = letterFromCommandWord(tokens[cmd.letter].text) else {
                continue
            }
            guard let targetIndex = findTarget(
                in: tokens,
                before: cmd.verb,
                letter: targetLetter,
                skipping: commandPhraseIndices
            ) else {
                // Fail-soft: leave the command phrase in the text.
                continue
            }

            tokens[targetIndex].text = capitalize(
                tokens[targetIndex].text,
                letter: targetLetter
            )
            tokens[targetIndex].usedAsTarget = true
            tokens[cmd.verb].isCommand = true
            tokens[cmd.letter].isCommand = true
            consumed.append(cmd)
        }

        // Identity when nothing applied: preserve commas, newlines, spacing.
        guard !consumed.isEmpty else {
            return text
        }

        // Rebuild from the original string: only capitalized targets change
        // and consumed command phrases are cut, so everything else (commas,
        // newlines, spacing) survives.
        var edits: [(range: Range<String.Index>, replacement: String)] = []
        for token in tokens where token.usedAsTarget {
            edits.append((token.range, token.text))
        }
        var runs: [(first: Int, last: Int, trailing: String)] = []
        for cmd in consumed.sorted(by: { $0.verb < $1.verb }) {
            // Keep sentence-final / glued punct that ASR stuck on the letter (`S.`).
            let trailing = peelEdgePunctuation(tokens[cmd.letter].text).trailing
            if let previous = runs.last, previous.last + 1 == cmd.verb {
                runs[runs.count - 1] = (previous.first, cmd.letter, previous.trailing + trailing)
            } else {
                runs.append((cmd.verb, cmd.letter, trailing))
            }
        }
        for run in runs {
            var lower = tokens[run.first].range.lowerBound
            while lower > text.startIndex {
                let before = text.index(before: lower)
                let ch = text[before]
                guard ch == "," || (ch.isWhitespace && !ch.isNewline) else { break }
                lower = before
            }
            edits.append((lower..<tokens[run.last].range.upperBound, run.trailing))
        }

        var result = ""
        var cursor = text.startIndex
        for edit in edits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            result += text[cursor..<edit.range.lowerBound]
            result += edit.replacement
            cursor = edit.range.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// Split for command parsing; commas are optional separators ≡ whitespace.
    /// Tokens keep their source ranges so output can be rebuilt from `text`.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var start: String.Index?
        var index = text.startIndex
        func isSeparator(_ ch: Character) -> Bool { ch == "," || ch.isWhitespace }
        while index < text.endIndex {
            if isSeparator(text[index]) {
                if let begin = start {
                    tokens.append(Token(text: String(text[begin..<index]), range: begin..<index))
                    start = nil
                }
            } else if start == nil {
                start = index
            }
            index = text.index(after: index)
        }
        if let begin = start {
            tokens.append(Token(text: String(text[begin...]), range: begin..<text.endIndex))
        }
        return tokens
    }

    private static func isCommandVerb(_ word: String) -> Bool {
        commandVerbs.contains(peelEdgePunctuation(word).core.lowercased())
    }

    /// Letter from a single A–Z token or NATO word; nil if unknown.
    /// ASR often glues sentence punct onto the letter (`S.`, `S,`, `"S"`).
    private static func letterFromCommandWord(_ word: String) -> Character? {
        let core = peelEdgePunctuation(word).core.lowercased()
        if core.count == 1, let ch = core.first, ch.isLetter {
            return Character(ch.uppercased())
        }
        return natoLetters[core]
    }

    /// Strip leading/trailing punctuation/symbols so `S.` / `"xray"` still parse.
    private static func peelEdgePunctuation(_ word: String) -> (core: String, trailing: String) {
        var core = word
        var trailing = ""
        while let last = core.last, Self.isPeelablePunctuation(last) {
            trailing = String(last) + trailing
            core.removeLast()
        }
        while let first = core.first, Self.isPeelablePunctuation(first) {
            core.removeFirst()
        }
        return (core, trailing)
    }

    private static func isPeelablePunctuation(_ ch: Character) -> Bool {
        ch.isPunctuation || ch.isSymbol
    }

    /// Nearest preceding unused match: prefer exact single-letter token, else
    /// word whose first letter matches (case-insensitive). Skip used targets
    /// and other command phrases; both passes are bounded (see the windows).
    private static func findTarget(
        in tokens: [Token],
        before verbIndex: Int,
        letter: Character,
        skipping commandPhraseIndices: Set<Int>
    ) -> Int? {
        let needle = Character(letter.lowercased())

        func search(window: Int, matches: (String) -> Bool) -> Int? {
            var seen = 0
            var index = verbIndex - 1
            while index >= 0, seen < window {
                if !commandPhraseIndices.contains(index) {
                    seen += 1
                    let token = tokens[index]
                    if !token.usedAsTarget, matches(token.text.lowercased()) {
                        return index
                    }
                }
                index -= 1
            }
            return nil
        }

        // Pass 1: exact single-letter token.
        if let hit = search(window: letterTargetWindow, matches: { $0.count == 1 && $0.first == needle }) {
            return hit
        }

        // Pass 2: first letter of a longer word.
        return search(window: wordTargetWindow, matches: {
            $0.count >= minWordTargetLength && $0.first == needle
        })
    }

    /// Single-letter → uppercase letter; longer word → first letter uppercased.
    private static func capitalize(_ text: String, letter: Character) -> String {
        if text.count == 1 {
            return String(letter)
        }
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }
}
