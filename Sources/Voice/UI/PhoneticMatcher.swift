import Foundation

enum PhoneticMatcher {

    static func encode(_ input: String) -> (primary: String, secondary: String?) {
        let result = DoubleMetaphoneEncoder().encode(input)
        if result.secondary.isEmpty || result.secondary == result.primary {
            return (result.primary, nil)
        }
        return (result.primary, result.secondary)
    }

    static func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a.lowercased())
        let b = Array(b.lowercased())
        let (m, n) = (a.count, b.count)
        guard m > 0 else { return n }
        guard n > 0 else { return m }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                dp[i][j] = min(
                    dp[i - 1][j] + 1,
                    dp[i][j - 1] + 1,
                    dp[i - 1][j - 1] + cost
                )
            }
        }
        return dp[m][n]
    }

    static func guardAccepts(heard: String, candidate: String, primaryKeyMatch: Bool = false) -> Bool {
        let heardTrimmed = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateTrimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heardTrimmed.isEmpty, !candidateTrimmed.isEmpty else { return false }

        let distance = levenshteinDistance(heardTrimmed, candidateTrimmed)
        if distance <= 2 { return true }

        let maxLen = max(heardTrimmed.count, candidateTrimmed.count)
        guard maxLen > 0 else { return false }
        let similarity = 1.0 - Double(distance) / Double(maxLen)
        // Candidates reach this guard only via a metaphone-key hit, so the
        // lexical check exists to reject coincidental key collisions, not to
        // second-guess phonetic identity. An exact primary-key match is strong
        // evidence on its own — the bar drops to 0.4 so spellings that diverge
        // widely but sound identical ("hyzer" → "Heiser", primary HSR/HSR,
        // similarity 0.5) still correct. Secondary-only overlaps keep 0.6.
        return similarity >= (primaryKeyMatch ? 0.4 : 0.6)
    }
}

// MARK: - Double Metaphone (faithful port of oubiwann/metaphone DoubleMetaphone)

private final class DoubleMetaphoneEncoder {

    private static let vowels: Set<Character> = ["A", "E", "I", "O", "U", "Y"]
    private static let silentStarters = ["GN", "KN", "PN", "WR", "PS"]

    private var buffer: [Character] = []
    private var startIndex = 0
    private var endIndex = 0
    private var position = 0
    private var primary = ""
    private var secondary = ""
    private var isSlavoGermanic = false

    func encode(_ input: String) -> (primary: String, secondary: String) {
        let upper = Self.normalize(input)
        isSlavoGermanic = Self.detectSlavoGermanic(upper)

        let prepad = Array("  ")
        let postpad = Array("      ")
        buffer = prepad + Array(upper) + postpad
        startIndex = prepad.count
        endIndex = startIndex + upper.count - 1
        position = startIndex
        primary = ""
        secondary = ""

        checkWordStart()

        while position <= endIndex {
            let character = buffer[position]
            if Self.vowels.contains(character) {
                processInitialVowels()
            } else if character == " " {
                position += 1
                continue
            } else {
                switch character {
                case "B": processB()
                case "C": processC()
                case "D": processD()
                case "F": processF()
                case "G": processG()
                case "H": processH()
                case "J": processJ()
                case "K": processK()
                case "L": processL()
                case "M": processM()
                case "N": processN()
                case "P": processP()
                case "Q": processQ()
                case "R": processR()
                case "S": processS()
                case "T": processT()
                case "V": processV()
                case "W": processW()
                case "X": processX()
                case "Z": processZ()
                default:
                    position += 1
                }
            }
        }

        return (primary, secondary)
    }

    private static func normalize(_ input: String) -> String {
        let decomposed = input.decomposedStringWithCanonicalMapping
        let stripped = decomposed.unicodeScalars.filter {
            CharacterSet.nonBaseCharacters.contains($0) == false
        }
        return String(String.UnicodeScalarView(stripped)).uppercased()
    }

    private static func detectSlavoGermanic(_ upper: String) -> Bool {
        upper.contains("W") || upper.contains("K") || upper.contains("CZ") || upper.contains("WITZ")
    }

