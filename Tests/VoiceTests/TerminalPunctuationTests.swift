import XCTest
@testable import Voice

final class TerminalPunctuationTests: XCTestCase {
    private let unknown = CaretContext.Snapshot.unknown

    private func snapshot(_ value: String, location: Int, selectionLength: Int = 0) -> CaretContext.Snapshot {
        CaretContext.Snapshot(
            value: value,
            location: location,
            selectionLength: .readable(selectionLength),
            precedingChar: .startOfField,
            isUnknown: false
        )
    }

    private func prepare(
        _ text: String,
        snapshot: CaretContext.Snapshot? = nil,
        codeAware: Bool = false,
        transform: Bool = false,
        snippet: Bool = false,
        trailingNewline: Bool = false
    ) -> String {
        TranscriptionPipeline.prepareResolvedSnapshotTextForInjection(
            expanded: text,
            snapshot: snapshot ?? unknown,
            codeAware: codeAware,
            hasExplicitCustomTransform: transform,
            snippetExpansionOccurred: snippet,
            hadExplicitTrailingNewline: trailingNewline
        )
    }

    func testReportedElevenLabsBatchTakesReceiveTerminalPeriods() {
        XCTAssertEqual(
            prepare("Like that dictation right there and probably this one too"),
            "Like that dictation right there and probably this one too."
        )
        XCTAssertEqual(
            prepare("Another issue I'm noticing is that it's not adding a period frequently when it should be"),
            "Another issue I'm noticing is that it's not adding a period frequently when it should be."
        )
    }

    func testReportedPhrasesKeepPeriodThroughActualInjectTransformOrder() {
        let phrases = [
            "Like that dictation right there and probably this one too",
            "Another issue I'm noticing is that it's not adding a period frequently when it should be",
        ]
        for phrase in phrases {
            let preprocessed = TranscriptionPipeline.preprocessBeforeCleanup(phrase, codeAware: false)
            let prepared = prepare(preprocessed)
            XCTAssertEqual(
                TranscriptionPipeline.applyInjectTransforms(
                    expanded: prepared, snapshot: unknown, secureInput: false,
                    smartLeadingSpaceEnabled: false, codeAware: false, accessibilityTrusted: false
                ),
                phrase + "."
            )
            XCTAssertEqual(
                TranscriptionPipeline.applyInjectTransforms(
                    expanded: prepared, snapshot: unknown, secureInput: false,
                    smartLeadingSpaceEnabled: true, codeAware: false, accessibilityTrusted: false
                ),
                " " + phrase + "."
            )
        }
    }

    func testUnknownAXAndKnownEndOfFieldUseTheSameSharedPolicy() {
        let text = "This ordinary shared pipeline output needs a period"
        XCTAssertEqual(prepare(text), text + ".")
        XCTAssertEqual(
            prepare(text, snapshot: snapshot("replace me", location: 0, selectionLength: 10)),
            text + "."
        )
    }

    func testDoesNotAddBeforeExistingTextForInsertionOrSelectionReplace() {
        let text = "This ordinary dictated phrase needs a period"
        XCTAssertEqual(prepare(text, snapshot: snapshot("before after", location: 3)), text)
        XCTAssertEqual(prepare(text, snapshot: snapshot("before selected after", location: 7, selectionLength: 8)), text)
        XCTAssertEqual(prepare(text, snapshot: snapshot("before .", location: 7)), text)
    }

    func testEndOfFieldAndUnicodeUTF16RangesAreEligible() {
        let text = "This ordinary unicode sentence needs a period"
        let field = "🙂 " + text
        XCTAssertEqual(prepare(text, snapshot: snapshot(field, location: field.utf16.count)), text + ".")
        XCTAssertEqual(
            prepare(text, snapshot: snapshot("old", location: 0, selectionLength: 3)),
            text + "."
        )
    }

    func testGuardsCodeSnippetsTransformsAndFormatting() {
        let text = "This ordinary dictated phrase needs a period"
        XCTAssertEqual(prepare(text, codeAware: true), text)
        XCTAssertEqual(prepare(text, transform: true), text)
        XCTAssertEqual(prepare(text, snippet: true), text)
        XCTAssertEqual(prepare("run ./script now please carefully"), "run ./script now please carefully")
        XCTAssertEqual(prepare("These are all my reasons:"), "These are all my reasons:")
        XCTAssertEqual(prepare("This call uses doThing()"), "This call uses doThing()")
        XCTAssertEqual(prepare("Please visit the site example.com"), "Please visit the site example.com")
        XCTAssertEqual(prepare("# This ordinary heading needs a period"), "# This ordinary heading needs a period")
        XCTAssertEqual(prepare("This ordinary line has a spoken new line", trailingNewline: true), "This ordinary line has a spoken new line")
    }

    func testPreservesEmptyFragmentsAndExistingTerminalForms() {
        XCTAssertEqual(prepare(""), "")
        XCTAssertEqual(prepare("just a short fragment"), "just a short fragment")
        XCTAssertEqual(prepare("This ordinary sentence already has a period."), "This ordinary sentence already has a period.")
        XCTAssertEqual(prepare("This ordinary question already ends here?"), "This ordinary question already ends here?")
        XCTAssertEqual(prepare("This ordinary quote remains quoted here\""), "This ordinary quote remains quoted here\"")
        XCTAssertEqual(prepare("This ordinary thought trails off now…"), "This ordinary thought trails off now…")
    }

    func testInvalidOrSurrogateSplittingAXRangesAreRefused() {
        let text = "This ordinary dictated phrase needs a period"
        XCTAssertEqual(prepare(text, snapshot: snapshot("field", location: -1)), text)
        XCTAssertEqual(prepare(text, snapshot: snapshot("field", location: 2, selectionLength: -1)), text)
        XCTAssertEqual(prepare(text, snapshot: snapshot("field", location: 4, selectionLength: 2)), text)
        XCTAssertEqual(prepare(text, snapshot: snapshot("🙂", location: 1)), text)
        XCTAssertEqual(prepare(text, snapshot: snapshot("🙂", location: 0, selectionLength: 1)), text)
    }
}
