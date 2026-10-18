import XCTest
@testable import Voice

final class DictionaryPhoneticCorrectionTests: XCTestCase {

    private func makeStore() -> DictionaryStore {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dict-phonetic-\(UUID().uuidString)")
        return DictionaryStore(
            fileURL: base.appendingPathComponent("dictionary.json"),
            blocklistFileURL: base.appendingPathComponent("blocklist.json")
        )
    }

    func testPhoneticCorrectionGroq() {
        let store = makeStore()
        store.add(term: "Groq", variants: [])
        let result = store.correct("I tested grok yesterday")
        XCTAssertTrue(result.text.contains("Groq"))
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.source, .phonetic)
        XCTAssertEqual(result.records.first?.heard, "grok")
        XCTAssertEqual(result.records.first?.replaced, "Groq")
    }

    func testPhoneticCorrectionHyzerToHeiser() {
        // Flagship case from plans/021 P2: shares a primary metaphone key with
        // the term but sits at Levenshtein distance 3 / similarity 0.5 — must
        // pass via the relaxed primary-key-match guard bar.
        let store = makeStore()
        store.add(term: "Heiser", variants: [])
        // Sentence deliberately includes "night": its mid-word GH once hung
        // the encoder (SIGTERM), masquerading as a guard failure.
        let result = store.correct("we listened to hyzer last night")
        XCTAssertTrue(result.text.contains("Heiser"))
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.source, .phonetic)
        XCTAssertEqual(result.records.first?.heard, "hyzer")
        XCTAssertEqual(result.records.first?.replaced, "Heiser")
    }

    func testBlocklistSuppressesRegexCorrection() {
        let store = makeStore()
        store.add(term: "Kubernetes", variants: ["Kubernettes"])
        XCTAssertTrue(store.correct("running Kubernettes now").text.contains("Kubernetes"))
        store.blocklistPair(heard: "Kubernettes", replaced: "Kubernetes")
        let blocked = store.correct("running Kubernettes now")
        XCTAssertEqual(blocked.text, "running Kubernettes now")
        XCTAssertTrue(blocked.records.isEmpty)
    }

    func testBlocklistSuppressesPhoneticCorrection() {
        let store = makeStore()
        store.add(term: "Groq", variants: [])
        store.blocklistPair(heard: "grok", replaced: "Groq")
        let result = store.correct("I tested grok yesterday")
        XCTAssertEqual(result.text, "I tested grok yesterday")
        XCTAssertTrue(result.records.isEmpty)
    }

    func testPhoneticDoesNotStealLineOrLandForLinode() {
        let store = makeStore()
        store.add(term: "Linode", variants: ["line out"])
        let field = store.correct("Did test, test, test in the field clean?")
        XCTAssertEqual(field.text, "Did test, test, test in the field clean?")
        XCTAssertTrue(field.records.isEmpty)
        let line = store.correct("the line broke")
        XCTAssertEqual(line.text, "the line broke")
        let phrase = store.correct("Can you get the line out or does that need to be the line out?")
        XCTAssertEqual(
            phrase.text,
            "Can you get the line out or does that need to be the line out?"
        )
        XCTAssertTrue(phrase.records.isEmpty)
    }

    func testUpdateStripsProtectedEnglishPhraseVariants() {
        let store = makeStore()
        store.add(term: "Linode", variants: ["linod"])
        guard var entry = store.entries.first else {
            XCTFail("expected Linode entry")
            return
        }
        entry.variants = ["linod", "line out"]
        store.update(entry)
        XCTAssertEqual(store.entries.first?.variants, ["linod"])
        let heard = store.correct("Can you get the line out?")
        XCTAssertEqual(heard.text, "Can you get the line out?")
        XCTAssertTrue(heard.records.isEmpty)
    }

    func testPhoneticGuardRejectsCatKite() {
        let store = makeStore()
        store.add(term: "cat", variants: [])
        let result = store.correct("I flew a kite today")
        XCTAssertEqual(result.text, "I flew a kite today")
        XCTAssertTrue(result.records.isEmpty)
    }

    /// A learned rule is a suggestion: it tags nothing until approved, then
    /// behaves like any dictionary entry.
    func testLearnedRuleIsInertUntilApprovedThenTagsDictionary() {
        let store = makeStore()
        let learned = store.learn(from: "use wispr here", to: "use whisper here", userInitiated: true)
        let pending = store.correct("dictate wispr now")
        XCTAssertEqual(pending.text, "dictate wispr now")
        XCTAssertTrue(pending.records.isEmpty)

        store.approveLearnedBatch(LearnBatch(corrections: learned))
        let result = store.correct("dictate wispr now")
        XCTAssertTrue(result.text.contains("whisper"))
        XCTAssertEqual(result.records.first?.source, .dictionary)
    }
}