    private func letters(from offset: Int, length: Int) -> String {
        let start = startIndex + offset
        let end = start + length
        guard start >= 0, start < buffer.count else { return "" }
        let clampedEnd = min(end, buffer.count)
        guard clampedEnd > start else { return "" }
        return String(buffer[start..<clampedEnd])
    }

    private func letters(at offset: Int, count: Int = 1) -> String {
        letters(from: offset, length: count)
    }

    private func bufferSlice(_ start: Int, _ end: Int) -> String {
        guard start < buffer.count else { return "" }
        let clampedEnd = min(end, buffer.count)
        guard clampedEnd > start else { return "" }
        return String(buffer[start..<clampedEnd])
    }

    private func char(at index: Int) -> Character? {
        guard index >= 0, index < buffer.count else { return nil }
        return buffer[index]
    }

    private func emitBoth(_ code: String, by count: Int) {
        primary.append(code)
        secondary.append(code)
        position += count
    }

    private func emitCodes(primary primaryCode: String?, secondary secondaryCode: String?, by count: Int) {
        if let primaryCode, !primaryCode.isEmpty { primary.append(primaryCode) }
        if let secondaryCode, !secondaryCode.isEmpty { secondary.append(secondaryCode) }
        position += count
    }

    private func secondaryOnly(_ text: String) {
        secondary.append(text)
    }

    private func checkWordStart() {
        if Self.silentStarters.contains(letters(at: 0, count: 2)) {
            position += 1
        }
        if letters(at: 0, count: 1) == "X" {
            primary.append("S")
            secondary.append("S")
            position += 1
        }
    }

    private func processInitialVowels() {
        if position == startIndex {
            emitBoth( "A", by: 1)
        } else {
            position += 1
        }
    }

    private func processB() {
        if char(at: position + 1) == "B" {
            emitBoth( "P", by: 2)
        } else {
            emitBoth( "P", by: 1)
        }
    }

