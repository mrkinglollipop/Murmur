import Foundation

/// Removes only known, provider-style non-speech captions. This deliberately
/// does not treat brackets as disposable: they are also ordinary prose and
/// code syntax in dictated text.
enum NonSpeechAnnotations {

    private static let labels: Set<String> = [
        "sniff", "sniffs", "sniffing", "sniffling", "sniffle", "sniffles",
        "cough", "coughs", "coughing",
        "laugh", "laughs", "laughing", "laughter",
        "sigh", "sighs", "sighing",
        "sneeze", "sneezes", "sneezing",
        "clear throat", "clears throat", "clearing throat", "throat clear", "throat clearing",
        "breath", "breathes", "breathing", "heavy breathing", "deep breath",
        "inhale", "inhales", "exhale", "exhales",
        "gasp", "gasps", "gasping",
        "chuckle", "chuckles", "chuckling", "giggle", "giggles", "giggling",
        "applause", "clapping", "music", "background noise", "silence"
    ]

    private static let tagPattern = try! NSRegularExpression(
        pattern: "\\(([^()\\r\\n]*)\\)|\\[([^\\[\\]\\r\\n]*)\\]|\\*([^*\\r\\n]*)\\*"
    )

    /// Strip a recognized round- or square-bracketed audio-event label when
    /// it is a standalone caption. A label abutting an identifier is retained
    /// so code such as `items[coughing]` cannot be damaged.
    static func stripRecognizedTags(_ text: String) -> String {
        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = tagPattern.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return text }

        var output = ""
        var cursor = text.startIndex
        var removedAny = false

        for match in matches {
            guard let range = Range(match.range, in: text),
                  let labelRange = Range(match.range(at: 1), in: text)
                      ?? Range(match.range(at: 2), in: text)
                      ?? Range(match.range(at: 3), in: text),
                  isRecognizedLabel(String(text[labelRange])),
                  hasCaptionBoundaries(in: text, range: range),
                  !isInsideProtectedSpan(in: text, before: range.lowerBound)
            else { continue }

            output.append(contentsOf: text[cursor..<range.lowerBound])
            removedAny = true

            cursor = range.upperBound
            while (output.isEmpty || output.last.map(isHorizontalWhitespace) == true),
                  isHorizontalWhitespace(character(at: cursor, in: text))
            {
                cursor = text.index(after: cursor)
            }

            if isSentencePunctuation(character(at: cursor, in: text)) {
                while output.last.map(isHorizontalWhitespace) == true {
                    output.removeLast()
                }
            }

            if cursor == text.endIndex {
                while output.last.map(isHorizontalWhitespace) == true {
                    output.removeLast()
                }
            }
        }

        output.append(contentsOf: text[cursor...])
        guard removedAny else { return text }
        return output.allSatisfy(\.isWhitespace) ? "" : output
    }

    private static func isRecognizedLabel(_ value: String) -> Bool {
        let punctuation = CharacterSet(charactersIn: " .,!?:;")
        let trimmed = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: punctuation)
        let normalized = trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return labels.contains(normalized)
    }

    private static func hasCaptionBoundaries(in text: String, range: Range<String.Index>) -> Bool {
        let leftSafe: Bool
        if range.lowerBound == text.startIndex {
            leftSafe = true
        } else {
            leftSafe = isCaptionBoundary(text[text.index(before: range.lowerBound)])
        }

        let rightSafe: Bool
        if range.upperBound == text.endIndex {
            rightSafe = true
        } else {
            rightSafe = isCaptionBoundary(text[range.upperBound])
        }
        return leftSafe && rightSafe
    }

    private static func isCaptionBoundary(_ character: Character) -> Bool {
        character.isWhitespace || isSentencePunctuation(character)
    }

    /// A caption-looking fragment inside code or an enclosing aside belongs to
    /// the dictated content. This is intentionally conservative: malformed
    /// unmatched delimiters also protect text instead of risking deletion.
    private static func isInsideProtectedSpan(in text: String, before index: String.Index) -> Bool {
        var parentheses = 0
        var brackets = 0
        var codeDelimiterLength: Int?
        var cursor = text.startIndex

        while cursor < index {
            if text[cursor] == "`" {
                var runLength = 0
                while cursor < index, text[cursor] == "`" {
                    runLength += 1
                    cursor = text.index(after: cursor)
                }
                if let delimiter = codeDelimiterLength {
                    if runLength == delimiter { codeDelimiterLength = nil }
                } else {
                    codeDelimiterLength = runLength
                }
                continue
            }
            guard codeDelimiterLength == nil else {
                cursor = text.index(after: cursor)
                continue
            }
            switch text[cursor] {
            case "(": parentheses += 1
            case ")": parentheses = max(0, parentheses - 1)
            case "[": brackets += 1
            case "]": brackets = max(0, brackets - 1)
            default: break
            }
            cursor = text.index(after: cursor)
        }

        return parentheses > 0 || brackets > 0 || codeDelimiterLength != nil
    }

    private static func isSentencePunctuation(_ character: Character?) -> Bool {
        guard let character else { return false }
        return ".,;:!?".contains(character)
    }

    private static func isHorizontalWhitespace(_ character: Character?) -> Bool {
        character == " " || character == "\t"
    }

    private static func character(at index: String.Index, in text: String) -> Character? {
        index < text.endIndex ? text[index] : nil
    }
}
