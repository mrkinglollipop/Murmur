import XCTest
@testable import Voice

final class CaretContextTests: XCTestCase {

    // MARK: - Known preceding character

    func testShouldPrependSpace_knownSentenceEnders() {
        let enders: [Character] = [".", "!", "?", ",", ":", ";"]
        for ender in enders {
            XCTAssertTrue(
                CaretContext.shouldPrependSpace(precedingChar: .known(ender), transcriptFirstChar: nil),
                "Expected true for sentence ender '\(ender)'"
            )
        }
    }

    func testShouldPrependSpace_knownAlphanumericLetter() {
        XCTAssertTrue(
            CaretContext.shouldPrependSpace(precedingChar: .known("a"), transcriptFirstChar: nil)
        )
        XCTAssertTrue(
            CaretContext.shouldPrependSpace(precedingChar: .known("Z"), transcriptFirstChar: nil)
        )
    }

    func testShouldPrependSpace_knownDigit() {
        XCTAssertTrue(
            CaretContext.shouldPrependSpace(precedingChar: .known("5"), transcriptFirstChar: nil)
        )
    }

    func testShouldPrependSpace_knownSpace() {
        XCTAssertFalse(
            CaretContext.shouldPrependSpace(precedingChar: .known(" "), transcriptFirstChar: nil)
        )
    }

    func testShouldPrependSpace_knownNewline() {
        XCTAssertFalse(
            CaretContext.shouldPrependSpace(precedingChar: .known("\n"), transcriptFirstChar: nil)
        )
    }

    func testShouldPrependSpace_knownOtherPunctuation() {
        XCTAssertFalse(
            CaretContext.shouldPrependSpace(precedingChar: .known(")"), transcriptFirstChar: nil)
        )
    }

    // MARK: - Start of field

    func testShouldPrependSpace_startOfField() {
        XCTAssertFalse(
            CaretContext.shouldPrependSpace(precedingChar: .startOfField, transcriptFirstChar: "h")
        )
        XCTAssertFalse(
            CaretContext.shouldPrependSpace(precedingChar: .startOfField, transcriptFirstChar: nil)
        )
    }

    // MARK: - Unknown (AX fallback)

    func testShouldPrependSpace_unknownAlphanumericTranscript() {
        XCTAssertTrue(
            CaretContext.shouldPrependSpace(precedingChar: .unknown, transcriptFirstChar: "h")
        )
        XCTAssertTrue(
            CaretContext.shouldPrependSpace(precedingChar: .unknown, transcriptFirstChar: "9")
        )
    }

    func testShouldPrependSpace_unknownPunctuationTranscript() {
        XCTAssertFalse(
            CaretContext.shouldPrependSpace(precedingChar: .unknown, transcriptFirstChar: ".")
        )
    }

    func testShouldPrependSpace_unknownWhitespaceTranscript() {
        XCTAssertFalse(
            CaretContext.shouldPrependSpace(precedingChar: .unknown, transcriptFirstChar: " ")
        )
    }

    func testShouldPrependSpace_unknownNilTranscript() {
        XCTAssertFalse(
            CaretContext.shouldPrependSpace(precedingChar: .unknown, transcriptFirstChar: nil)
        )
    }

    // MARK: - Selected range parsing

    func testSelectedTextOffset_nonAXValueReturnsNil() {
        let fakeRange = "not an AXValue" as CFString
        XCTAssertNil(CaretContext.selectedTextOffset(from: fakeRange))
    }
}