    private func processC() {
        if position > startIndex + 1,
           let prev2 = char(at: position - 2), !Self.vowels.contains(prev2),
           bufferSlice(position - 1, position + 3) == "ACH",
           char(at: position + 2) != "I",
           char(at: position + 2) != "E" || bufferSlice(position - 2, position + 4) == "BACHER" || bufferSlice(position - 2, position + 4) == "MACHER" {
            emitBoth( "K", by: 2)
        } else if position == startIndex, bufferSlice(startIndex, startIndex + 6) == "CAESAR" {
            emitBoth( "S", by: 2)
        } else if bufferSlice(position, position + 4) == "CHIA" {
            emitBoth( "K", by: 2)
        } else if bufferSlice(position, position + 2) == "CH" {
            if position > startIndex, bufferSlice(position, position + 4) == "CHAE" {
                emitCodes(primary: "K", secondary: "X", by: 2)
            } else if position == startIndex,
                      ["HARAC", "HARIS"].contains(bufferSlice(position + 1, position + 6))
                        || ["HOR", "HYM", "HIA", "HEM"].contains(bufferSlice(position + 1, position + 4)),
                      bufferSlice(startIndex, startIndex + 5) != "CHORE" {
                emitBoth( "K", by: 2)
            } else if ["VAN ", "VON "].contains(bufferSlice(startIndex, startIndex + 4))
                        || bufferSlice(startIndex, startIndex + 3) == "SCH"
                        || ["ORCHES", "ARCHIT", "ORCHID"].contains(bufferSlice(position - 2, position + 4))
                        || ["T", "S"].contains(String(char(at: position + 2) ?? " "))
                        || ((["A", "O", "U", "E"].contains(String(char(at: position - 1) ?? " ")) || position == startIndex)
                            && ["L", "R", "N", "M", "B", "H", "F", "V", "W", " "].contains(String(char(at: position + 2) ?? " "))) {
                emitBoth( "K", by: 2)
            } else {
                if position > startIndex {
                    if bufferSlice(startIndex, startIndex + 2) == "MC" {
                        emitBoth( "K", by: 2)
                    } else {
                        emitCodes(primary: "X", secondary: "K", by: 2)
                    }
                } else {
                    emitBoth( "X", by: 2)
                }
            }
        } else if bufferSlice(position, position + 2) == "CZ", bufferSlice(position - 2, position + 2) != "WICZ" {
            emitCodes(primary: "S", secondary: "X", by: 2)
        } else if bufferSlice(position + 1, position + 4) == "CIA" {
            emitBoth( "X", by: 3)
        } else if bufferSlice(position, position + 2) == "CC", !(position == startIndex + 1 && char(at: startIndex) == "M") {
            if ["I", "E", "H"].contains(String(char(at: position + 2) ?? " ")), bufferSlice(position + 2, position + 4) != "HU" {
                if (position == startIndex + 1 && char(at: startIndex) == "A")
                    || ["UCCEE", "UCCES"].contains(bufferSlice(position - 1, position + 4)) {
                    emitBoth( "KS", by: 3)
                } else {
                    emitBoth( "X", by: 3)
                }
            } else {
                emitBoth( "K", by: 2)
            }
        } else if ["CK", "CG", "CQ"].contains(bufferSlice(position, position + 2)) {
            emitBoth( "K", by: 2)
        } else if ["CI", "CE", "CY"].contains(bufferSlice(position, position + 2)) {
            if ["CIO", "CIE", "CIA"].contains(bufferSlice(position, position + 3)) {
                emitCodes(primary: "S", secondary: "X", by: 2)
            } else {
                emitBoth( "S", by: 2)
            }
        } else {
            if [" C", " Q", " G"].contains(bufferSlice(position + 1, position + 3)) {
                emitBoth( "K", by: 3)
            } else if ["C", "K", "Q"].contains(String(char(at: position + 1) ?? " ")),
                      !["CE", "CI"].contains(bufferSlice(position + 1, position + 3)) {
                emitBoth( "K", by: 2)
            } else {
                emitBoth( "K", by: 1)
            }
        }
    }

    private func processD() {
        if bufferSlice(position, position + 2) == "DG" {
            if ["I", "E", "Y"].contains(String(char(at: position + 2) ?? " ")) {
                emitBoth( "J", by: 3)
            } else {
                emitBoth( "TK", by: 2)
            }
        } else if ["DT", "DD"].contains(bufferSlice(position, position + 2)) {
            emitBoth( "T", by: 2)
        } else {
            emitBoth( "T", by: 1)
        }
    }

    private func processF() {
        if char(at: position + 1) == "F" {
            emitBoth( "F", by: 2)
        } else {
            emitBoth( "F", by: 1)
        }
    }

