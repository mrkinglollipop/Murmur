import Foundation
import ApplicationServices

/// Decides whether a hold with a focused selection is an edit instruction or
/// ordinary dictation. Kept pure so AX reads stay at lifecycle boundaries and the safety
/// boundary is covered without starting recording services in tests.
enum VoiceEditRouting {
    static let maximumSelectionUTF16Length = 8_000

    enum Response: Equatable {
        case edit(String)
        case replace
    }

    /// Older/unmarked model responses retain the existing rewrite sanity gate.
    /// Only a marker occupying the first line can select replacement delivery.
    static func parseResponse(_ response: String) -> Response {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        let firstLine = String(lines.first ?? "").trimmingCharacters(in: .whitespaces)
        let marker = String(firstLine.reversed().drop(while: {
            $0.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
        }).reversed()).trimmingCharacters(in: .whitespaces).uppercased()
        switch marker {
        case "REPLACE": return .replace
        case "EDIT":
            return .edit(lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : "")
        default: return .edit(trimmed)
        }
    }

    enum Decision: Equatable {
        case dictate
        case edit(selection: String)
        case selectionTooLong(utf16Count: Int)
    }

    static func decide(
        snapshot: CaretContext.Snapshot,
        enabled: Bool,
        shiftHeld: Bool
    ) -> Decision {
        guard enabled, !shiftHeld, !snapshot.isUnknown,
              case .readable(let selectionLength) = snapshot.selectionLength,
              selectionLength > 0
        else {
            return .dictate
        }

        guard let selection = selectedText(in: snapshot), !selection.isEmpty else {
            return .dictate
        }
        guard selectionLength <= maximumSelectionUTF16Length else {
            return .selectionTooLong(utf16Count: selectionLength)
        }
        return .edit(selection: selection)
    }

    /// AX ranges may split composed graphemes at scalar boundaries, but a
    /// boundary inside a UTF-16 surrogate pair cannot represent selected text.
    static func selectedText(in snapshot: CaretContext.Snapshot) -> String? {
        let units = Array(snapshot.value.utf16)
        guard !snapshot.isUnknown,
              case .readable(let length) = snapshot.selectionLength,
              snapshot.location >= 0, length > 0, length <= units.count,
              snapshot.location <= units.count - length else { return nil }
        let end = snapshot.location + length
        func splitsSurrogatePair(_ offset: Int) -> Bool {
            offset > 0 && offset < units.count
                && (0xD800...0xDBFF).contains(units[offset - 1])
                && (0xDC00...0xDFFF).contains(units[offset])
        }
        guard !splitsSurrogatePair(snapshot.location), !splitsSurrogatePair(end) else { return nil }
        return String(decoding: units[snapshot.location..<end], as: UTF16.self)
    }

    /// Assistant-style lead-in ("Sure! Here's the edited text:") ending in a colon
    /// or line break. Deliberately narrow: a bare "OK" or "Here" without the
    /// terminator is ordinary prose.
    private static let assistantPreamble = "^(?:"
        + "(?:sure|certainly|of course|okay|ok|absolutely)[!.,]?[ \\t]*(?:here(?:'s|’s| is| are)[^:\\n]{0,40})?[:\\n]"
        + "|here(?:'s|’s| is| are)[^:\\n]{0,40}[:\\n]"
        + "|the (?:edited|revised|rewritten|updated) (?:text|version)[^:\\n]{0,20}[:\\n]"
        + "|(?:edited|revised|rewritten|updated)(?: text| version)?[:\\n]"
        + ")"

