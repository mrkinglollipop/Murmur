import XCTest
@testable import Voice

final class PhoneticMatcherTests: XCTestCase {

    func testEncodeVectors() {
        assertEncode("hyzer", primary: "HSR", secondary: nil)
        assertEncode("Heiser", primary: "HSR", secondary: nil)
        assertEncode("Groq", primary: "KRK", secondary: nil)
        assertEncode("grok", primary: "KRK", secondary: nil)
        assertEncode("Kubernetes", primary: "KPRNTS", secondary: nil)
        assertEncode("Kubernettes", primary: "KPRNTS", secondary: nil)
        assertEncode("Schwartz", primary: "XRTS", secondary: "XFRTS")
        assertEncode("wispr", primary: "ASPR", secondary: "FSPR")
        assertEncode("whisper", primary: "ASPR", secondary: nil)
        assertEncode("cat", primary: "KT", secondary: nil)
        assertEncode("kite", primary: "KT", secondary: nil)
        // Regression vectors for the mid-word GH infinite loop (processG once
        // failed to advance on GH-after-vowel at positions 1-2, hanging the
        // encoder on "night") plus the flagship shared-primary pair.
        assertEncode("night", primary: "NT", secondary: nil)
        assertEncode("hyzer", primary: "HSR", secondary: nil)
        assertEncode("Heiser", primary: "HSR", secondary: nil)
    }

    func testGuardAccepts() {
        // Isolated from the real /usr/share/dict/words lookup (an empty fake
        // lexicon) so these pure distance/similarity assertions can't be
        // perturbed by quirks of the system word list — e.g. "tari" is
        // itself an obscure real dictionary entry and would otherwise
        // reject the very correction being asserted here.
        let noRealWords = fakeLexicon([])
        XCTAssertTrue(PhoneticMatcher.guardAccepts(heard: "cast", candidate: "cost", lexicon: noRealWords))
        XCTAssertFalse(PhoneticMatcher.guardAccepts(heard: "cat", candidate: "kite", lexicon: noRealWords))
        XCTAssertTrue(PhoneticMatcher.guardAccepts(heard: "wispr", candidate: "whisper", lexicon: noRealWords))
        // Flagship case (plans/021 P2): identical primary keys (HSR) relax the
        // lexical bar to 0.4, so similarity 0.5 passes. Without the primary
        // match the strict 0.6 bar applies and the pair is rejected.
        XCTAssertTrue(PhoneticMatcher.guardAccepts(heard: "hyzer", candidate: "Heiser", primaryKeyMatch: true, lexicon: noRealWords))
        XCTAssertFalse(PhoneticMatcher.guardAccepts(heard: "hyzer", candidate: "Heiser", primaryKeyMatch: false, lexicon: noRealWords))
        XCTAssertFalse(PhoneticMatcher.guardAccepts(heard: "line", candidate: "Linode", lexicon: noRealWords))
        XCTAssertFalse(PhoneticMatcher.guardAccepts(heard: "land", candidate: "Linode", primaryKeyMatch: true, lexicon: noRealWords))
        XCTAssertTrue(PhoneticMatcher.guardAccepts(heard: "Tari", candidate: "Tauri", lexicon: noRealWords))
        XCTAssertTrue(PhoneticMatcher.isProtectedHeardToken("Line"))
        XCTAssertTrue(PhoneticMatcher.isProtectedEnglishPhrase("line out"))
        XCTAssertFalse(PhoneticMatcher.isProtectedEnglishPhrase("Get ignore"))
        XCTAssertFalse(PhoneticMatcher.isProtectedHeardToken("hyzer"))
    }

    // MARK: - RealWordLexicon gating (plan: stop rewriting real English words)