    private func processG() {
        if char(at: position + 1) == "H" {
            if position > startIndex, let prev = char(at: position - 1), !Self.vowels.contains(prev) {
                emitBoth( "K", by: 2)
            } else if position == startIndex {
                // Canonical double metaphone: the word-start branch is exactly
                // position == 0. Wrapping it in `< start + 3` with the equality
                // check inside (a port artifact) left mid-word GH-after-vowel
                // ("night") advancing nothing — an infinite loop.
                if char(at: position + 2) == "I" {
                    emitBoth( "J", by: 2)
                } else {
                    emitBoth( "K", by: 2)
                }
            } else if (position > startIndex + 1 && ["B", "H", "D"].contains(String(char(at: position - 2) ?? " ")))
                        || (position > startIndex + 2 && ["B", "H", "D"].contains(String(char(at: position - 3) ?? " ")))
                        || (position > startIndex + 3 && ["B", "H"].contains(String(char(at: position - 4) ?? " "))) {
                position += 2
            } else if position > startIndex + 2,
                      char(at: position - 1) == "U",
                      ["C", "G", "L", "R", "T"].contains(String(char(at: position - 3) ?? " ")) {
                emitBoth( "F", by: 2)
            } else {
                if position > startIndex, char(at: position - 1) != "I" {
                    emitBoth( "K", by: 2)
                } else {
                    position += 2
                }
            }
        } else if char(at: position + 1) == "N" {
            if position == startIndex + 1,
               let first = char(at: startIndex), Self.vowels.contains(first),
               !isSlavoGermanic {
                emitCodes(primary: "KN", secondary: "N", by: 2)
            } else if bufferSlice(position + 2, position + 4) != "EY",
                      char(at: position + 1) != "Y",
                      !isSlavoGermanic {
                emitCodes(primary: "N", secondary: "KN", by: 2)
            } else {
                emitBoth( "KN", by: 2)
            }
        } else if bufferSlice(position + 1, position + 3) == "LI", !isSlavoGermanic {
            emitCodes(primary: "KL", secondary: "L", by: 2)
        } else if position == startIndex,
                  char(at: position + 1) == "Y"
                    || ["ES", "EP", "EB", "EL", "EY", "IB", "IL", "IN", "IE", "EI", "ER"].contains(bufferSlice(position + 1, position + 3)) {
            emitCodes(primary: "K", secondary: "J", by: 2)
        } else if (bufferSlice(position + 1, position + 3) == "ER" || char(at: position + 1) == "Y"),
                  !["DANGER", "RANGER", "MANGER"].contains(bufferSlice(startIndex, startIndex + 6)),
                  !["E", "I"].contains(String(char(at: position - 1) ?? " ")),
                  !["RGY", "OGY"].contains(bufferSlice(position - 1, position + 2)) {
            emitCodes(primary: "K", secondary: "J", by: 2)
        } else if ["E", "I", "Y"].contains(String(char(at: position + 1) ?? " "))
                    || ["AGGI", "OGGI"].contains(bufferSlice(position - 1, position + 3)) {
            if ["VON ", "VAN "].contains(bufferSlice(startIndex, startIndex + 4))
                || bufferSlice(startIndex, startIndex + 3) == "SCH"
                || bufferSlice(position + 1, position + 3) == "ET" {
                emitBoth( "K", by: 2)
            } else if bufferSlice(position + 1, position + 5) == "IER " {
                emitBoth( "J", by: 2)
            } else {
                emitCodes(primary: "J", secondary: "K", by: 2)
            }
        } else if char(at: position + 1) == "G" {
            emitBoth( "K", by: 2)
        } else {
            emitBoth( "K", by: 1)
        }
    }

    private func processH() {
        if (position == startIndex || (char(at: position - 1).map { Self.vowels.contains($0) } ?? false)),
           let next = char(at: position + 1), Self.vowels.contains(next) {
            emitBoth( "H", by: 2)
        } else {
            position += 1
        }
    }

    private func processJ() {
        if bufferSlice(position, position + 4) == "JOSE" || bufferSlice(startIndex, startIndex + 4) == "SAN " {
            if (position == startIndex && char(at: position + 4) == " ") || bufferSlice(startIndex, startIndex + 4) == "SAN " {
                emitBoth( "H", by: 1)
            } else {
                emitCodes(primary: "J", secondary: "H", by: 1)
            }
        } else if position == startIndex, bufferSlice(position, position + 4) != "JOSE" {
            emitCodes(primary: "J", secondary: "A", by: 1)
        } else {
            if let prev = char(at: position - 1), Self.vowels.contains(prev),
               !isSlavoGermanic,
               ["A", "O"].contains(String(char(at: position + 1) ?? " ")) {
                emitCodes(primary: "J", secondary: "H", by: 1)
            } else if position == endIndex {
                emitCodes(primary: "J", secondary: " ", by: 1)
            } else {
                let next = char(at: position + 1)
                let prev = char(at: position - 1)
                let emitJ = !(["L", "T", "K", "S", "N", "M", "B", "Z"].contains(String(next ?? " "))
                                || ["S", "K", "L"].contains(String(prev ?? " ")))
                let step = char(at: position + 1) == "J" ? 2 : 1
                if emitJ {
                    emitBoth( "J", by: step)
                } else {
                    position += step
                }
            }
        }
    }

