import Foundation

/// Deterministic spoken→symbol pass for code-aware dictation. Runs on raw ASR
/// output before cleanup so identifiers and symbols survive even when cleanup
/// is off or the LLM misses a token.
enum SpokenPunctuation {

    private struct WordJoiner {
        /// Regex alternation for the spoken connector (case-insensitive).
        let spokenPattern: String
        let separator: String
        /// Minimum length for left/right `\w` segments (avoids eating short English words).
        let minWordLength: Int
        /// Overrides `minWordLength` for the left segment only. The right
        /// side stays stricter because a short right word is usually prose
        /// ("type forward slash at the start"), while a short left token is
        /// usually an acronym or path root ("PP forward slash shipped").
        var minLeadingWordLength: Int? = nil
    }

    /// "foo underscore bar" / "src forward slash lib" → joined identifiers.
    private static let wordJoiners: [WordJoiner] = [
        WordJoiner(spokenPattern: #"underscore|under\s+score"#, separator: "_", minWordLength: 1),
        WordJoiner(spokenPattern: #"dot|period"#, separator: ".", minWordLength: 1),
        WordJoiner(spokenPattern: #"forward\s+slash"#, separator: "/", minWordLength: 3, minLeadingWordLength: 2),
        WordJoiner(spokenPattern: #"back\s+slash"#, separator: "\\", minWordLength: 3, minLeadingWordLength: 2),
        WordJoiner(spokenPattern: "colon", separator: ":", minWordLength: 2),
    ]

    /// Longest phrases first — order is applied via length sort at runtime.
    private static let phraseReplacements: [(String, String)] = [
        // Compound operators
        ("less than or equal to", "<="),
        ("greater than or equal to", ">="),
        ("less than or equal", "<="),
        ("greater than or equal", ">="),
        ("not equal to", "!="),
        ("not equals", "!="),
        ("triple equals", "==="),
        ("equals equals", "=="),
        ("plus equals", "+="),
        ("minus equals", "-="),
        ("star equals", "*="),
        ("fat arrow", "=>"),
        ("thin arrow", "->"),

        // Doubled symbols (also in preJoinerPhrases — listed for discoverability)
        ("double underscore", "__"),
        ("double colon", "::"),

        // Grouping — long forms before short
        ("open parenthesis", "("),
        ("close parenthesis", ")"),
        ("closing parenthesis", ")"),
        ("left parenthesis", "("),
        ("right parenthesis", ")"),
        ("open square bracket", "["),
        ("close square bracket", "]"),
        ("open curly brace", "{"),
        ("close curly brace", "}"),
        ("open curly bracket", "{"),
        ("close curly bracket", "}"),
        ("left bracket", "["),
        ("right bracket", "]"),
        ("left brace", "{"),
        ("right brace", "}"),
        ("left paren", "("),
        ("right paren", ")"),
        ("open paren", "("),
        ("close paren", ")"),
        ("open bracket", "["),
        ("close bracket", "]"),
        ("open brace", "{"),
        ("close brace", "}"),

        // Slashes and quotes
        ("forward slash", "/"),
        ("back slash", "\\"),
        ("backslash", "\\"),
        ("double quote", "\""),
        ("single quote", "'"),
        ("open quote", "\""),
        ("close quote", "\""),

        // Named symbols
        ("equals sign", "="),
        ("equal sign", "="),
        ("plus sign", "+"),
        ("minus sign", "-"),
        ("percent sign", "%"),
        ("dollar sign", "$"),
        ("at sign", "@"),
        ("at symbol", "@"),
        ("hash sign", "#"),
        ("pound sign", "#"),
        ("number sign", "#"),
        ("ampersand sign", "&"),
        ("vertical bar", "|"),
        ("pipe symbol", "|"),
        ("less than sign", "<"),
        ("greater than sign", ">"),
        ("grave accent", "`"),

        // Single-word code tokens (code-aware context)
        ("semicolon", ";"),
        ("colon", ":"),
        ("asterisk", "*"),
        ("ampersand", "&"),
        ("underscore", "_"),
        ("backtick", "`"),
        ("tilde", "~"),
        ("caret", "^"),
        ("comma", ","),
        ("star", "*"),
        ("pipe", "|"),

        // Whitespace
        ("new line", "\n"),
        ("newline", "\n"),
        ("tab key", "\t"),
    ]

    /// Applied before word joiners so `double colon` is not parsed as `word:word`.
    private static let preJoinerPhrases: [(String, String)] = [
        ("double underscore", "__"),
        ("double colon", "::"),
    ]

    /// Code-aware full mapping. `!` / `?` commands use mention guards even here
    /// (`a question mark` stays words; `question mark optional` still maps).
    static func apply(_ text: String) -> String {
        apply(text, codeAware: true)
    }

    /// `codeAware` runs joiners + the symbol table. Prose still converts
    /// sentence-end commands (`exclamation point` → `!`) with mention guards.
    static func apply(_ text: String, codeAware: Bool) -> String {
        var result = text
        if codeAware {
            result = applyPhraseReplacements(result, phrases: preJoinerPhrases)
            result = applyWordJoiners(result)
            // After `conduct dot m` → `conduct.m`, ASR often leaves the rest of a
            // letter-spelled extension spaced: `conduct.m d c` → `conduct.mdc`.
            result = collapseSpacedFileExtensions(result)
            // `conduct Dot Mdc` joins as `conduct.Mdc` — normalize known extensions.
            result = lowercaseKnownFileExtensions(result)
            let postJoiner = phraseReplacements
                .filter { pair in !preJoinerPhrases.contains(where: { $0.0 == pair.0 }) }
                .sorted { $0.0.count > $1.0.count }
            result = applyPhraseReplacements(result, phrases: postJoiner)
        }
        return applyPunctuationCommands(result, allowMidSentence: codeAware)
    }

    /// Longest first so `exclamation point` wins over a future shorter alias.
    private static let sentencePunctuationCommands: [(String, String)] = [
        ("exclamation point", "!"),
        ("exclamation mark", "!"),
        ("question mark", "?"),
    ]

    /// Command vs mention: `I need one of these, exclamation point.` → `!`,
    /// but `a question mark` / `an exclamation point` stay words. Mid-sentence
    /// unguarded maps (`? optional`) only when `allowMidSentence` (code-aware).
    private static func applyPunctuationCommands(_ text: String, allowMidSentence: Bool) -> String {
        var result = text
        let commands = sentencePunctuationCommands.sorted { $0.0.count > $1.0.count }
        for (spoken, symbol) in commands {
            result = replacePunctuationCommand(
                in: result,
                spoken: spoken,
                symbol: symbol,
                allowMidSentence: allowMidSentence
            )
        }
        return result
    }

    private static func replacePunctuationCommand(
        in text: String,
        spoken: String,
        symbol: String,
        allowMidSentence: Bool
    ) -> String {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: spoken))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        var result = text
        while true {
            let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
            let matches = regex.matches(in: result, options: [], range: nsRange)
            var didReplace = false
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let prefix = String(result[..<range.lowerBound])
                let suffix = String(result[range.upperBound...])
                if isPunctuationMention(prefix: prefix) { continue }
                let terminal = isSentenceTerminal(suffix: suffix)
                if !allowMidSentence && !terminal { continue }
                if terminal {
                    result = gluePrefix(prefix) + symbol + droppingCommandPeriod(suffix)
                } else {
                    result.replaceSubrange(range, with: symbol)
                }
                didReplace = true
                break
            }
            if !didReplace { break }
        }
        return result
    }

    /// `a` / `an` / `the` immediately before the phrase means naming the mark.
    private static func isPunctuationMention(prefix: String) -> Bool {
        let pattern = #"\b(a|an|the)\s+\z"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(prefix.startIndex..<prefix.endIndex, in: prefix)
        return regex.firstMatch(in: prefix, options: [], range: range) != nil
    }

    /// End of string, or a period that is the sentence terminator (ASR often
    /// appends `.` after the spoken command).
    private static func isSentenceTerminal(suffix: String) -> Bool {
        let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        guard trimmed.hasPrefix(".") else { return false }
        let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.isEmpty { return true }
        if let first = rest.first, first.isUppercase || first.isNewline { return true }
        return false
    }

    /// Glue `!`/`?` to the preceding word; eat a command comma (`these, !`).
    private static func gluePrefix(_ prefix: String) -> String {
        if let range = prefix.range(of: #",\s*\z"#, options: .regularExpression) {
            return String(prefix[..<range.lowerBound])
        }
        if let range = prefix.range(of: #"[ \t]+\z"#, options: .regularExpression) {
            return String(prefix[..<range.lowerBound])
        }
        return prefix
    }

    /// Drop the period ASR stuck on the command so `!.` does not survive.
    private static func droppingCommandPeriod(_ suffix: String) -> String {
        guard let range = suffix.range(of: #"^\s*\."#, options: .regularExpression) else {
            return suffix
        }
        var result = suffix
        result.removeSubrange(range)
        return result
    }

    /// Known extensions we will glue from letter-spaced ASR (`m d c` → `mdc`).
    /// Keeps outline prose like `section.a b` from becoming `section.ab`.
    private static let spacedFileExtensions: Set<String> = [
        "md", "mdc", "ts", "tsx", "js", "jsx", "mjs", "cjs",
        "py", "go", "rs", "rb", "sh", "zsh", "bash",
        "swift", "json", "yaml", "yml", "toml", "xml", "plist",
        "css", "scss", "html", "htm", "txt", "pdf", "csv", "sql",
        "kt", "kts", "java", "c", "h", "hpp", "cc", "cpp", "mm",
        "dart", "vue", "svelte", "wasm", "proto",
    ]

    /// Collapses letter-spaced file extensions glued to a stem via a real dot.
    /// Requires the first extension letter immediately after `.` so prose like
    /// `Mr. A B C` or `section. A B` is left alone. Resulting extension is
    /// lowercased and must be in `spacedFileExtensions`.
    static func collapseSpacedFileExtensions(_ text: String) -> String {
        // stem.X Y Z… where X/Y/Z are single letters (2–5 letters total).
        let pattern = #"(\w+)\.([A-Za-z](?:\s+[A-Za-z]){1,4})(?!\w)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }

        var result = text
        let fullRange = NSRange(result.startIndex..<result.endIndex, in: result)
        let matches = regex.matches(in: result, options: [], range: fullRange)
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let stemRange = Range(match.range(at: 1), in: result),
                  let lettersRange = Range(match.range(at: 2), in: result),
                  let full = Range(match.range, in: result) else { continue }
            let stem = String(result[stemRange])
            let letters = String(result[lettersRange].filter { $0.isLetter }).lowercased()
            guard letters.count >= 2, spacedFileExtensions.contains(letters) else { continue }
            result.replaceSubrange(full, with: stem + "." + letters)
        }
        return result
    }

