import Foundation

/// Rewrites spoken numbers as digits in unambiguous contexts only.
///
/// ElevenLabs' batch endpoint (`scribe_v2`) spells numbers out ("September
/// twenty-ninth") while its realtime stream writes digits ("September 29th"),
/// and the batch API has no option to change that. Applied only to that batch
/// output so a streaming fallback reads the same as a streamed result.
///
/// Converted: month + day (with an optional spoken year), "N percent",
/// "N dollars [and N cents]", and standalone multi-word or hyphenated
/// cardinals of 10 or more. Everything else — lone small numbers, ordinals
/// outside dates, idioms, capitalized names — is left untouched.
enum SpokenNumberNormalizer {

    private enum Kind { case zero, unit, teen, tens, hundred, thousand }

    private struct Part {
        let kind: Kind
        let value: Int
        let ordinal: Bool
    }

    private struct Token {
        let range: Range<String.Index>
        let lower: String
        /// Non-nil only when every hyphen-separated piece is a number word.
        let parts: [Part]?
        var isCardinalNumber: Bool { parts?.contains(where: { $0.ordinal }) == false }
    }

    private struct Phrase {
        let value: Int
        let end: Int          // token index just past the phrase
        let ordinal: Bool
        let multiPart: Bool
    }

    private static let words: [String: Part] = {
        var table: [String: Part] = [:]
        func add(_ word: String, _ kind: Kind, _ value: Int, ordinal: Bool = false) {
            table[word] = Part(kind: kind, value: value, ordinal: ordinal)
        }
        add("zero", .zero, 0)
        let units = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        for (i, w) in units.enumerated() { add(w, .unit, i + 1) }
        let teens = ["ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
                     "sixteen", "seventeen", "eighteen", "nineteen"]
        for (i, w) in teens.enumerated() { add(w, .teen, 10 + i) }
        let tens = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        for (i, w) in tens.enumerated() { add(w, .tens, (i + 2) * 10) }
        add("hundred", .hundred, 100)
        add("thousand", .thousand, 1000)

        let unitOrd = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth"]
        for (i, w) in unitOrd.enumerated() { add(w, .unit, i + 1, ordinal: true) }
        let teenOrd = ["tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth",
                       "sixteenth", "seventeenth", "eighteenth", "nineteenth"]
        for (i, w) in teenOrd.enumerated() { add(w, .teen, 10 + i, ordinal: true) }
        let tensOrd = ["twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth",
                       "seventieth", "eightieth", "ninetieth"]
        for (i, w) in tensOrd.enumerated() { add(w, .tens, (i + 2) * 10, ordinal: true) }
        add("hundredth", .hundred, 100, ordinal: true)
        add("thousandth", .thousand, 1000, ordinal: true)
        return table
    }()

    private static let months: Set<String> = [
        "January", "February", "March", "April", "May", "June", "July",
        "August", "September", "October", "November", "December"
    ]
    /// Months that are also common words; a bare cardinal 1–9 after them is not a date.
    private static let ambiguousMonths: Set<String> = ["March", "May"]

    private static let tokenRegex = try? NSRegularExpression(
        pattern: #"[\p{L}\p{N}]+(?:[-'’][\p{L}\p{N}]+)*"#
    )