    private func processK() {
        if char(at: position + 1) == "K" {
            emitBoth( "K", by: 2)
        } else {
            emitBoth( "K", by: 1)
        }
    }

    private func processL() {
        if char(at: position + 1) == "L" {
            if (position == endIndex - 2 && ["ILLO", "ILLA", "ALLE"].contains(bufferSlice(position - 1, position + 3)))
                || ((["AS", "OS"].contains(bufferSlice(endIndex - 1, endIndex + 1)) || ["A", "O"].contains(String(char(at: endIndex) ?? " ")))
                    && bufferSlice(position - 1, position + 3) == "ALLE") {
                primary.append("L")
                position += 2
            } else {
                emitBoth( "L", by: 2)
            }
        } else {
            emitBoth( "L", by: 1)
        }
    }

    private func processM() {
        if (bufferSlice(position + 1, position + 4) == "UMB"
                && (position + 1 == endIndex || bufferSlice(position + 2, position + 4) == "ER"))
            || char(at: position + 1) == "M" {
            emitBoth( "M", by: 2)
        } else {
            emitBoth( "M", by: 1)
        }
    }

    private func processN() {
        if char(at: position + 1) == "N" {
            emitBoth( "N", by: 2)
        } else {
            emitBoth( "N", by: 1)
        }
    }

    private func processP() {
        if char(at: position + 1) == "H" {
            emitBoth( "F", by: 2)
        } else if ["P", "B"].contains(String(char(at: position + 1) ?? " ")) {
            emitBoth( "P", by: 2)
        } else {
            emitBoth( "P", by: 1)
        }
    }

    private func processQ() {
        if char(at: position + 1) == "Q" {
            emitBoth( "K", by: 2)
        } else {
            emitBoth( "K", by: 1)
        }
    }

    private func processR() {
        if position == endIndex,
           !isSlavoGermanic,
           bufferSlice(position - 2, position) == "IE",
           !["ME", "MA"].contains(bufferSlice(position - 4, position - 2)) {
            secondaryOnly("R")
            let step = char(at: position + 1) == "R" ? 2 : 1
            position += step
        } else {
            primary.append("R")
            secondary.append("R")
            position += char(at: position + 1) == "R" ? 2 : 1
        }
    }

    private func processS() {
        if ["ISL", "YSL"].contains(bufferSlice(position - 1, position + 2)) {
            position += 1
        } else if position == startIndex, bufferSlice(startIndex, startIndex + 5) == "SUGAR" {
            emitCodes(primary: "X", secondary: "S", by: 1)
        } else if bufferSlice(position, position + 2) == "SH" {
            if ["HEIM", "HOEK", "HOLM", "HOLZ"].contains(bufferSlice(position + 1, position + 5)) {
                emitBoth( "S", by: 2)
            } else {
                emitBoth( "X", by: 2)
            }
        } else if ["SIO", "SIA"].contains(bufferSlice(position, position + 3)) || bufferSlice(position, position + 4) == "SIAN" {
            if !isSlavoGermanic {
                emitCodes(primary: "S", secondary: "X", by: 3)
            } else {
                emitBoth( "S", by: 3)
            }
        } else if (position == startIndex && ["M", "N", "L", "W"].contains(String(char(at: position + 1) ?? " ")))
                    || char(at: position + 1) == "Z" {
            let step = char(at: position + 1) == "Z" ? 2 : 1
            emitCodes(primary: "S", secondary: "X", by: step)
        } else if bufferSlice(position, position + 2) == "SC" {
            if char(at: position + 2) == "H" {
                if ["OO", "ER", "EN", "UY", "ED", "EM"].contains(bufferSlice(position + 3, position + 5)) {
                    if ["ER", "EN"].contains(bufferSlice(position + 3, position + 5)) {
                        emitCodes(primary: "X", secondary: "SK", by: 3)
                    } else {
                        emitBoth( "SK", by: 3)
                    }
                } else {
                    if position == startIndex,
                       let c = char(at: startIndex + 3), !Self.vowels.contains(c), c != "W" {
                        emitCodes(primary: "X", secondary: "S", by: 3)
                    } else {
                        emitBoth( "X", by: 3)
                    }
                }
            } else if ["I", "E", "Y"].contains(String(char(at: position + 2) ?? " ")) {
                emitBoth( "S", by: 3)
            } else {
                emitBoth( "SK", by: 3)
            }
        } else if position == endIndex, ["AI", "OI"].contains(bufferSlice(position - 2, position)) {
            secondaryOnly("S")
            position += 1
        } else {
            if ["S", "Z"].contains(String(char(at: position + 1) ?? " ")) {
                emitCodes(primary: "S", secondary: "X", by: 2)
            } else {
                emitBoth( "S", by: 1)
            }
        }
    }

