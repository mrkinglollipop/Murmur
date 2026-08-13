import XCTest

final class AutocorrectControllerTests: XCTestCase {
    func testProductionFrequencyListForcesHetheAndImgoing() {
        XCTAssertFalse(FrequencyList.words.isEmpty, "en-US lists must be in the test bundle")
        XCTAssertFalse(FrequencyList.frequencyOrder.isEmpty)
        XCTAssertGreaterThan(FrequencyList.words.count, FrequencyList.frequencyOrder.count)
        let theMerged = FrequencyList.words.firstIndex(of: "the") ?? 0
        XCTAssertGreaterThan(theMerged, 500, "names prefix must still be present on words")
        XCTAssertEqual(FrequencyList.frequencyOrder.first, "the")
        XCTAssertTrue(FrequencyList.frequencyOrder.contains("going"))

        XCTAssertEqual(
            AutocorrectEngine.forcedSplit(
                "hethe",
                known: FrequencyList.words,
                frequencyOrder: FrequencyList.frequencyOrder
            ),
            "he the"
        )
        XCTAssertEqual(
            AutocorrectEngine.forcedSplit(
                "hethere",
                known: FrequencyList.words,
                frequencyOrder: FrequencyList.frequencyOrder
            ),
            "he there"
        )
        XCTAssertNil(
            AutocorrectEngine.forcedSplit(
                "together",
                known: FrequencyList.words,
                frequencyOrder: FrequencyList.frequencyOrder
            )
        )
        XCTAssertEqual(
            AutocorrectEngine.forcedSplit(
                "imgoing",
                known: FrequencyList.words,
                frequencyOrder: FrequencyList.frequencyOrder
            ),
            "I'm going"
        )
    }

    func testNewLetterSpanClearsSuppressSoPronounICanFire() {
        let controller = AutocorrectController()
        controller.suppressUntilWhitespace = true
        XCTAssertNil(
            controller.correction(for: "i"),
            "trailing commit after swipe/dictation must not respell that token"
        )
        controller.noteIncomingText("i")
        XCTAssertFalse(controller.suppressUntilWhitespace)
        XCTAssertEqual(controller.correction(for: "i"), "I")
    }

    func testSuppressStillBlocksFuzzyGuessUntilNewSpan() {
        let controller = AutocorrectController()
        controller.suppressUntilWhitespace = true
        XCTAssertNil(controller.correction(for: "teh"))
        controller.noteIncomingText(" ")
        XCTAssertTrue(controller.suppressUntilWhitespace)
        XCTAssertNil(controller.correction(for: "teh"))
    }
}
