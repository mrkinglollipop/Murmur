import XCTest
@testable import Voice

final class SpokenCapitalizationTests: XCTestCase {

    func testLockedGoldenSingleCapital() {
        XCTAssertEqual(
            SpokenCapitalization.apply("api key for x capital x"),
            "api key for X"
        )
    }

    func testLockedGoldenRTLMultiCommand() {
        XCTAssertEqual(
            SpokenCapitalization.apply("x api key secret capital k capital s capital x"),
            "X api Key Secret"
        )
    }

    func testCommaEquivalentToWhitespace() {
        XCTAssertEqual(
            SpokenCapitalization.apply("x api key secret capital k, capital s, capital x"),
            "X api Key Secret"
        )
    }

    func testCapsAndUppercaseAliases() {
        XCTAssertEqual(SpokenCapitalization.apply("foo x caps x"), "foo X")
        XCTAssertEqual(SpokenCapitalization.apply("foo x uppercase x"), "foo X")
    }

    func testNATOLetterInCommandFrame() {
        XCTAssertEqual(
            SpokenCapitalization.apply("api key for x capital xray"),
            "api key for X"
        )
        XCTAssertEqual(
            SpokenCapitalization.apply("secret capital sierra"),
            "Secret"
        )
    }

    func testBareNATOWordIsNotALetter() {
        XCTAssertEqual(
            SpokenCapitalization.apply("book a hotel tonight"),
            "book a hotel tonight"
        )
    }

    func testUnknownLetterWordFailSoft() {
        XCTAssertEqual(
            SpokenCapitalization.apply("api key capital foobar"),
            "api key capital foobar"
        )
    }

    func testNoPrecedingMatchFailSoft() {
        XCTAssertEqual(
            SpokenCapitalization.apply("capital x"),
            "capital x"
        )
    }

    func testPreferSingleLetterOverWordStart() {
        XCTAssertEqual(
            SpokenCapitalization.apply("s secret capital s"),
            "S secret"
        )
    }

    func testPreservesCommasWhenNoCommand() {
        XCTAssertEqual(
            SpokenCapitalization.apply("Hello, world"),
            "Hello, world"
        )
    }

    func testPreservesNewlinesWhenNoCommand() {
        XCTAssertEqual(
            SpokenCapitalization.apply("line1\nline2"),
            "line1\nline2"
        )
    }
}

final class TranscriptionPipelineCapsGateTests: XCTestCase {

    func testPreprocessAppliesCapsWhenNotCodeAware() {
        let out = TranscriptionPipeline.preprocessBeforeCleanup(
            "api key for x capital x",
            codeAware: false
        )
        XCTAssertEqual(out, "api key for X")
    }

    func testPreprocessAppliesCapsBeforeSpokenPunctuation() {
        // Caps runs first; codeAware SP still sees the capped text.
        let out = TranscriptionPipeline.preprocessBeforeCleanup(
            "foo x capital x underscore bar",
            codeAware: true
        )
        XCTAssertEqual(out, "foo X_bar")
    }

    func testPreprocessCapsOnShortInput() {
        let out = TranscriptionPipeline.preprocessBeforeCleanup(
            "x capital x",
            codeAware: false
        )
        XCTAssertEqual(out, "X")
    }
}