    static func normalize(_ text: String) -> String {
        guard let regex = tokenRegex, !text.isEmpty else { return text }
        let ns = NSRange(text.startIndex..<text.endIndex, in: text)
        var tokens: [Token] = []
        var sawNumberWord = false
        for match in regex.matches(in: text, range: ns) {
            guard let range = Range(match.range, in: text) else { continue }
            let lower = text[range].lowercased()
            let pieces = lower.split(separator: "-", omittingEmptySubsequences: false)
            let parts = pieces.compactMap { words[String($0)] }
            let numeric = parts.count == pieces.count ? parts : nil
            if numeric != nil { sawNumberWord = true }
            tokens.append(Token(range: range, lower: lower, parts: numeric))
        }
        guard sawNumberWord else { return text }

        var edits: [(Range<String.Index>, String)] = []
        var i = 0
        while i < tokens.count {
            if let (edit, next) = dateEdit(at: i, tokens: tokens, text: text) {
                edits.append(contentsOf: edit)
                i = next
                continue
            }
            if let phrase = parsePhrase(at: i, tokens: tokens, text: text) {
                // A fragment after "point" belongs to a decimal; never convert it alone.
                if i > 0, tokens[i - 1].lower == "point", joinable(tokens[i - 1], tokens[i], text) {
                    i = phrase.end
                    continue
                }
                if let (edit, next) = numberEdit(phrase, from: i, tokens: tokens, text: text) {
                    edits.append(edit)
                    i = next
                } else {
                    i = phrase.end
                }
                continue
            }
            i += 1
        }
        guard !edits.isEmpty else { return text }
        var result = text
        for (range, replacement) in edits.reversed() {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    // MARK: - Rules

    private static func dateEdit(
        at i: Int, tokens: [Token], text: String
    ) -> ([(Range<String.Index>, String)], Int)? {
        let monthToken = tokens[i]
        guard months.contains(String(text[monthToken.range])),
              i + 1 < tokens.count, joinable(tokens[i], tokens[i + 1], text),
              let day = parsePhrase(at: i + 1, tokens: tokens, text: text),
              (1...31).contains(day.value) else { return nil }
        let monthName = String(text[monthToken.range])
        if ambiguousMonths.contains(monthName), !day.ordinal, day.value < 10 { return nil }

        let dayText = day.ordinal ? "\(day.value)\(ordinalSuffix(day.value))" : "\(day.value)"
        var edits = [(tokens[i + 1].range.lowerBound..<tokens[day.end - 1].range.upperBound, dayText)]
        var next = day.end
        if let (yearRange, yearText, yearEnd) = yearAfter(tokenIndex: day.end, tokens: tokens, text: text) {
            edits.append((yearRange, yearText))
            next = yearEnd
        }
        return (edits, next)
    }

    /// A spoken year directly after a date, optionally behind a comma.
    private static func yearAfter(
        tokenIndex e: Int, tokens: [Token], text: String
    ) -> (Range<String.Index>, String, Int)? {
        guard e < tokens.count else { return nil }
        let gap = text[tokens[e - 1].range.upperBound..<tokens[e].range.lowerBound]
        let body = gap.first == "," ? gap.dropFirst() : gap[...]
        guard !body.isEmpty, body.allSatisfy(isInlineSpace) else { return nil }

        guard let first = parsePhrase(at: e, tokens: tokens, text: text), !first.ordinal else { return nil }
        if (1900...2099).contains(first.value) {
            return (tokens[e].range.lowerBound..<tokens[first.end - 1].range.upperBound,
                    "\(first.value)", first.end)
        }
        // "twenty twenty-six", "nineteen eighty four", "twenty oh five"
        guard first.end == e + 1, first.value == 19 || first.value == 20,
              first.end < tokens.count, joinable(tokens[first.end - 1], tokens[first.end], text) else { return nil }
        var tail = first.end
        var low: Int?
        if tokens[tail].lower == "oh" || tokens[tail].lower == "o",
           tail + 1 < tokens.count, joinable(tokens[tail], tokens[tail + 1], text),
           let unit = parsePhrase(at: tail + 1, tokens: tokens, text: text),
           !unit.ordinal, unit.end == tail + 2, (1...9).contains(unit.value) {
            low = unit.value
            tail = unit.end
        } else if let pair = parsePhrase(at: tail, tokens: tokens, text: text),
                  !pair.ordinal, (10...99).contains(pair.value) {
            low = pair.value
            tail = pair.end
        }
        guard let low else { return nil }
        return (tokens[e].range.lowerBound..<tokens[tail - 1].range.upperBound,
                "\(first.value * 100 + low)", tail)
    }

    private static func numberEdit(
        _ phrase: Phrase, from start: Int, tokens: [Token], text: String
    ) -> ((Range<String.Index>, String), Int)? {
        guard !phrase.ordinal else { return nil }
        let lower = tokens[start].range.lowerBound
        let n = tokens.count
        let end = phrase.end

        // Percent, including "point" decimals.
        if end < n, joinable(tokens[end - 1], tokens[end], text) {
            if tokens[end].lower == "percent" {
                return ((lower..<tokens[end].range.upperBound, "\(phrase.value)%"), end + 1)
            }
            if tokens[end].lower == "point" {
                var j = end + 1
                var digits = ""
                while j < n, joinable(tokens[j - 1], tokens[j], text), let d = singleDigit(tokens[j]) {
                    digits += String(d)
                    j += 1
                }
                if !digits.isEmpty, j < n, joinable(tokens[j - 1], tokens[j], text),
                   tokens[j].lower == "percent" {
                    return ((lower..<tokens[j].range.upperBound, "\(phrase.value).\(digits)%"), j + 1)
                }
            }
            // Money.
            if tokens[end].lower == "dollar" || tokens[end].lower == "dollars" {
                let dollarsEnd = end + 1
                if dollarsEnd + 1 < n, tokens[dollarsEnd].lower == "and",
                   joinable(tokens[end], tokens[dollarsEnd], text),
                   joinable(tokens[dollarsEnd], tokens[dollarsEnd + 1], text),
                   let cents = parsePhrase(at: dollarsEnd + 1, tokens: tokens, text: text),
                   !cents.ordinal, (0...99).contains(cents.value),
                   cents.end < n, joinable(tokens[cents.end - 1], tokens[cents.end], text),
                   tokens[cents.end].lower == "cents" || tokens[cents.end].lower == "cent" {
                    let amount = String(format: "$%d.%02d", phrase.value, cents.value)
                    return ((lower..<tokens[cents.end].range.upperBound, amount), cents.end + 1)
                }
                return ((lower..<tokens[end].range.upperBound, "$\(phrase.value)"), dollarsEnd)
            }
        }

        // Standalone: multi-word or hyphenated, 10 or more.
        guard phrase.multiPart, phrase.value >= 10 else { return nil }
        if start > 0, joinable(tokens[start - 1], tokens[start], text), tokens[start - 1].isCardinalNumber { return nil }
        if end < n, joinable(tokens[end - 1], tokens[end], text), tokens[end].isCardinalNumber { return nil }
        if let before = text[..<lower].last, ".@/#_".contains(before) { return nil }
        if isCapitalizedMidSentence(tokens[start], text: text) { return nil }
        // Consecutive capitalized number words ("Twenty One Pilots") are a name, even at sentence start.
        let capitalized = (start..<end).filter {
            tokens[$0].parts != nil && text[tokens[$0].range].first?.isUppercase == true
        }.count
        if capitalized >= 2 { return nil }
        return ((lower..<tokens[end - 1].range.upperBound, "\(phrase.value)"), end)
    }

    // MARK: - Number phrase parser

    /// Longest valid cardinal/ordinal phrase starting at `start`, ending on a token boundary.
    private static func parsePhrase(at start: Int, tokens: [Token], text: String) -> Phrase? {
        var total = 0, group = 0
        var last: Kind?
        var hundredUsed = false, thousandUsed = false
        var partCount = 0
        var best: Phrase?
        var ti = start
        outer: while ti < tokens.count {
            if ti > start, !joinable(tokens[ti - 1], tokens[ti], text) { break }
            let token = tokens[ti]
            if token.lower == "and" {
                guard last == .hundred || last == .thousand, ti + 1 < tokens.count,
                      joinable(token, tokens[ti + 1], text),
                      let nextKind = tokens[ti + 1].parts?.first?.kind,
                      nextKind == .unit || nextKind == .teen || nextKind == .tens else { break }
                ti += 1
                continue
            }
            guard let parts = token.parts else { break }
            var ended = false
            for (pi, part) in parts.enumerated() {
                if part.ordinal && pi != parts.count - 1 { break outer }
                switch part.kind {
                case .zero:
                    guard partCount == 0, parts.count == 1 else { break outer }
                    ended = true
                case .unit:
                    guard last == nil || last == .tens || last == .hundred || last == .thousand else { break outer }
                    group += part.value
                case .teen, .tens:
                    guard last == nil || last == .hundred || last == .thousand else { break outer }
                    group += part.value
                case .hundred:
                    // "twenty-six hundred" is 2600; after a thousand only a lone unit may take "hundred".
                    guard !hundredUsed,
                          (last == .unit && (group < 10 || total == 0))
                            || ((last == .teen || last == .tens) && total == 0) else { break outer }
                    group *= 100
                    hundredUsed = true
                case .thousand:
                    guard last == .unit || last == .teen || last == .tens || last == .hundred,
                          !thousandUsed else { break outer }
                    total += group * 1000
                    group = 0
                    thousandUsed = true
                    hundredUsed = false
                }
                last = part.kind
                partCount += 1
                if part.ordinal { ended = true }
            }
            best = Phrase(value: total + group, end: ti + 1,
                          ordinal: parts.last?.ordinal ?? false, multiPart: partCount > 1)
            if ended { break }
            ti += 1
        }
        return best
    }

    // MARK: - Helpers

    private static func singleDigit(_ token: Token) -> Int? {
        guard let parts = token.parts, parts.count == 1, !parts[0].ordinal,
              parts[0].kind == .zero || parts[0].kind == .unit else { return nil }
        return parts[0].value
    }

    private static func isInlineSpace(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\u{00A0}"
    }

    /// Tokens separated only by blanks (no punctuation, no newline).
    private static func joinable(_ a: Token, _ b: Token, _ text: String) -> Bool {
        let gap = text[a.range.upperBound..<b.range.lowerBound]
        return !gap.isEmpty && gap.allSatisfy(isInlineSpace)
    }

    private static func isCapitalizedMidSentence(_ token: Token, text: String) -> Bool {
        guard text[token.range].first?.isUppercase == true else { return false }
        let before = text[..<token.range.lowerBound].reversed().first { !isInlineSpace($0) }
        guard let before else { return false }
        return !".!?:\n\"“".contains(before)
    }

    private static func ordinalSuffix(_ n: Int) -> String {
        if (11...13).contains(n % 100) { return "th" }
        switch n % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }
}
