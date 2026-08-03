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
}
