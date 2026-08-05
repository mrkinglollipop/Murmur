import Foundation

/// Pure locate + region-diff helpers for post-injection correction learning.
/// No Accessibility — callers supply field value and caret UTF-16 offset.
enum CorrectionExtractor {

    static let maxFieldUTF16Units = 32_768

    struct LocateResult: Equatable {
        /// UTF-16 location of `deliveredText` in `fieldValue`.
        let utf16Location: Int
        let utf16Length: Int
    }

    struct RegionDiff: Equatable {
        let oldRegion: String
        let newRegion: String
    }

    /// Prefer a match whose end equals `caretUTF16`; else last occurrence whose end
    /// is nearest the caret. Returns nil when no match or when two+ matches are
    /// equally nearest (ambiguous).
    static func locate(
        deliveredText: String,
        in fieldValue: String,
        caretUTF16: Int
    ) -> LocateResult? {
        guard !deliveredText.isEmpty else { return nil }
        let fieldUTF16 = Array(fieldValue.utf16)
        let needle = Array(deliveredText.utf16)
        guard needle.count <= fieldUTF16.count else { return nil }

        var ends: [Int] = []
        let lastStart = fieldUTF16.count - needle.count
        for start in 0...lastStart {
            if Array(fieldUTF16[start..<(start + needle.count)]) == needle {
                ends.append(start + needle.count)
            }
        }
        guard !ends.isEmpty else { return nil }

        if let exact = ends.first(where: { $0 == caretUTF16 }) {
            return LocateResult(utf16Location: exact - needle.count, utf16Length: needle.count)
        }

        let distances = ends.map { abs($0 - caretUTF16) }
        guard let best = distances.min() else { return nil }
        let nearestEnds = ends.enumerated().filter { distances[$0.offset] == best }.map(\.element)
        guard nearestEnds.count == 1, let end = nearestEnds.first else { return nil }
        return LocateResult(utf16Location: end - needle.count, utf16Length: needle.count)
    }

    /// Diffs the injected span against the later field value by stripping the
    /// unchanged document prefix/suffix around that span.
    static func regionDiff(
        snapshotValue: String,
        injectedUTF16Location: Int,
        injectedUTF16Length: Int,
        currentValue: String
    ) -> RegionDiff? {
        let snap = snapshotValue as NSString
        let cur = currentValue as NSString
        guard injectedUTF16Location >= 0,
              injectedUTF16Length >= 0,
              injectedUTF16Location + injectedUTF16Length <= snap.length else {
            return nil
        }

        let prefix = snap.substring(to: injectedUTF16Location)
        let suffixStart = injectedUTF16Location + injectedUTF16Length
        let suffix = snap.substring(from: suffixStart)
        let oldRegion = snap.substring(
            with: NSRange(location: injectedUTF16Location, length: injectedUTF16Length)
        )

        let prefixLen = (prefix as NSString).length
        let suffixLen = (suffix as NSString).length
        guard cur.length >= prefixLen + suffixLen else { return nil }
        if prefixLen > 0 {
            guard cur.substring(to: prefixLen) == prefix else { return nil }
        }
        if suffixLen > 0 {
            let expectedSuffixStart = cur.length - suffixLen
            guard expectedSuffixStart >= prefixLen,
                  cur.substring(from: expectedSuffixStart) == suffix else { return nil }
        }

        let newStart = prefixLen
        let newEnd = cur.length - suffixLen
        guard newEnd >= newStart else { return nil }
        let newRegion = cur.substring(with: NSRange(location: newStart, length: newEnd - newStart))
        guard oldRegion != newRegion else { return nil }
        return RegionDiff(oldRegion: oldRegion, newRegion: newRegion)
    }

    static func exceedsFieldCap(_ value: String) -> Bool {
        value.utf16.count > maxFieldUTF16Units
    }
}
