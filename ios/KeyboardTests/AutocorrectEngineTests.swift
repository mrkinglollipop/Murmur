import XCTest

final class AutocorrectEngineTests: XCTestCase {
    func testWordSpanTakesTrailingLettersAndApostrophes() {
        XCTAssertEqual(AutocorrectEngine.wordSpan(beforeInput: "hello th"), "th")
        XCTAssertEqual(AutocorrectEngine.wordSpan(beforeInput: "it's"), "it's")
        XCTAssertEqual(AutocorrectEngine.wordSpan(beforeInput: "hello "), "")
        XCTAssertEqual(AutocorrectEngine.wordSpan(beforeInput: ""), "")
        XCTAssertEqual(AutocorrectEngine.wordSpan(beforeInput: "teh"), "teh")
        XCTAssertEqual(AutocorrectEngine.wordSpan(beforeInput: "say don't"), "don't")
    }

    func testWordSpanStopsAtPunctuation() {
        XCTAssertEqual(AutocorrectEngine.wordSpan(beforeInput: "hello,th"), "th")
        XCTAssertEqual(AutocorrectEngine.wordSpan(beforeInput: "ok."), "")
    }

    func testSkipDigitsAcronymsAndURLs() {
        XCTAssertTrue(AutocorrectEngine.shouldSkip("abc123"))
        XCTAssertTrue(AutocorrectEngine.shouldSkip("NASA"))
        XCTAssertTrue(AutocorrectEngine.shouldSkip("OK"))
        XCTAssertTrue(AutocorrectEngine.shouldSkip("https://example.com"))
        XCTAssertTrue(AutocorrectEngine.shouldSkip("www.apple.com"))
        XCTAssertTrue(AutocorrectEngine.shouldSkip("foo.bar"))
        XCTAssertFalse(AutocorrectEngine.shouldSkip("teh"))
        XCTAssertFalse(AutocorrectEngine.shouldSkip("The"))
        XCTAssertFalse(AutocorrectEngine.shouldSkip("I"))
    }

    func testCommitText() {
        XCTAssertTrue(AutocorrectEngine.isCommitText(" "))
        XCTAssertTrue(AutocorrectEngine.isCommitText("."))
        XCTAssertTrue(AutocorrectEngine.isCommitText(","))
        XCTAssertTrue(AutocorrectEngine.isCommitText("\n"))
        XCTAssertFalse(AutocorrectEngine.isCommitText("'"))
        XCTAssertFalse(AutocorrectEngine.isCommitText("a"))
        XCTAssertFalse(AutocorrectEngine.isCommitText("the"))
    }

    func testApplyCase() {
        XCTAssertEqual(AutocorrectEngine.applyCase(template: "teh", correction: "the"), "the")
        XCTAssertEqual(AutocorrectEngine.applyCase(template: "Teh", correction: "the"), "The")
        XCTAssertEqual(AutocorrectEngine.applyCase(template: "TEH", correction: "the"), "THE")
    }

    func testReplacementMath() {
        let replacement = AutocorrectEngine.replacement(span: "teh", correction: "the")
        XCTAssertEqual(replacement.deleteCount, 3)
        XCTAssertEqual(replacement.insert, "the")
        let titled = AutocorrectEngine.replacement(span: "Teh", correction: "the")
        XCTAssertEqual(titled.deleteCount, 3)
        XCTAssertEqual(titled.insert, "The")
    }

    func testPrefixMatchesExcludesExactAndRespectsLimit() {
        let list = ["the", "then", "there", "their", "theme"]
        XCTAssertEqual(
            AutocorrectEngine.prefixMatches(prefix: "the", in: list, limit: 3),
            ["then", "there", "their"]
        )
        XCTAssertEqual(
            AutocorrectEngine.prefixMatches(prefix: "the", in: ["Then", "THERE", "the"], limit: 3),
            ["Then", "THERE"]
        )
    }

    func testCommittedSpanKeepsTrailingWhitespace() {
        let spaced = AutocorrectEngine.committedSpan(beforeInput: "hello the ")
        XCTAssertEqual(spaced.word, "the")
        XCTAssertEqual(spaced.trailing, " ")
        let double = AutocorrectEngine.committedSpan(beforeInput: "the  ")
        XCTAssertEqual(double.word, "the")
        XCTAssertEqual(double.trailing, "  ")
        let punct = AutocorrectEngine.committedSpan(beforeInput: "the.")
        XCTAssertEqual(punct.word, "")
        XCTAssertEqual(punct.trailing, "")
        let midWord = AutocorrectEngine.committedSpan(beforeInput: "the")
        XCTAssertEqual(midWord.word, "the")
        XCTAssertEqual(midWord.trailing, "")
    }

    func testUniquedDropsDuplicatesAndExcluded() {
        XCTAssertEqual(
            AutocorrectEngine.uniqued(["The", "the", "then", "Then"], excluding: "the", limit: 3),
            ["then"]
        )
    }
}