    private func processT() {
        if bufferSlice(position, position + 4) == "TION" {
            emitBoth( "X", by: 3)
        } else if ["TIA", "TCH"].contains(bufferSlice(position, position + 3)) {
            emitBoth( "X", by: 3)
        } else if bufferSlice(position, position + 2) == "TH" || bufferSlice(position, position + 3) == "TTH" {
            if ["OM", "AM"].contains(bufferSlice(position + 2, position + 4))
                || ["VON ", "VAN "].contains(bufferSlice(startIndex, startIndex + 4))
                || bufferSlice(startIndex, startIndex + 3) == "SCH" {
                emitBoth( "T", by: 2)
            } else {
                emitCodes(primary: "0", secondary: "T", by: 2)
            }
        } else if ["T", "D"].contains(String(char(at: position + 1) ?? " ")) {
            emitBoth( "T", by: 2)
        } else {
            emitBoth( "T", by: 1)
        }
    }

    private func processV() {
        if char(at: position + 1) == "V" {
            emitBoth( "F", by: 2)
        } else {
            emitBoth( "F", by: 1)
        }
    }

    private func processW() {
        if bufferSlice(position, position + 2) == "WR" {
            emitBoth( "R", by: 2)
        } else if position == startIndex,
                  (char(at: position + 1).map { Self.vowels.contains($0) } ?? false)
                    || bufferSlice(position, position + 2) == "WH" {
            if char(at: position + 1).map({ Self.vowels.contains($0) }) ?? false {
                emitCodes(primary: "A", secondary: "F", by: 1)
            } else {
                emitBoth( "A", by: 1)
            }
        } else if (position == endIndex && char(at: position - 1).map { Self.vowels.contains($0) } ?? false)
                    || ["EWSKI", "EWSKY", "OWSKI", "OWSKY"].contains(bufferSlice(position - 1, position + 4))
                    || bufferSlice(startIndex, startIndex + 3) == "SCH" {
            emitCodes(primary: nil, secondary: "F", by: 1)
        } else if ["WICZ", "WITZ"].contains(bufferSlice(position, position + 4)) {
            emitCodes(primary: "TS", secondary: "FX", by: 4)
        } else {
            position += 1
        }
    }

    private func processX() {
        if !(position == endIndex
             && (["IAU", "EAU"].contains(bufferSlice(position - 3, position))
                 || ["AU", "OU"].contains(bufferSlice(position - 2, position)))) {
            primary.append("KS")
            secondary.append("KS")
        }
        position += ["C", "X"].contains(String(char(at: position + 1) ?? " ")) ? 2 : 1
    }

    private func processZ() {
        if char(at: position + 1) == "H" {
            primary.append("J")
            secondary.append("J")
            position += 2
        } else if ["ZO", "ZI", "ZA"].contains(bufferSlice(position + 1, position + 3))
                    || (isSlavoGermanic && position > startIndex && char(at: position - 1) != "T") {
            emitCodes(primary: "S", secondary: "TS", by: char(at: position + 1) == "Z" || char(at: position + 1) == "H" ? 2 : 1)
        } else {
            primary.append("S")
            secondary.append("S")
            position += ["Z", "H"].contains(String(char(at: position + 1) ?? " ")) ? 2 : 1
        }
    }
}
