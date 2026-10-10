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

    /// Extracts a UTF-16 AX selection without splitting a grapheme or trusting
    /// an invalid range. Returns nil rather than falling through to partial text.
    static func selectedText(in snapshot: CaretContext.Snapshot) -> String? {
        guard case .readable(let length) = snapshot.selectionLength,
              snapshot.location >= 0,
              length > 0,
              snapshot.location <= snapshot.value.utf16.count - length,
              let range = Range(NSRange(location: snapshot.location, length: length), in: snapshot.value),
              let lower = range.lowerBound.samePosition(in: snapshot.value.utf16),
              let upper = range.upperBound.samePosition(in: snapshot.value.utf16)
        else {
            return nil
        }
        let actualLocation = snapshot.value.utf16.distance(
            from: snapshot.value.utf16.startIndex,
            to: lower
        )
        let actualLength = snapshot.value.utf16.distance(from: lower, to: upper)
        guard actualLocation == snapshot.location, actualLength == length else {
            return nil
        }
        return String(snapshot.value[range])
    }
}
