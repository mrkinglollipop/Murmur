import Foundation

/// Whole-phrase match shared by dictionary variants and snippet triggers.
/// `\b` silently fails for phrases that start or end with a non-word character.
enum PhraseBoundaryPattern {

    static func wholePhrase(for phrase: String) -> String {
        "(?<!\\w)\(NSRegularExpression.escapedPattern(for: phrase))(?!\\w)"
    }

    static func hasWordCharacterEdges(_ phrase: String) -> Bool {
        guard let first = phrase.first, let last = phrase.last else { return false }
        return isWordCharacter(first) && isWordCharacter(last)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
