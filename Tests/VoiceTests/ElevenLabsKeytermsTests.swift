import XCTest
@testable import Voice

/// Covers the pure (non-networked) parts of plan 014: the `keyterms`
/// selection function (`ElevenLabsRealtimeTranscriber.selectKeyterms(from:)`)
/// and the socket URL builder (`buildSocketURL`), which now folds in
/// `no_verbatim` and `keyterms`. Mirrors the static-method testing style of
/// `ElevenLabsRealtimeTests`.
final class ElevenLabsKeytermsTests: XCTestCase {

    // MARK: - selectKeyterms: canonical terms only, never variants

    func testSelectKeytermsReturnsCanonicalTermsOnly() {
        let entries = [
            DictionaryEntry(term: "Xcodegen", variants: ["ex codegen", "eggs codegen"]),
            DictionaryEntry(term: "Keychain", variants: ["key chain"])
        ]
        let result = ElevenLabsRealtimeTranscriber.selectKeyterms(from: entries)
        XCTAssertEqual(Set(result), ["Xcodegen", "Keychain"])
        for variant in ["ex codegen", "eggs codegen", "key chain"] {
            XCTAssertFalse(result.contains(variant), "variant \(variant) leaked into keyterms")
        }
    }

    // MARK: - De-dup, empty, single-char

    func testSelectKeytermsDeduplicatesCaseInsensitively() {
        let entries = [
            DictionaryEntry(term: "Scribe", variants: []),
            DictionaryEntry(term: "scribe", variants: []),
            DictionaryEntry(term: "SCRIBE", variants: [])
        ]
        let result = ElevenLabsRealtimeTranscriber.selectKeyterms(from: entries)
        XCTAssertEqual(result.count, 1)
    }

    func testSelectKeytermsDropsEmptyAndWhitespaceOnlyTerms() {
        let entries = [
            DictionaryEntry(term: "", variants: []),
            DictionaryEntry(term: "   ", variants: []),
            DictionaryEntry(term: "Valid", variants: [])
        ]
        let result = ElevenLabsRealtimeTranscriber.selectKeyterms(from: entries)
        XCTAssertEqual(result, ["Valid"])
    }

    func testSelectKeytermsDropsSingleCharacterTerms() {
        let entries = [
            DictionaryEntry(term: "a", variants: []),
            DictionaryEntry(term: "I", variants: []),
            DictionaryEntry(term: "AI", variants: [])
        ]
        let result = ElevenLabsRealtimeTranscriber.selectKeyterms(from: entries)
        XCTAssertEqual(result, ["AI"])
    }

    // MARK: - Server limits (exceeding either one fails the handshake)

    func testSelectKeytermsDropsTermsOverTwentyCharacters() {
        let entries = [
            DictionaryEntry(term: "ElevenLabsRealtimeTranscriber", variants: []), // 29
            DictionaryEntry(term: String(repeating: "a", count: 21), variants: []),
            DictionaryEntry(term: String(repeating: "b", count: 20), variants: []) // exactly at the limit
        ]
        let result = ElevenLabsRealtimeTranscriber.selectKeyterms(from: entries)
        XCTAssertEqual(result, [String(repeating: "b", count: 20)])
    }

    func testSelectKeytermsCapsAtServerLimitPreferringHighestFixCount() {
        var entries: [DictionaryEntry] = []
        for i in 0..<150 {
            entries.append(DictionaryEntry(term: "term\(i)", variants: [], fixCount: i))
        }
        let result = ElevenLabsRealtimeTranscriber.selectKeyterms(from: entries)
        XCTAssertEqual(ElevenLabsRealtimeTranscriber.maxKeyterms, 50)
        XCTAssertEqual(result.count, 50)
        // Highest fixCount entries (term149...term100) must be the ones kept.
        XCTAssertTrue(result.contains("term149"))
        XCTAssertTrue(result.contains("term100"))
        XCTAssertFalse(result.contains("term99"))
        XCTAssertFalse(result.contains("term0"))
    }

    /// Every keyterm the selector emits must survive the server's own limits,
    /// since one bad term rejects the whole `session_started` handshake.
    func testSelectedKeytermsAlwaysSatisfyServerLimits() {
        let entries = (0..<200).map { i in
            DictionaryEntry(term: String(repeating: "x", count: i % 30), variants: [], fixCount: i)
        }
        let result = ElevenLabsRealtimeTranscriber.selectKeyterms(from: entries)
        XCTAssertLessThanOrEqual(result.count, ElevenLabsRealtimeTranscriber.maxKeyterms)
        for term in result {
            XCTAssertGreaterThan(term.count, 1)
            XCTAssertLessThanOrEqual(term.count, ElevenLabsRealtimeTranscriber.maxKeytermLength)
        }
    }

