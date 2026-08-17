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

    func testForcedTypoAndSafeReplaceHelpers() {
        XCTAssertEqual(AutocorrectEngine.forcedTypo("teh"), "the")
        XCTAssertEqual(AutocorrectEngine.forcedTypo("Teh"), "The")
        XCTAssertNil(AutocorrectEngine.forcedTypo("hello"))
        XCTAssertTrue(AutocorrectEngine.canReplaceSpan("wor", inBeforeInput: "hello wor"))
        XCTAssertFalse(AutocorrectEngine.canReplaceSpan("wor", inBeforeInput: "hello"))
        XCTAssertFalse(AutocorrectEngine.canReplaceSpan("", inBeforeInput: "hello"))
        XCTAssertTrue(AutocorrectEngine.canReplaceSpan("you ", inBeforeInput: "hello you "))
        XCTAssertFalse(
            AutocorrectEngine.canReplaceSpan("hello how are you", inBeforeInput: "hello how are you")
        )
        XCTAssertEqual(
            AutocorrectEngine.allowedDeleteCount(span: "wor", inBeforeInput: "hello wor"),
            3
        )
        XCTAssertEqual(
            AutocorrectEngine.allowedDeleteCount(span: "you ", inBeforeInput: "hello you "),
            4
        )
        XCTAssertEqual(
            AutocorrectEngine.allowedDeleteCount(
                span: "hellohowareyou",
                inBeforeInput: "hellohowareyou"
            ),
            0,
            "hosts that strip spaces must not look like one giant word"
        )
        XCTAssertEqual(
            AutocorrectEngine.wordSpan(beforeInput: "hellohowareyou"),
            "hellohowareyou"
        )
        XCTAssertEqual(
            AutocorrectEngine.allowedDeleteCount(span: "the", inBeforeInput: "the"),
            3
        )
        XCTAssertTrue(AutocorrectEngine.shouldAbortDeleteLoop(beforeCount: 17, afterCount: 3))
        XCTAssertTrue(AutocorrectEngine.shouldAbortDeleteLoop(beforeCount: 5, afterCount: 5))
        XCTAssertFalse(AutocorrectEngine.shouldAbortDeleteLoop(beforeCount: 5, afterCount: 4))
        XCTAssertEqual(
            AutocorrectEngine.allowedDeleteCount(span: "congratulations", inBeforeInput: "congratulations"),
            0
        )
        XCTAssertTrue(AutocorrectEngine.shouldReplaceDoubleSpaceWithPeriod(beforeInput: "you "))
        XCTAssertFalse(AutocorrectEngine.shouldReplaceDoubleSpaceWithPeriod(beforeInput: "you  "))
        XCTAssertFalse(AutocorrectEngine.shouldReplaceDoubleSpaceWithPeriod(beforeInput: "you"))
        XCTAssertFalse(AutocorrectEngine.shouldReplaceDoubleSpaceWithPeriod(beforeInput: "you. "))
        XCTAssertFalse(AutocorrectEngine.shouldReplaceDoubleSpaceWithPeriod(beforeInput: " "))
        XCTAssertEqual(AutocorrectEngine.damerauLevenshtein("hte", "the"), 1)
        XCTAssertEqual(AutocorrectEngine.damerauLevenshtein("recieve", "receive"), 1)
        XCTAssertGreaterThan(AutocorrectEngine.damerauLevenshtein("hello", "world"), 1)
        XCTAssertTrue(
            AutocorrectEngine.shouldForceSpelling(
                span: "hellp",
                guess: "hello",
                frequencyOrder: ["the", "hello", "help"],
                names: []
            )
        )
        XCTAssertFalse(
            AutocorrectEngine.shouldForceSpelling(
                span: "matt",
                guess: "mat",
                frequencyOrder: ["the", "mat", "matt"],
                names: ["matt"]
            )
        )
        XCTAssertFalse(
            AutocorrectEngine.shouldForceSpelling(
                span: "xyzzy",
                guess: "dizzy",
                frequencyOrder: ["the", "dizzy"],
                names: []
            )
        )
    }

    func testTypingDoesNotForceValidWordsOrFuzzyGuesses() {
        let controller = AutocorrectController()
        XCTAssertEqual(controller.correction(for: "teh"), "the")
        XCTAssertEqual(controller.correction(for: "dont"), "don't")
        XCTAssertEqual(controller.correction(for: "i"), "I")
        XCTAssertEqual(controller.correction(for: "hethe"), "he the")
        XCTAssertNil(controller.correction(for: "together"))
        XCTAssertNil(controller.correction(for: "therapist"))
        XCTAssertNil(controller.correction(for: "matt"))
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
