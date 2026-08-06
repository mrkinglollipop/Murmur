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
        /// True when this token was used as a capitalization target (kept in output).
        var usedAsTarget: Bool = false
        /// True when this token is part of a consumed `capital X` command (dropped).
        var isCommand: Bool = false
    }

    static func apply(_ text: String) -> String {
        let raw = tokenize(text)
        guard !raw.isEmpty else { return text }

        var tokens = raw.map { Token(text: $0) }
        /// Trailing punct peeled from consumed letter tokens (e.g. `S.` → `.`).
        var salvagedTrailingPunctuation = ""

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

        for cmd in commands.reversed() {
            guard let targetLetter = letterFromCommandWord(tokens[cmd.letter].text) else {
                continue
            }
            guard let targetIndex = findTarget(
                in: tokens,
                before: cmd.verb,
                letter: targetLetter
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
            // Keep sentence-final / glued punct that ASR stuck on the letter (`S.`).
            let peeled = peelEdgePunctuation(tokens[cmd.letter].text)
            salvagedTrailingPunctuation = peeled.trailing + salvagedTrailingPunctuation
        }

        // Identity when nothing applied: preserve commas, newlines, spacing.
        guard tokens.contains(where: \.isCommand) else {
            return text
        }

        var result = tokens.filter { !$0.isCommand }.map(\.text).joined(separator: " ")
        if !salvagedTrailingPunctuation.isEmpty {
            result += salvagedTrailingPunctuation
        }
        return result
    }

    /// Split for command parsing; commas are optional separators ≡ whitespace.
    /// Only used when scanning/applying commands — identity path skips rebuild.
    private static func tokenize(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
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
    /// word whose first letter matches (case-insensitive). Skip used targets.
    private static func findTarget(
        in tokens: [Token],
        before verbIndex: Int,
        letter: Character
    ) -> Int? {
        let needle = Character(letter.lowercased())

        // Pass 1: exact single-letter token.
        var index = verbIndex - 1
        while index >= 0 {
            let token = tokens[index]
            if !token.usedAsTarget && !token.isCommand {
                let lower = token.text.lowercased()
                if lower.count == 1, lower.first == needle {
                    return index
                }
            }
            index -= 1
        }

        // Pass 2: first letter of a longer word.
        index = verbIndex - 1
        while index >= 0 {
            let token = tokens[index]
            if !token.usedAsTarget && !token.isCommand {
                let lower = token.text.lowercased()
                if lower.count >= 1, lower.first == needle {
                    return index
                }
            }
            index -= 1
        }

        return nil
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