    func testGuardAcceptsRejectsRealWordsFoundInLexicon() {
        // Live user data: the phonetic corrector rewrote ordinary words into
        // jargon dictionary terms once a metaphone key happened to collide.
        // Every heard word below is a real word an injected lexicon reports
        // as known, so guardAccepts must reject regardless of how close the
        // candidate looks by distance/similarity.
        let realWords = fakeLexicon([
            "is", "the", "many", "money", "try", "true", "ready", "main", "mine", "slow",
        ])
        XCTAssertFalse(PhoneticMatcher.guardAccepts(heard: "is", candidate: "bs", lexicon: realWords))
        XCTAssertFalse(PhoneticMatcher.guardAccepts(heard: "the", candidate: "type", lexicon: realWords))
        XCTAssertFalse(PhoneticMatcher.guardAccepts(heard: "many", candidate: "manna", lexicon: realWords))
        XCTAssertFalse(PhoneticMatcher.guardAccepts(heard: "money", candidate: "Manna", lexicon: realWords))
        XCTAssertFalse(PhoneticMatcher.guardAccepts(heard: "try", candidate: "tauri", lexicon: realWords))
        XCTAssertFalse(PhoneticMatcher.guardAccepts(heard: "true", candidate: "tauri", lexicon: realWords))
        XCTAssertFalse(PhoneticMatcher.guardAccepts(heard: "ready", candidate: "ready/done", lexicon: realWords))
        XCTAssertFalse(PhoneticMatcher.guardAccepts(heard: "main", candidate: "manna", lexicon: realWords))
        XCTAssertFalse(PhoneticMatcher.guardAccepts(heard: "mine", candidate: "manna", lexicon: realWords))
        XCTAssertFalse(PhoneticMatcher.guardAccepts(heard: "slow", candidate: "sol", lexicon: realWords))
    }

    func testGuardAcceptsRejectsHeardWordsShorterThanThreeCharacters() {
        // Short heard tokens are rejected outright regardless of lexicon
        // membership — "is" (2 chars) must reject even against an empty
        // lexicon that doesn't itself know the word.
        let noRealWords = fakeLexicon([])
        XCTAssertFalse(PhoneticMatcher.guardAccepts(heard: "is", candidate: "bs", lexicon: noRealWords))
        XCTAssertFalse(PhoneticMatcher.guardAccepts(heard: "ok", candidate: "Okta", lexicon: noRealWords))
    }

    func testGuardAcceptsKeepsJargonCorrectionsWorking() {
        // Non-words phonetically near dictionary terms must still correct —
        // the lexicon gate should never catch names that aren't real words.
        let noRealWords = fakeLexicon([])
        XCTAssertTrue(PhoneticMatcher.guardAccepts(heard: "Kipu", candidate: "Khipu", lexicon: noRealWords))
        XCTAssertTrue(PhoneticMatcher.guardAccepts(heard: "Kifu", candidate: "Khipu", lexicon: noRealWords))
        XCTAssertTrue(PhoneticMatcher.guardAccepts(heard: "Egis", candidate: "Aegis", lexicon: noRealWords))
        XCTAssertTrue(PhoneticMatcher.guardAccepts(heard: "Groq", candidate: "Grok", lexicon: noRealWords))
    }

    func testRealWordLexiconLowercasesMembershipChecks() {
        let lexicon = fakeLexicon(["money"])
        XCTAssertTrue(lexicon.contains("Money"))
        XCTAssertTrue(lexicon.contains("MONEY"))
        XCTAssertFalse(lexicon.contains("Egis"))
    }

    func testRealWordLexiconFallbackCoversCommonWords() {
        // Guards the built-in fallback used when /usr/share/dict/words is
        // unreadable — it must still catch the words seen misfiring live.
        let fallback = RealWordLexicon.fallbackWords
        for word in [
            "is", "the", "a", "an", "and", "or", "but", "to", "of", "in", "on",
            "at", "by", "for", "with", "as", "if", "it", "be", "do", "day",
            "try", "true", "many", "money", "mine", "main", "ready", "slow",
            "type", "one", "ones", "sent", "said", "was", "are", "this",
            "that", "these", "those",
        ] {
            XCTAssertTrue(fallback.contains(word), "expected fallback lexicon to contain '\(word)'")
        }
        XCTAssertGreaterThanOrEqual(fallback.count, 60)
    }

    private func fakeLexicon(_ words: Set<String>) -> RealWordLexicon {
        RealWordLexicon { words.contains($0) }
    }

    private func assertEncode(
        _ input: String,
        primary: String,
        secondary: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let encoded = PhoneticMatcher.encode(input)
        XCTAssertEqual(encoded.primary, primary, file: file, line: line)
        XCTAssertEqual(encoded.secondary, secondary, file: file, line: line)
    }
}
