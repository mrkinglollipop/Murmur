import AppKit
import ApplicationServices

enum CaretContext {
    enum PrecedingChar: Equatable {
        case known(Character)
        case startOfField
        case unknown
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

        guard let offset = selectedTextOffset(from: rangeRef) else {
            return .unknown
        }

        let utf16Length = value.utf16.count
        guard offset <= utf16Length else { return .unknown }
        if offset == 0 { return .startOfField }

        let nsString = value as NSString
        let charIndex = offset - 1
        guard charIndex >= 0 else { return .startOfField }

        let composedRange = nsString.rangeOfComposedCharacterSequence(at: charIndex)
        let charString = nsString.substring(with: composedRange)
        guard let char = charString.first else { return .unknown }

        return .known(char)
    }

    /// Parses `kAXSelectedTextRangeAttribute` into a UTF-16 offset, or nil when
    /// the attribute is not an `AXValue` CFRange (testable without AX mocks).
    static func selectedTextOffset(from rangeRef: CFTypeRef) -> Int? {
        guard CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        let axValue = rangeRef as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }

        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &cfRange) else { return nil }

        let offset = cfRange.location
        guard offset != kCFNotFound, offset >= 0 else { return nil }
        return offset
    }

    /// Pure, testable decision: should a single leading space be prepended to
    /// the transcript before injection?
    /// - .known(c): true when c is a sentence-ender (one of . ! ? , : ;) or
    ///   alphanumeric (c.isLetter || c.isNumber); false when c is whitespace
    ///   or a newline; false otherwise.
    /// - .startOfField: always false (AX confirms caret at position 0).
    /// - .unknown: true iff transcriptFirstChar is alphanumeric (fallback
    ///   heuristic for AX-unreadable targets, e.g. Electron); false when
    ///   transcriptFirstChar is nil.
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
}
