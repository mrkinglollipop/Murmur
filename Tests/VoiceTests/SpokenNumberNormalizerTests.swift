import XCTest
@testable import Voice

final class SpokenNumberNormalizerTests: XCTestCase {

    private func n(_ s: String) -> String { SpokenNumberNormalizer.normalize(s) }

    func testRealBatchFallbackExample() {
        XCTAssertEqual(
            n("The effective policy date for Tesla was September twenty-ninth."),
            "The effective policy date for Tesla was September 29th.")
    }

    func testDates() {
        XCTAssertEqual(n("See you March third."), "See you March 3rd.")
        XCTAssertEqual(n("Due May twenty nine."), "Due May 29.")
        XCTAssertEqual(n("It is June first, okay?"), "It is June 1st, okay?")
        XCTAssertEqual(n("On October twenty-second we ship."), "On October 22nd we ship.")
        XCTAssertEqual(n("On the 4th of July"), "On the 4th of July")
    }

    func testDateWithSpokenYear() {
        XCTAssertEqual(n("September twenty-ninth, twenty twenty-six."), "September 29th, 2026.")
        XCTAssertEqual(n("May twenty nine twenty twenty six"), "May 29 2026")
        XCTAssertEqual(n("June third, two thousand twenty-six."), "June 3rd, 2026.")
        XCTAssertEqual(n("July fourth nineteen eighty four"), "July 4th 1984")
        XCTAssertEqual(n("August ninth, twenty oh five"), "August 9th, 2005")
    }

    func testPercentages() {
        XCTAssertEqual(n("It rose zero point eight one percent."), "It rose 0.81%.")
        XCTAssertEqual(n("About fifty percent of them."), "About 50% of them.")
        XCTAssertEqual(n("Up twelve point five percent."), "Up 12.5%.")
        XCTAssertEqual(n("One hundred percent sure."), "100% sure.")
        XCTAssertEqual(n("Five percent."), "5%.")
    }

    func testAHundredPercentIsLeftAlone() {
        // "a hundred" has no leading number word, so the literal rule does not match.
        XCTAssertEqual(n("I'm a hundred percent sure."), "I'm a hundred percent sure.")
    }

    func testMoney() {
        XCTAssertEqual(n("It cost twenty dollars."), "It cost $20.")
        XCTAssertEqual(n("One dollar and fifty cents."), "$1.50.")
        XCTAssertEqual(n("Three dollars and five cents total"), "$3.05 total")
        XCTAssertEqual(n("About one hundred fifty dollars."), "About $150.")
        XCTAssertEqual(n("Two thousand five hundred dollars."), "$2500.")
    }

    func testStandaloneNumbers() {
        XCTAssertEqual(n("We have twenty-nine open items."), "We have 29 open items.")
        XCTAssertEqual(n("About one hundred fifty people came."), "About 150 people came.")
        XCTAssertEqual(n("It was two thousand."), "It was 2000.")
        XCTAssertEqual(n("One hundred and five days."), "105 days.")
        XCTAssertEqual(n("Sixty five."), "65.")
    }

    func testPreservesPunctuationAndCapitalization() {
        XCTAssertEqual(n("Tesla, Inc. paid twenty-nine dollars; Bob agreed."),
                       "Tesla, Inc. paid $29; Bob agreed.")
        XCTAssertEqual(n("\"September twenty-ninth\" it is!"), "\"September 29th\" it is!")
    }

    func testNegativeCasesStayUnchanged() {
        let untouched = [
            "One of them left.",
            "I'll do one.",
            "A couple of options.",
            "One or two things.",
            "Don't second guess it.",
            "First of all, hello.",
            "I'm a hundred percent sure.",
            "Twelve of them came.",
            "We talked for twenty minutes.",
            "Open twenty-four seven.",
            "A one-on-one meeting.",
            "She is a thirty-five-year-old doctor.",
            "Meet me at Twenty One Pilots later.",
            "It was the twenty-first century.",
            "I may two-time it.",
            "We march four miles.",
            "Call five five five.",
            "Already 29 items and 3rd place.",
            "The second of three.",
            "Hundred and fifty is odd.",
        ]
        for sentence in untouched {
            XCTAssertEqual(n(sentence), sentence, sentence)
        }
    }

