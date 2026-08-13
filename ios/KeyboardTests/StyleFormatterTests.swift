import XCTest

final class StyleFormatterTests: XCTestCase {
    func testFormalAddsCapsAndPeriod() {
        XCTAssertEqual(
            StyleFormatter.apply("hello there", profile: .formal),
            "Hello there."
        )
    }

    func testCasualStripsTrailingPeriodOnShortTakes() {
        XCTAssertEqual(
            StyleFormatter.apply("hello there.", profile: .casual),
            "Hello there"
        )
    }

    func testCasualKeepsPeriodsWhenLong() {
        let text = "First sentence. Second sentence. Third sentence."
        XCTAssertEqual(
            StyleFormatter.apply(text, profile: .casual),
            "First sentence. Second sentence. Third sentence."
        )
    }

    func testVeryCasualLowercasesAndStripsPeriod() {
        XCTAssertEqual(
            StyleFormatter.apply("Hello There.", profile: .veryCasual),
            "hello there"
        )
    }

    func testVeryCasualKeepsDictionaryTerms() {
        XCTAssertEqual(
            StyleFormatter.apply(
                "Deploy to Kubernetes now.",
                profile: .veryCasual,
                preserveTerms: ["Kubernetes"]
            ),
            "deploy to Kubernetes now"
        )
    }

    func testFormalKeepsQuestionMark() {
        XCTAssertEqual(
            StyleFormatter.apply("are you free", profile: .formal),
            "Are you free."
        )
        XCTAssertEqual(
            StyleFormatter.apply("are you free?", profile: .formal),
            "Are you free?"
        )
    }
}

final class KeytermsSelectionTests: XCTestCase {
    func testSelectsCanonicalTermsNotVariants() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kt-\(UUID().uuidString).json")
        let store = DictionaryStore(fileURL: url)
        store.add(term: "Kubernetes", variants: ["kubernetis"])
        store.add(term: "X", variants: ["ex"])
        let terms = DictionaryStore.selectKeyterms(from: store.entries)
        XCTAssertEqual(terms, ["Kubernetes"])
    }

    func testDropsOverlongTerms() {
        let long = String(repeating: "a", count: 51)
        let entry = DictionaryEntry(term: long, variants: [])
        XCTAssertTrue(DictionaryStore.selectKeyterms(from: [entry]).isEmpty)
    }
}
