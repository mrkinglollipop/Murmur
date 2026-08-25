import XCTest
@testable import Voice

final class DictionaryLearnTests: XCTestCase {

    private func makeStore() -> DictionaryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dict-test-\(UUID().uuidString).json")
        return DictionaryStore(fileURL: url)
    }

    func testUserInitiatedLearnsDissimilarWords() {
        let store = makeStore()
        let learned = store.learn(
            from: "I met with banana yesterday",
            to: "I met with Schwartz yesterday",
            userInitiated: true
        )
        XCTAssertEqual(learned.count, 1)
        XCTAssertEqual(learned.first?.variant, "banana")
        XCTAssertEqual(learned.first?.term, "Schwartz")
        XCTAssertTrue(store.entries.contains { $0.term == "Schwartz" && $0.variants.contains("banana") })
    }

    func testAutomatedLearnSkipsDissimilarWords() {
        let store = makeStore()
        let learned = store.learn(
            from: "I met with banana yesterday",
            to: "I met with Schwartz yesterday",
            userInitiated: false
        )
        XCTAssertTrue(learned.isEmpty)
    }

    func testUserInitiatedLearnsMergedPhraseForDotFix() {
        let store = makeStore()
        let learned = store.learn(
            from: "foo dot bar",
            to: "foo.bar",
            userInitiated: true
        )
        XCTAssertEqual(learned.count, 1)
        XCTAssertEqual(learned.first?.variant, "foo dot bar")
        XCTAssertEqual(learned.first?.term, "foo.bar")
        XCTAssertEqual(store.correct("use foo dot bar here").text, "use foo.bar here")
    }

    func testUserInitiatedLearnsTypoFix() {
        let store = makeStore()
        let learned = store.learn(
            from: "fix teh spelling",
            to: "fix the spelling",
            userInitiated: true
        )
        XCTAssertEqual(learned.count, 1)
        XCTAssertEqual(learned.first?.variant, "teh")
        XCTAssertEqual(learned.first?.term, "the")
    }

    func testUserInitiatedLearnsSplitWordMerge() {
        let store = makeStore()
        let learned = store.learn(
            from: "Get ignore it.",
            to: "gitignore it",
            userInitiated: true
        )
        XCTAssertEqual(learned.count, 1)
        XCTAssertEqual(learned.first?.variant, "Get ignore")
        XCTAssertEqual(learned.first?.term, "gitignore")
        XCTAssertEqual(store.correct("Get ignore it.").text, "gitignore it.")
    }

    func testAutomatedLearnSkipsWordCountMismatch() {
        let store = makeStore()
        let learned = store.learn(
            from: "Get ignore it.",
            to: "gitignore it",
            userInitiated: false
        )
        XCTAssertTrue(learned.isEmpty)
    }

    /// 2026-08-25 incident: ASR wrote "Type" for "the"; the user's hand-fix
    /// was offered as a learned rule mapping "Type" -> "the", which would have
    /// rewritten every legitimate "type" from then on. "type" is protected
    /// heard-side, so neither direction of that pair can be learned.
    /// (Typo fixes TO a function word, like "teh" -> "the", stay learnable.)
    func testLearnRefusesProtectedEnglishTerm() {
        let store = makeStore()
        for userInitiated in [true, false] {
            let learned = store.learn(
                from: "I like Type keyboard",
                to: "I like the keyboard",
                userInitiated: userInitiated
            )
            XCTAssertTrue(learned.isEmpty, "userInitiated=\(userInitiated)")
        }
        XCTAssertFalse(store.entries.contains { $0.term.caseInsensitiveCompare("the") == .orderedSame })
    }

    /// "type" is protected on the heard side too: no learned or phonetic rule
    /// may steal it as a variant of some jargon term.
    func testTypeIsProtectedHeardToken() {
        XCTAssertTrue(PhoneticMatcher.isProtectedHeardToken("type"))
        XCTAssertTrue(PhoneticMatcher.isProtectedHeardToken("Type"))
        let store = makeStore()
        let learned = store.learn(
            from: "use type here",
            to: "use Tauri here",
            userInitiated: true
        )
        XCTAssertTrue(learned.isEmpty)
    }
}
