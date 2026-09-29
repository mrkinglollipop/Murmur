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

    func testLetterTokenWithTrailingPeriod() {
        // ASR often emits sentence-final punct glued to the letter.
        XCTAssertEqual(
            SpokenCapitalization.apply("Client secret capital S."),
            "Client Secret."
        )
        XCTAssertEqual(
            SpokenCapitalization.apply("A lot of 2.0 Client secret capital S."),
            "A lot of 2.0 Client Secret."
        )
    }

    func testProseWithCapitalNounIsUnchanged() {
        let sentence = "It went well in the capital, I think"
        XCTAssertEqual(SpokenCapitalization.apply(sentence), sentence)
    }

    func testDistantTargetIsNotCapitalizedAndNewlineSurvives() {
        let text = "Is this the state capital, I guess\nNew line here"
        XCTAssertEqual(SpokenCapitalization.apply(text), text)
    }

    func testCommandKeepsFollowingCommaAndNewline() {
        XCTAssertEqual(
            SpokenCapitalization.apply("my name is john capital j, and I live here\nsecond line"),
            "my name is John, and I live here\nsecond line"
        )
        XCTAssertEqual(
            SpokenCapitalization.apply("client secret capital s\nnext"),
            "client Secret\nnext"
        )
    }

    func testOAuthStyleCapitalCS() {
        XCTAssertEqual(
            SpokenCapitalization.apply("OAuth Client secret capital c capital s"),
            "OAuth Client Secret"
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