    func testEmptyAndNumberFreeTextUnchanged() {
        XCTAssertEqual(n(""), "")
        XCTAssertEqual(n(" Hello there.\n"), " Hello there.\n")
    }

    // MARK: - Where it applies

    func testDecimalFragmentsAfterPointAreNeverConverted() {
        XCTAssertEqual(n("It costs one point five dollars."), "It costs one point five dollars.")
        XCTAssertEqual(n("It rose one point twenty five percent."), "It rose one point twenty five percent.")
        XCTAssertEqual(n("Up twelve point five percent."), "Up 12.5%.")
    }

    func testCapitalizedNumberWordsAreAName() {
        XCTAssertEqual(n("Twenty One Pilots released an album."), "Twenty One Pilots released an album.")
        XCTAssertEqual(n("I love Twenty One Pilots."), "I love Twenty One Pilots.")
        XCTAssertEqual(n("Twenty one people came."), "21 people came.")
    }

    func testHundredMultiples() {
        XCTAssertEqual(n("It cost twenty-six hundred dollars."), "It cost $2600.")
        XCTAssertEqual(n("About twenty one hundred people."), "About 2100 people.")
        XCTAssertEqual(n("Two thousand one hundred dollars."), "$2100.")
    }

    func testElevenLabsBatchDecodeDoesNotNormalize() throws {
        let json = #"{"text":"Effective September twenty-ninth."}"#
        XCTAssertEqual(
            try ElevenLabsTranscriptionService.decodeTranscript(from: Data(json.utf8)),
            "Effective September twenty-ninth.")
    }

    @MainActor
    func testPipelineNormalizesOnlyElevenLabsBatchDictation() async {
        let pipeline = TranscriptionPipeline()
        let spelled = "Effective September twenty-ninth, it fell zero point eight one percent."
        let batch = await pipeline.prepareTranscript(
            spelled, holdToken: 0, replaceHistoryEntryID: nil, engineID: "cloud:elevenLabs")
        XCTAssertTrue(batch.text.contains("September 29th"), batch.text)
        XCTAssertTrue(batch.text.contains("0.81%"), batch.text)
        for other in [nil, "cloud:xai", "elevenLabs-stream", "local"] as [String?] {
            let r = await pipeline.prepareTranscript(
                "The date was September twenty-ninth.", holdToken: 0, replaceHistoryEntryID: nil, engineID: other)
            XCTAssertTrue(r.text.contains("twenty-ninth"), "\(other ?? "nil"): \(r.text)")
        }
    }

    @MainActor
    func testVoiceEditInstructionIsNotNormalized() async {
        let pipeline = TranscriptionPipeline()
        let snap = CaretContext.Snapshot(
            value: String(repeating: "a", count: 33), location: 0, selectionLength: .readable(33),
            precedingChar: .startOfField, isUnknown: false,
            focusedElement: AXUIElementCreateApplication(42))
        let token = pipeline.test_holdVoiceEditSnapshot(snap, frontmostPID: 42)
        XCTAssertTrue(pipeline.isVoiceEditHold(token))
        let r = await pipeline.prepareTranscript(
            "Replace 'twenty five' with 'many'.", holdToken: token,
            replaceHistoryEntryID: nil, engineID: "cloud:elevenLabs")
        XCTAssertTrue(r.text.contains("twenty five"), r.text)
        XCTAssertFalse(r.text.contains("25"), r.text)
    }

    func testOtherEnginesAndSharedPipelineAreNotNormalized() throws {
        let spelled = "The date was September twenty-ninth."
        XCTAssertEqual(
            try XAITranscriptionService.decodeTranscript(from: Data(#"{"text":"\#(spelled)"}"#.utf8)),
            spelled)
        // The shared post-processing path (used by streaming text) leaves it alone too.
        XCTAssertEqual(
            TranscriptionPipeline.preprocessBeforeCleanup(spelled, codeAware: false),
            spelled)
    }
}