    /// Lowercases known file extensions after a real dot (`conduct.Mdc` → `conduct.mdc`).
    static func lowercaseKnownFileExtensions(_ text: String) -> String {
        let alts = spacedFileExtensions.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let pattern = #"(\w+)\.(\#(alts))\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        var result = text
        let fullRange = NSRange(result.startIndex..<result.endIndex, in: result)
        let matches = regex.matches(in: result, options: [], range: fullRange)
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let stemRange = Range(match.range(at: 1), in: result),
                  let extRange = Range(match.range(at: 2), in: result),
                  let full = Range(match.range, in: result) else { continue }
            let stem = String(result[stemRange])
            let ext = String(result[extRange]).lowercased()
            result.replaceSubrange(full, with: stem + "." + ext)
        }
        return result
    }

    private static let compiledWordJoiners: [(NSRegularExpression, String)] = {
        wordJoiners.compactMap { joiner in
            func word(_ minLength: Int) -> String {
                minLength <= 1 ? #"\w+"# : #"\w{\#(minLength),}"#
            }
            let left = word(joiner.minLeadingWordLength ?? joiner.minWordLength)
            let right = word(joiner.minWordLength)
            let pattern = "(\(left))\\s+(?:\(joiner.spokenPattern))\\s+(\(right))"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return nil
            }
            return (regex, joiner.separator)
        }
    }()

    /// Spoken phrase → symbol regexes, keyed by spoken string (tables vary).
    private static let compiledPhrasePatterns: [String: NSRegularExpression] = {
        var cache: [String: NSRegularExpression] = [:]
        let allSpoken = Set(phraseReplacements.map(\.0) + preJoinerPhrases.map(\.0))
        for spoken in allSpoken {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: spoken))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                cache[spoken] = regex
            }
        }
        return cache
    }()

    private static func applyWordJoiners(_ text: String) -> String {
        var result = text
        for (regex, separator) in compiledWordJoiners {
            while true {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                let template = "$1" + NSRegularExpression.escapedTemplate(for: separator) + "$2"
                let replaced = regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: range,
                    withTemplate: template
                )
                if replaced == result { break }
                result = replaced
            }
        }
        return result
    }

    private static func applyPhraseReplacements(_ text: String, phrases: [(String, String)]) -> String {
        var result = text
        for (spoken, symbol) in phrases {
            guard let regex = compiledPhrasePatterns[spoken] else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: symbol)
            )
        }
        return result
    }
}
