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

    func testPhoneticGuardRejectsCatKite() {
        let store = makeStore()
        store.add(term: "cat", variants: [])
        let result = store.correct("I flew a kite today")
        XCTAssertEqual(result.text, "I flew a kite today")
        XCTAssertTrue(result.records.isEmpty)
    }

    func testAutoLearnedSourceTagging() {
        let store = makeStore()
        _ = store.learn(from: "use wispr here", to: "use whisper here", userInitiated: true)
        let result = store.correct("dictate wispr now")
        XCTAssertTrue(result.text.contains("whisper"))
        XCTAssertEqual(result.records.first?.source, .autoLearned)
    }
}
