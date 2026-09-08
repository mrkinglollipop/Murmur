import Foundation

/// Conservative recovery for ASR output that is otherwise ordinary prose but
/// omitted only its final period. This deliberately does not try to infer
/// interior sentence boundaries or repair grammar.
enum TerminalPunctuation {
    /// Returns `text` unchanged unless it is safe to append one terminal period
    /// at the end of a field (or when Electron-style AX is unavailable).
    static func prepare(
        _ text: String,
        snapshot: CaretContext.Snapshot,
        codeAware: Bool,
        hasExplicitCustomTransform: Bool,
        snippetExpansionOccurred: Bool,
        hadExplicitTrailingNewline: Bool
    ) -> String {
        if codeAware { vlog("terminal punctuation skipped: code-aware"); return text }
        if hasExplicitCustomTransform { vlog("terminal punctuation skipped: custom-transform"); return text }
        if snippetExpansionOccurred { vlog("terminal punctuation skipped: snippet-expansion"); return text }
        // This flag comes from preprocessing a provider-whitespace-normalized
        // transcript, so it represents a spoken formatting command rather
        // than an ASR service's incidental trailing line break.
        guard !hadExplicitTrailingNewline else {
            vlog("terminal punctuation skipped: explicit-spoken-trailing-newline")
            return text
        }
        guard isOrdinaryProse(text) else {
            vlog("terminal punctuation skipped: prose-ineligible")
            return text
        }
        guard insertionEndsFieldOrParagraph(snapshot) else {
            let selection: String
            switch snapshot.selectionLength {
            case .readable(let length): selection = String(length)
            case .unreadable: selection = "unreadable"
            }
            // Positions expose why the context guard fired without logging
            // the focused field's contents or any surrounding user text.
            vlog("terminal punctuation skipped: insertion-context fieldUTF16=\(snapshot.value.utf16.count) location=\(snapshot.location) selection=\(selection) unknown=\(snapshot.isUnknown)")
            return text
        }
        vlog("terminal punctuation added")
        return text + "."
    }

    private static func insertionEndsFieldOrParagraph(_ snapshot: CaretContext.Snapshot) -> Bool {
        // Electron commonly declines AX value/range queries. Its unknown state
        // remains eligible because there is no readable evidence of following text.
        guard !snapshot.isUnknown else { return true }
        guard case .readable(let selectionLength) = snapshot.selectionLength else {
            return false
        }
        let utf16Count = snapshot.value.utf16.count
        guard snapshot.location >= 0, selectionLength >= 0,
              snapshot.location <= utf16Count,
              selectionLength <= utf16Count - snapshot.location else { return false }
        let end = snapshot.location + selectionLength
        let utf16 = snapshot.value.utf16
        let startIndex = utf16.index(utf16.startIndex, offsetBy: snapshot.location)
        let endIndex = utf16.index(utf16.startIndex, offsetBy: end)
        // AX offsets are UTF-16; refuse a range that cuts through a surrogate
        // pair instead of guessing where a replacement would land.
        guard String.Index(startIndex, within: snapshot.value) != nil,
              String.Index(endIndex, within: snapshot.value) != nil else { return false }
        let suffix = (snapshot.value as NSString).substring(from: end)
        // Whitespace after the caret is an end-of-paragraph/end-of-field tail;
        // any visible character means a period would land before existing text.
        return suffix.allSatisfy { $0.isWhitespace || $0.isNewline }
    }

    private static func isOrdinaryProse(_ text: String) -> Bool {
        guard !text.isEmpty,
              text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.contains(where: { $0.isNewline }),
              let first = text.first, first.isUppercase,
              let last = text.last, last.isLetter else { return false }

        // The sentence-case gate intentionally leaves lowercase commands and
        // fragments alone; ASR's normal prose sentences begin uppercase.

        let leading = String(text.drop(while: { $0.isWhitespace }))
        guard !leading.hasPrefix("#"), !leading.hasPrefix("-"), !leading.hasPrefix("*") else {
            return false
        }
        guard leading.range(of: #"^\d+[.)]\s"#, options: .regularExpression) == nil else { return false }

        // Obvious structured/code tokens are not prose, regardless of mode.
        let forbidden = CharacterSet(charactersIn: "`{}_[]=;<>\\()@#%+*|&")
        guard text.rangeOfCharacter(from: forbidden) == nil,
              !text.contains("/"),
              !text.lowercased().contains("://"),
              !text.lowercased().hasPrefix("www.") else { return false }

        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= 4 else { return false }
        // Require words, rather than a run of symbols/identifiers. Apostrophes
        // are allowed for ordinary contractions such as "I'm".
        return words.allSatisfy { word in
            let token = String(word)
            let withoutTerminal = token.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            return token.contains(where: { $0.isLetter }) &&
                !token.contains("_") && !withoutTerminal.contains(".")
        }
    }
}
