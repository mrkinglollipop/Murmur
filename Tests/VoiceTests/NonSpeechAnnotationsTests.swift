import XCTest
@testable import Voice

final class NonSpeechAnnotationsTests: XCTestCase {

    func testWhisperCaptionCleanupPreservesContentAndCode() {
        XCTAssertEqual(WhisperKitEngine.stripSoundAnnotations("Keep [chapter three] and *important words* intact."),
                       "Keep [chapter three] and *important words* intact.")
        XCTAssertEqual(WhisperKitEngine.stripSoundAnnotations("Use `items[coughing]` and `*sighs*` literally."),
                       "Use `items[coughing]` and `*sighs*` literally.")
        XCTAssertEqual(WhisperKitEngine.stripSoundAnnotations("*sighs* Keep these words [music]."), "Keep these words.")
    }

    func testStripsRecognizedRoundAndSquareCaptions() {
        XCTAssertEqual(
            NonSpeechAnnotations.stripRecognizedTags("Please [sniffs] send (coughing) the report."),
            "Please send the report."
        )
        XCTAssertEqual(
            NonSpeechAnnotations.stripRecognizedTags("[LAUGHS] Start after (clears throat)."),
            "Start after."
        )
    }

    func testStripsOnlyRecognizedLabels() {
        XCTAssertEqual(
            NonSpeechAnnotations.stripRecognizedTags("Keep (for coughing) and [chapter 3] exactly."),
            "Keep (for coughing) and [chapter 3] exactly."
        )
        XCTAssertEqual(
            NonSpeechAnnotations.stripRecognizedTags("Coughing is a word; so is laughter."),
            "Coughing is a word; so is laughter."
        )
    }

    func testPreservesAmbiguousCodeAndNestedAsides() {
        XCTAssertEqual(
            NonSpeechAnnotations.stripRecognizedTags("items[coughing] remains; `items[coughing]` too."),
            "items[coughing] remains; `items[coughing]` too."
        )
        XCTAssertEqual(
            NonSpeechAnnotations.stripRecognizedTags("Run `echo [coughs] now` unchanged."),
            "Run `echo [coughs] now` unchanged."
        )
        XCTAssertEqual(
            NonSpeechAnnotations.stripRecognizedTags("Keep ((coughing)) as a nested aside."),
            "Keep ((coughing)) as a nested aside."
        )
        XCTAssertEqual(
            NonSpeechAnnotations.stripRecognizedTags("Keep (he was (coughing) earlier) intact."),
            "Keep (he was (coughing) earlier) intact."
        )
    }

    func testKeepsParagraphBreaksAndMakesAudioOnlyCaptionEmpty() {
        XCTAssertEqual(
            NonSpeechAnnotations.stripRecognizedTags("First paragraph.\n\nSecond [sighs] paragraph."),
            "First paragraph.\n\nSecond paragraph."
        )
        XCTAssertEqual(NonSpeechAnnotations.stripRecognizedTags("  [breathing]  \n"), "")
    }

    func testPreservesMatchingBacktickSpansAndExitsThemCorrectly() {
        for code in ["``echo [coughs] now``", "```text\nan `example` [coughs] now\n```"] {
            XCTAssertEqual(NonSpeechAnnotations.stripRecognizedTags(code), code)
        }
        XCTAssertEqual(
            NonSpeechAnnotations.stripRecognizedTags("``(open`` [coughs] end."),
            "``(open`` end."
        )
    }

    func testCleansOnlyWhitespaceAdjacentToRemovedCaptionPunctuation() {
        XCTAssertEqual(
            NonSpeechAnnotations.stripRecognizedTags("Hello [coughing] , world."),
            "Hello, world."
        )
        XCTAssertEqual(
            NonSpeechAnnotations.stripRecognizedTags("[sniffles] Hello."),
            "Hello."
        )
    }

    func testPipelinePreprocessUsesSharedSoundTagGuardWithoutCleanup() {
        XCTAssertEqual(
            TranscriptionPipeline.preprocessBeforeCleanup("alpha [coughs] beta", codeAware: false),
            "alpha beta"
        )
    }
}
