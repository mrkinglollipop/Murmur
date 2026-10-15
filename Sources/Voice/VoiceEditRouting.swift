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
    /// Rewrites share cleanup's length and symbol-only checks, but deliberately
    /// skip word preservation: changing the wording is the requested operation.
    static func resultLooksUsable(_ result: String, over selection: String) -> Bool {
        let output = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, output.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        let ratio = Double(output.count) / Double(max(selection.count, 1))
        return (0.4...2.0).contains(ratio)
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
        return fresh.isEditable == true
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