    private static func startsWithAssistantPreamble(_ text: String) -> Bool {
        text.range(of: assistantPreamble, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Rewrites share cleanup's length and symbol-only checks, but deliberately
    /// skip word preservation: changing the wording is the requested operation.
    static func resultLooksUsable(_ result: String, over selection: String) -> Bool {
        let output = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, output.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        // The prompt demands only the edited text. A lead-in the selection did not
        // itself start with is the model talking, and must not be injected.
        let selectionStart = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if startsWithAssistantPreamble(output), !startsWithAssistantPreamble(selectionStart) { return false }
        // Short selections legitimately grow (one word becomes a phrase), so the
        // ceiling is the larger of 2x and +160 characters; long selections are
        // still held to 2x so runaway model output cannot replace them.
        let count = selection.count
        let ceiling = max(count * 2, count + 160)
        let floor = Int(0.4 * Double(count))
        return output.count >= floor && output.count <= ceiling
    }

    static func fieldMatches(held: AXUIElement, fresh: AXUIElement?) -> Bool {
        guard let fresh else { return false }
        return CFEqual(held, fresh)
    }

    /// Ordinary dictation types at the current caret, as a keyboard would.
    /// Chromium/Electron recreate the composer's AX element while it keeps
    /// focus, so identity alone false-aborts (2026-10-15, Claude desktop).
    /// With the frontmost PID already pinned by the injector, an editable
    /// element of the held role is accepted. An unread held role keeps the
    /// strict identity rule. Voice edit never uses this: it must replace the
    /// exact selection it read.
    static func ordinaryDeliveryFieldMatches(
        held: AXUIElement, heldRole: String?, fresh: CaretContext.FocusedField
    ) -> Bool {
        if CFEqual(held, fresh.element) { return true }
        guard let heldRole, fresh.role == heldRole else { return false }
        return fresh.acceptsRelaxedDelivery
    }

    /// A release with nothing focused, or a frontmost app with no windows,
    /// binds the take to no field (2026-10-15: browser window closed mid-hold,
    /// user clicked into another app). A focused element that merely reads as
    /// non-editable stays bound: terminals (Terminal, iTerm, Ghostty) report
    /// their text area that way and must keep typing into it. Only definite
    /// answers unbind: a timed-out or failed focus read keeps the release app,
    /// so a slow app cannot hand its text to whatever is focused later.
    static func isUnboundReleaseTarget(focus: CaretContext.FocusRead, appHasWindows: Bool?) -> Bool {
        if appHasWindows == false { return true }
        if case .noFocus = focus { return true }
        return false
    }

    /// AX role, editability, PID and bundle only. Never field text.
    static func focusDiagnostic(field: CaretContext.FocusedField?, appHasWindows: Bool?, pid: pid_t?, bundle: String) -> String {
        let role = field.map { $0.role ?? "?" } ?? "none"
        let editable = field?.isEditable.map { $0 ? "yes" : "no" } ?? "?"
        let windows = appHasWindows.map { $0 ? "yes" : "no" } ?? "?"
        return "role=\(role) editable=\(editable) windows=\(windows) pid=\(pid.map { String($0) } ?? "nil") bundle=\(bundle)"
    }

    /// Counts, ranges and AX roles only. Never field text.
    static func deliveryCheckDiagnostic(
        check: String, held: CaretContext.Snapshot?, fresh: CaretContext.Snapshot, pid: pid_t?
    ) -> String {
        func selection(_ s: CaretContext.Snapshot) -> String {
            guard !s.isUnknown else { return "?" }
            switch s.selectionLength {
            case .readable(let n): return "\(s.location)+\(n)"
            case .unreadable: return "\(s.location)+?"
            }
        }
        func valueLength(_ s: CaretContext.Snapshot) -> String { s.isUnknown ? "?" : "\(s.value.utf16.count)" }
        let identity: String
        switch (held?.focusedElement, fresh.focusedElement) {
        case (let h?, let f?): identity = CFEqual(h, f) ? "same" : "differs"
        case (nil, _): identity = "held-unavailable"
        case (_, nil): identity = "fresh-unavailable"
        }
        let editable: String = fresh.focusedIsEditable.map { $0 ? "yes" : "no" } ?? "?"
        let heldRole: String = held?.focusedRole ?? "?"
        let freshRole: String = fresh.focusedRole ?? "?"
        let heldLength: String = held.map(valueLength) ?? "?"
        let heldSelection: String = held.map(selection) ?? "?"
        let pidText: String = pid.map { String($0) } ?? "?"
        return "\(check) check failed — identity=\(identity) role=\(heldRole)→\(freshRole)"
            + " freshEditable=\(editable) valueLen=\(heldLength)→\(valueLength(fresh))"
            + " selection=\(heldSelection)→\(selection(fresh)) pid=\(pidText)"
    }

    /// Element identity, field value, and range must all match the hold-start
    /// snapshot. Another field with identical content is not the same selection.
    static func selectionMatches(held: CaretContext.Snapshot?, fresh: CaretContext.Snapshot) -> Bool {
        guard let held, let heldElement = held.focusedElement,
              fieldMatches(held: heldElement, fresh: fresh.focusedElement),
              let selected = selectedText(in: held),
              selectedText(in: fresh) == selected else { return false }
        return held.value == fresh.value && held.location == fresh.location
            && held.selectionLength == fresh.selectionLength
    }

}
