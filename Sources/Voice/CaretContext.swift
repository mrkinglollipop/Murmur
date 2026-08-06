import AppKit
import ApplicationServices

enum CaretContext {
    enum PrecedingChar: Equatable {
        case known(Character)
        case startOfField
        case unknown
    }

    /// Selection length from AX `CFRange` — readable vs fail-open unreadable.
    enum SelectionLength: Equatable {
        case readable(Int)
        case unreadable
    }

    /// One AX read used for mid-sentence trailing-punct strip and smart leading space.
    struct Snapshot: Equatable {
        /// Full focused field value, or empty when AX value unreadable.
        let value: String
        /// UTF-16 selection start (`CFRange.location`).
        let location: Int
        let selectionLength: SelectionLength
        /// Grapheme immediately before `location` (selection start).
        let precedingChar: PrecedingChar
        /// True when focused value/range could not be read at all.
        let isUnknown: Bool

        static let unknown = Snapshot(
            value: "",
            location: 0,
            selectionLength: .unreadable,
            precedingChar: .unknown,
            isUnknown: true
        )
    }

    /// Reads the character immediately left of the caret in the frontmost app's
    /// focused UI element via the Accessibility API (AXFocusedUIElement ->
    /// kAXValueAttribute + kAXSelectedTextRangeAttribute). Returns `.unknown`
    /// when the element/value/range can't be read (common for Electron apps,
    /// which frequently refuse AX value queries), `.startOfField` when the
    /// caret sits at offset 0.
    static func precedingCharacter(
        frontmostPID: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier
    ) -> PrecedingChar {
        snapshot(frontmostPID: frontmostPID).precedingChar
    }

    /// Single AX snapshot for strip + leading space (no dual fetch).
    static func snapshot(
        frontmostPID: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier
    ) -> Snapshot {
        guard let pid = frontmostPID else { return .unknown }

        let appElement = AXUIElementCreateApplication(pid)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else {
            return .unknown
        }
        guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return .unknown
        }
        let focused = focusedRef as! AXUIElement

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success, let valueRef, let value = valueRef as? String else {
            return .unknown
        }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success, let rangeRef else {
            return .unknown
        }

        guard let parsed = selectedTextRange(from: rangeRef) else {
            return .unknown
        }

        let utf16Length = value.utf16.count
        guard parsed.location <= utf16Length else { return .unknown }

        var selectionLength = parsed.selectionLength
        if case .readable(let length) = selectionLength {
            if length < 0 {
                selectionLength = .unreadable
            } else if parsed.location + length > utf16Length {
                // Plan: location + length > utf16 → fail-open no strip.
                selectionLength = .unreadable
            }
        }

