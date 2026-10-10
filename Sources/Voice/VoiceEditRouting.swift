import Foundation

/// Decides whether a hold with a focused selection is an edit instruction or
/// ordinary dictation. Kept pure so AX reads stay at hold start and the safety
/// boundary is covered without starting recording services in tests.
enum VoiceEditRouting {
    static let maximumSelectionUTF16Length = 8_000

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

        guard selectionLength <= maximumSelectionUTF16Length else {
            return .selectionTooLong(utf16Count: selectionLength)
        }
        guard let selection = selectedText(in: snapshot), !selection.isEmpty else {
            return .dictate
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
}