    func testSelectKeytermsTiebreaksEqualFixCountByMostRecentlyAdded() {
        let entries = [
            DictionaryEntry(term: "older", variants: [], fixCount: 0),
            DictionaryEntry(term: "newer", variants: [], fixCount: 0)
        ]
        let result = ElevenLabsRealtimeTranscriber.selectKeyterms(from: entries)
        XCTAssertEqual(result, ["newer", "older"])
    }

    func testSelectKeytermsEmptyWhenNoEntries() {
        XCTAssertEqual(ElevenLabsRealtimeTranscriber.selectKeyterms(from: []), [])
    }

    // MARK: - buildSocketURL: no_verbatim + keyterms encoding

    func testBuildSocketURLIncludesNoVerbatimTrue() {
        let url = ElevenLabsRealtimeTranscriber.buildSocketURL(language: "en", noVerbatim: true, keyterms: [])
        XCTAssertTrue(url?.query?.contains("no_verbatim=true") ?? false)
    }

    func testBuildSocketURLIncludesNoVerbatimFalse() {
        let url = ElevenLabsRealtimeTranscriber.buildSocketURL(language: "en", noVerbatim: false, keyterms: [])
        XCTAssertTrue(url?.query?.contains("no_verbatim=false") ?? false)
    }

    /// The realtime socket requires REPEATED `keyterms` query params, not a
    /// single comma-joined value (probed live 2026-07-09 — comma-joined is
    /// read as one over-long keyterm and rejected).
    func testBuildSocketURLEncodesKeytermsAsRepeatedParams() {
        let url = ElevenLabsRealtimeTranscriber.buildSocketURL(
            language: "en",
            noVerbatim: true,
            keyterms: ["Xcodegen", "Keychain"]
        )
        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        let keytermItems = components?.queryItems?.filter { $0.name == "keyterms" } ?? []
        XCTAssertEqual(keytermItems.map { $0.value }, ["Xcodegen", "Keychain"])
        // Never a single comma-joined value.
        XCTAssertNil(keytermItems.first(where: { $0.value == "Xcodegen,Keychain" }))
    }

    /// `+` must go on the wire as `%2B`: URLComponents leaves it literal, and
    /// form-urlencoded parsers read a literal `+` as a space — so "C++" would
    /// silently arrive as "C  " and the bias for it would do nothing.
    func testBuildSocketURLPercentEncodesPlusInKeyterms() {
        let url = ElevenLabsRealtimeTranscriber.buildSocketURL(
            language: "en",
            noVerbatim: false,
            keyterms: ["C++", "g++"]
        )
        let query = url!.absoluteString
        XCTAssertTrue(query.contains("keyterms=C%2B%2B"), "got: \(query)")
        XCTAssertFalse(query.contains("keyterms=C++"), "literal + leaked: \(query)")
        // And the encoding still round-trips back to the original terms.
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
            .queryItems!.filter { $0.name == "keyterms" }
        XCTAssertEqual(items.map { $0.value }, ["C++", "g++"])
    }

    /// The 20-char server limit is enforced in UTF-8 bytes (the strictest
    /// plausible server-side count), not Swift grapheme clusters.
    func testSelectKeytermsLengthLimitCountsUTF8Bytes() {
        // 15 graphemes but 30 UTF-8 bytes — must be dropped.
        let accented = String(repeating: "é", count: 15)
        let entries = [
            DictionaryEntry(term: accented, variants: []),
            DictionaryEntry(term: "plainAscii", variants: [])
        ]
        let result = ElevenLabsRealtimeTranscriber.selectKeyterms(from: entries)
        XCTAssertEqual(result, ["plainAscii"])
    }

    func testBuildSocketURLOmitsKeytermsWhenEmpty() {
        let url = ElevenLabsRealtimeTranscriber.buildSocketURL(language: "en", noVerbatim: true, keyterms: [])
        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        let keytermItems = components?.queryItems?.filter { $0.name == "keyterms" } ?? []
        XCTAssertTrue(keytermItems.isEmpty)
    }
}