        let preceding = precedingGrapheme(in: value, beforeUTF16Location: parsed.location)
        return Snapshot(
            value: value,
            location: parsed.location,
            selectionLength: selectionLength,
            precedingChar: preceding,
            isUnknown: false
        )
    }

    /// Parses `kAXSelectedTextRangeAttribute` into a UTF-16 offset, or nil when
    /// the attribute is not an `AXValue` CFRange (testable without AX mocks).
    static func selectedTextOffset(from rangeRef: CFTypeRef) -> Int? {
        selectedTextRange(from: rangeRef)?.location
    }

    /// Location + length from AX `CFRange`. Length may be `.unreadable`.
    static func selectedTextRange(from rangeRef: CFTypeRef) -> (location: Int, selectionLength: SelectionLength)? {
        guard CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        let axValue = rangeRef as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }

        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &cfRange) else { return nil }

        let offset = cfRange.location
        guard offset != kCFNotFound, offset >= 0 else { return nil }

        let rawLength = cfRange.length
        let selectionLength: SelectionLength
        if rawLength == kCFNotFound || rawLength < 0 {
            selectionLength = .unreadable
        } else {
            selectionLength = .readable(rawLength)
        }
        return (offset, selectionLength)
    }

    /// Grapheme immediately before UTF-16 `location` (selection start).
    static func precedingGrapheme(in value: String, beforeUTF16Location location: Int) -> PrecedingChar {
        let utf16Length = value.utf16.count
        guard location <= utf16Length else { return .unknown }
        if location == 0 { return .startOfField }

        let nsString = value as NSString
        let charIndex = location - 1
        guard charIndex >= 0 else { return .startOfField }

        let composedRange = nsString.rangeOfComposedCharacterSequence(at: charIndex)
        let charString = nsString.substring(with: composedRange)
        guard let char = charString.first else { return .unknown }
        return .known(char)
    }

    /// True when non-whitespace remains after selection end (continuing prose).
    static func hasContinuingProse(
        value: String,
        selectionLocation: Int,
        selectionLength: Int
    ) -> Bool {
        let utf16Length = value.utf16.count
        let end = selectionLocation + selectionLength
        guard end >= 0, end <= utf16Length else { return false }

        let nsString = value as NSString
        var index = end
        while index < utf16Length {
            let composed = nsString.rangeOfComposedCharacterSequence(at: index)
            let piece = nsString.substring(with: composed)
            guard let ch = piece.first else { return false }
            if !(ch.isWhitespace || ch.isNewline) {
                return true
            }
            index = composed.location + composed.length
        }
        return false
    }

    /// Pure, testable decision: should a single leading space be prepended to
    /// the transcript before injection?
    static func shouldPrependSpace(precedingChar: PrecedingChar, transcriptFirstChar: Character?) -> Bool {
        switch precedingChar {
        case .known(let char):
            if char.isWhitespace || char.isNewline {
                return false
            }
            if char.isLetter || char.isNumber {
                return true
            }
            let sentenceEnders: Set<Character> = [".", "!", "?", ",", ":", ";"]
            if sentenceEnders.contains(char) {
                return true
            }
            return false
        case .startOfField:
            return false
        case .unknown:
            guard let first = transcriptFirstChar else { return false }
            return first.isLetter || first.isNumber
        }
    }

    // MARK: - Mid-sentence trailing sentence punctuation

    private static let sentencePunct: Set<Character> = [".", "!", "?"]

    /// Transcript-tail rule: after trimming trailing WS, ends with exactly one
    /// of `.` `!` `?` whose previous char is not also sentence punct.
    static func transcriptHasStrippableTrailingSentencePunctuation(_ transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, sentencePunct.contains(last) else { return false }
        let before = trimmed.dropLast()
        guard let prev = before.last else { return false }
        if sentencePunct.contains(prev) { return false }
        if prev.isWhitespace || prev.isNewline { return false }
        return true
    }

    /// Abbreviation / multi-dot / short-title guard — always on (independent of `codeAware`).
    /// - (a) trailing `.` and last token has another `.` before the final one
    ///   (covers multi-dot abbreviations and domain/extension forms such as `example.com.`)
    /// - (b) last token matches `^[A-Za-z]{1,3}\.$` (short titles: `Dr.`, `Mr.`, `vs.`)
    ///
    /// `codeAware` is retained for call-site / API stability. Domain caution that the
    /// mid-sentence punct plan attached to codeAware is already identical to (a), so
    /// the flag does not change this guard’s result.
    static func abbreviationGuardBlocksStrip(transcript: String, codeAware: Bool) -> Bool {
        // Equivalence: codeAware domain caution ⊆ always-on (a); do not branch on the flag.
        _ = codeAware

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(".") else { return false }
        guard let token = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).last.map(String.init) else {
            return false
        }

        // (b) short title
        if token.range(of: #"^[A-Za-z]{1,3}\.$"#, options: .regularExpression) != nil {
            return true
        }

        // (a) multi-dot / internal-dot before final `.` (always on)
        let withoutFinal = String(token.dropLast())
        if withoutFinal.contains(".") {
            return true
        }

        return false
    }

    static func shouldStripTrailingSentencePunctuation(
        snapshot: Snapshot,
        transcript: String,
        codeAware: Bool
    ) -> Bool {
        guard !snapshot.isUnknown else { return false }

        switch snapshot.selectionLength {
        case .unreadable:
            return false
        case .readable(let length):
            guard length > 0 else { return false }
            guard hasContinuingProse(
                value: snapshot.value,
                selectionLocation: snapshot.location,
                selectionLength: length
            ) else {
                return false
            }
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Transcript that is only punctuation → no strip
        if trimmed.allSatisfy({ sentencePunct.contains($0) || $0.isWhitespace }) {
            return false
        }

        guard transcriptHasStrippableTrailingSentencePunctuation(transcript) else {
            return false
        }
        if abbreviationGuardBlocksStrip(transcript: transcript, codeAware: codeAware) {
            return false
        }
        return true
    }

    /// Removes a single trailing `.` `!` or `?` after trimming trailing WS, then
    /// re-trims. Returns `transcript` unchanged when strip is not warranted.
    static func stripTrailingSentencePunctuationIfNeeded(
        snapshot: Snapshot,
        transcript: String,
        codeAware: Bool
    ) -> String {
        guard shouldStripTrailingSentencePunctuation(
            snapshot: snapshot,
            transcript: transcript,
            codeAware: codeAware
        ) else {
            return transcript
        }
        var trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, sentencePunct.contains(last) else { return transcript }
        trimmed.removeLast()
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
