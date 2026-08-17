import Foundation

/// Apple-ish Latin long-press set. Lookup is case-insensitive; output matches
/// the input glyph’s case. Unknown letters return `[]`.
enum KeyDiacriticMap {
    private static let lower: [Character: [String]] = [
        "a": ["à", "á", "â", "ä", "æ", "ã", "å", "ā"],
        "e": ["è", "é", "ê", "ë", "ē", "ė", "ę"],
        "i": ["ì", "í", "î", "ï", "ī"],
        "o": ["ò", "ó", "ô", "ö", "õ", "ø", "ō", "œ"],
        "u": ["ù", "ú", "û", "ü", "ū"],
        "n": ["ñ"],
        "c": ["ç"],
        "s": ["ß", "š"],
        "y": ["ÿ"],
        "z": ["ž"]
    ]

    /// Base glyph plus alternates, or empty if this letter has no strip.
    static func alternatives(for glyph: String) -> [String] {
        guard glyph.count == 1, let scalar = glyph.first else { return [] }
        let folded = Character(scalar.lowercased())
        guard let alts = lower[folded] else { return [] }
        let upper = scalar.isUppercase
        let mapped = alts.map { upper ? $0.uppercased() : $0 }
        return [String(scalar)] + mapped
    }
}
