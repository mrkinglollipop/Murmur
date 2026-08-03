import Foundation

/// Replaces spoken number words glued to a dot-compound token (`flux.one` → `flux.1`).
enum DotCompoundNumberNormalizer {

    private static let digitByWord: [String: String] = [
        "zero": "0",
        "one": "1",
        "two": "2",
        "three": "3",
        "four": "4",
        "five": "5",
        "six": "6",
        "seven": "7",
        "eight": "8",
        "nine": "9",
    ]

    static func apply(_ text: String) -> String {
        let pattern = #"(\w+)\.(zero|one|two|three|four|five|six|seven|eight|nine)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        var result = text
        let fullRange = NSRange(result.startIndex..<result.endIndex, in: result)
        let matches = regex.matches(in: result, options: [], range: fullRange)
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let stemRange = Range(match.range(at: 1), in: result),
                  let wordRange = Range(match.range(at: 2), in: result),
                  let full = Range(match.range, in: result) else { continue }
            let stem = String(result[stemRange])
            let word = String(result[wordRange]).lowercased()
            guard let digit = digitByWord[word] else { continue }
            result.replaceSubrange(full, with: stem + "." + digit)
        }
        return result
    }
}
