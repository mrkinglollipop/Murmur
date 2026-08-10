import Foundation

/// Builds the whole-phrase match pattern shared by dictionary variants
/// (`DictionaryStore.correct`) and snippet triggers (`SnippetsStore.expand`).
///
/// `\b` is the obvious spelling and it silently fails for any phrase that
/// starts or ends with a non-word character: `\b` asserts a *transition*
/// between a word and a non-word character, so `\b@work` demands a word
/// character immediately before the `@` and never matches " @work", and
/// `c\+\+\b` demands a word character after the `+` and never matches "c++ ".
///
/// The lookarounds below state the intent directly — not preceded/followed by
/// a word character — which behaves identically to `\b` for a phrase whose
/// first and last characters are word characters (the common case) while also
/// matching punctuation-edged phrases.
enum PhraseBoundaryPattern {

    /// Case-insensitive whole-phrase pattern for `phrase`, regex-escaped.
    static func wholePhrase(for phrase: String) -> String {
        "(?<!\\w)\(NSRegularExpression.escapedPattern(for: phrase))(?!\\w)"
    }

    /// Whether `phrase` starts and ends with a word character, i.e. whether it
    /// can stand in for a bare word token. Phrases that do not (".NET", "c++")
    /// carry their own edge punctuation and must only be matched literally —
    /// swapping one in for a token would duplicate punctuation already present
    /// in the surrounding text.
    static func hasWordCharacterEdges(_ phrase: String) -> Bool {
        guard let first = phrase.first, let last = phrase.last else { return false }
        return isWordCharacter(first) && isWordCharacter(last)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
