import ApplicationServices
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

    func testSelectedTextRange_readableLocationAndLength() {
        var cfRange = CFRange(location: 4, length: 2)
        guard let axValue = AXValueCreate(.cfRange, &cfRange) else {
            XCTFail("AXValueCreate failed")
            return
        }
        let parsed = CaretContext.selectedTextRange(from: axValue)
        XCTAssertEqual(parsed?.location, 4)
        XCTAssertEqual(parsed?.selectionLength, .readable(2))
        XCTAssertEqual(CaretContext.selectedTextOffset(from: axValue), 4)
    }

    func testSelectedTextRange_negativeLengthIsUnreadable() {
        var cfRange = CFRange(location: 1, length: -1)
        guard let axValue = AXValueCreate(.cfRange, &cfRange) else {
            XCTFail("AXValueCreate failed")
            return
        }
        let parsed = CaretContext.selectedTextRange(from: axValue)
        XCTAssertEqual(parsed?.location, 1)
        XCTAssertEqual(parsed?.selectionLength, .unreadable)
    }

    func testSelectedTextRange_kCFNotFoundLengthIsUnreadable() {
        var cfRange = CFRange(location: 2, length: kCFNotFound)
        guard let axValue = AXValueCreate(.cfRange, &cfRange) else {
            XCTFail("AXValueCreate failed")
            return
        }
        let parsed = CaretContext.selectedTextRange(from: axValue)
        XCTAssertEqual(parsed?.location, 2)
        XCTAssertEqual(parsed?.selectionLength, .unreadable)
    }

    func testSelectedTextRange_kCFNotFoundLocationReturnsNil() {
        var cfRange = CFRange(location: kCFNotFound, length: 0)
        guard let axValue = AXValueCreate(.cfRange, &cfRange) else {
            XCTFail("AXValueCreate failed")
            return
        }
        XCTAssertNil(CaretContext.selectedTextRange(from: axValue))
    }

    // MARK: - Preceding grapheme (before selection.location)

    func testPrecedingGrapheme_beforeSelectionStart() {
        // "hello world" — selection at "world" (location 6) → preceding is space
        XCTAssertEqual(
            CaretContext.precedingGrapheme(in: "hello world", beforeUTF16Location: 6),
            .known(" ")
        )
        // Mid-word selection at "llo" (location 2) → preceding is "e"
        XCTAssertEqual(
            CaretContext.precedingGrapheme(in: "hello world", beforeUTF16Location: 2),
            .known("e")
        )
        XCTAssertEqual(
            CaretContext.precedingGrapheme(in: "hello", beforeUTF16Location: 0),
            .startOfField
        )
    }

    // MARK: - Continuing prose

    func testHasContinuingProse_afterSelection() {
        // "The quick brown fox" select "quick" (loc 4, len 5) → space + brown…
        XCTAssertTrue(
            CaretContext.hasContinuingProse(value: "The quick brown fox", selectionLocation: 4, selectionLength: 5)
        )
        // End of field
        XCTAssertFalse(
            CaretContext.hasContinuingProse(value: "The end.", selectionLocation: 4, selectionLength: 4)
        )
        // Only trailing whitespace after selection
        XCTAssertFalse(
            CaretContext.hasContinuingProse(value: "word   ", selectionLocation: 0, selectionLength: 4)
        )
        // Abutted period after selection still counts as continuing
        XCTAssertTrue(
            CaretContext.hasContinuingProse(value: "word.", selectionLocation: 0, selectionLength: 4)
        )
    }

    // MARK: - Transcript-tail rule

    func testTranscriptTail_candidatesAndNegatives() {
        XCTAssertTrue(CaretContext.transcriptHasStrippableTrailingSentencePunctuation("word."))
        XCTAssertTrue(CaretContext.transcriptHasStrippableTrailingSentencePunctuation("word!"))
        XCTAssertTrue(CaretContext.transcriptHasStrippableTrailingSentencePunctuation("word?"))
        XCTAssertTrue(CaretContext.transcriptHasStrippableTrailingSentencePunctuation("word.  "))
        XCTAssertFalse(CaretContext.transcriptHasStrippableTrailingSentencePunctuation("word ."))
        XCTAssertFalse(CaretContext.transcriptHasStrippableTrailingSentencePunctuation("word!!"))
        XCTAssertFalse(CaretContext.transcriptHasStrippableTrailingSentencePunctuation("word..."))
        XCTAssertFalse(CaretContext.transcriptHasStrippableTrailingSentencePunctuation("word?!"))
        XCTAssertFalse(CaretContext.transcriptHasStrippableTrailingSentencePunctuation("word"))
    }

    // MARK: - Abbreviation guard

    func testAbbreviationGuard_multiDotAndShortTitle() {
        // (a) multi-dot / internal-dot — always on for both codeAware values
        for codeAware in [false, true] {
            XCTAssertTrue(
                CaretContext.abbreviationGuardBlocksStrip(transcript: "U.S.", codeAware: codeAware),
                "U.S. codeAware=\(codeAware)"
            )
            XCTAssertTrue(
                CaretContext.abbreviationGuardBlocksStrip(transcript: "e.g.", codeAware: codeAware),
                "e.g. codeAware=\(codeAware)"
            )
            XCTAssertTrue(
                CaretContext.abbreviationGuardBlocksStrip(transcript: "foo.bar.", codeAware: codeAware),
                "foo.bar. codeAware=\(codeAware)"
            )
            XCTAssertTrue(
                CaretContext.abbreviationGuardBlocksStrip(transcript: "example.com.", codeAware: codeAware),
                "example.com. codeAware=\(codeAware)"
            )
            XCTAssertFalse(
                CaretContext.abbreviationGuardBlocksStrip(transcript: "word.", codeAware: codeAware),
                "word. codeAware=\(codeAware)"
            )
        }
        // (b) short titles — always on
        XCTAssertTrue(CaretContext.abbreviationGuardBlocksStrip(transcript: "Dr.", codeAware: false))
        XCTAssertTrue(CaretContext.abbreviationGuardBlocksStrip(transcript: "Mr.", codeAware: false))
        XCTAssertTrue(CaretContext.abbreviationGuardBlocksStrip(transcript: "vs.", codeAware: false))
    }

    // MARK: - shouldStrip matrix

    private func selectReplaceSnapshot(
        value: String = "The quick brown fox.",
        location: Int = 4,
        length: Int = 5,
        preceding: CaretContext.PrecedingChar = .known(" ")
    ) -> CaretContext.Snapshot {
        CaretContext.Snapshot(
            value: value,
            location: location,
            selectionLength: .readable(length),
            precedingChar: preceding,
            isUnknown: false
        )
    }

    func testShouldStrip_selectReplaceWithContinuingProse() {
        let snap = selectReplaceSnapshot()
        XCTAssertTrue(
            CaretContext.shouldStripTrailingSentencePunctuation(
                snapshot: snap,
                transcript: "fast.",
                codeAware: false
            )
        )
        XCTAssertEqual(
            CaretContext.stripTrailingSentencePunctuationIfNeeded(
                snapshot: snap,
                transcript: "fast.",
                codeAware: false
            ),
            "fast"
        )
    }

    func testShouldStrip_exclamationAndQuestion() {
        let snap = selectReplaceSnapshot()
        XCTAssertTrue(
            CaretContext.shouldStripTrailingSentencePunctuation(
                snapshot: snap, transcript: "wow!", codeAware: false
            )
        )
        XCTAssertTrue(
            CaretContext.shouldStripTrailingSentencePunctuation(
                snapshot: snap, transcript: "huh?", codeAware: false
            )
        )
    }

    func testShouldStrip_midCaretNoStrip() {
        let snap = CaretContext.Snapshot(
            value: "The quick brown fox.",
            location: 4,
            selectionLength: .readable(0),
            precedingChar: .known(" "),
            isUnknown: false
        )
        XCTAssertFalse(
            CaretContext.shouldStripTrailingSentencePunctuation(
                snapshot: snap, transcript: "fast.", codeAware: false
            )
        )
    }

    func testShouldStrip_unknownSnapshotNoStrip() {
        XCTAssertFalse(
            CaretContext.shouldStripTrailingSentencePunctuation(
                snapshot: .unknown, transcript: "fast.", codeAware: false
            )
        )
    }

    func testShouldStrip_unreadableLengthNoStrip() {
        let snap = CaretContext.Snapshot(
            value: "The quick brown fox.",
            location: 4,
            selectionLength: .unreadable,
            precedingChar: .known(" "),
            isUnknown: false
        )
        XCTAssertFalse(
            CaretContext.shouldStripTrailingSentencePunctuation(
                snapshot: snap, transcript: "fast.", codeAware: false
            )
        )
    }

    func testShouldStrip_endOfFieldNoStrip() {
        // Select last word with nothing after
        let snap = selectReplaceSnapshot(value: "The end", location: 4, length: 3)
        XCTAssertFalse(
            CaretContext.shouldStripTrailingSentencePunctuation(
                snapshot: snap, transcript: "finish.", codeAware: false
            )
        )
    }

    func testShouldStrip_abuttedPeriodStillStrips() {
        // Prefer strip when continuing starts with `.` (avoid word..)
        let snap = selectReplaceSnapshot(value: "word.more", location: 0, length: 4)
        XCTAssertTrue(
            CaretContext.shouldStripTrailingSentencePunctuation(
                snapshot: snap, transcript: "replacement.", codeAware: false
            )
        )
    }

    func testShouldStrip_abbreviationNoStrip() {
        let snap = selectReplaceSnapshot()
        XCTAssertFalse(
            CaretContext.shouldStripTrailingSentencePunctuation(
                snapshot: snap, transcript: "Dr.", codeAware: false
            )
        )
        XCTAssertFalse(
            CaretContext.shouldStripTrailingSentencePunctuation(
                snapshot: snap, transcript: "U.S.", codeAware: false
            )
        )
    }

    func testShouldStrip_transcriptTailNegatives() {
        let snap = selectReplaceSnapshot()
        for transcript in ["word .", "word!!", "word...", "word?!"] {
            XCTAssertFalse(
                CaretContext.shouldStripTrailingSentencePunctuation(
                    snapshot: snap, transcript: transcript, codeAware: false
                ),
                "Expected no strip for \(transcript)"
            )
        }
    }

    func testShouldStrip_onlyPunctuationNoStrip() {
        let snap = selectReplaceSnapshot()
        XCTAssertFalse(
            CaretContext.shouldStripTrailingSentencePunctuation(
                snapshot: snap, transcript: ".", codeAware: false
            )
        )
    }
}

// MARK: - Inject transform seam

final class InjectTransformSeamTests: XCTestCase {

    private func selectReplaceSnapshot(
        preceding: CaretContext.PrecedingChar = .known("e")
    ) -> CaretContext.Snapshot {
        // "The quick brown" — select "quick" after "e "
        CaretContext.Snapshot(
            value: "The quick brown",
            location: 4,
            selectionLength: .readable(5),
            precedingChar: preceding,
            isUnknown: false
        )
    }

    func testApplyInjectTransforms_toggleOffNoStripNoSpace() {
        let snap = selectReplaceSnapshot(preceding: .known("e"))
        let out = TranscriptionPipeline.applyInjectTransforms(
            expanded: "fast.",
            snapshot: snap,
            secureInput: false,
            smartLeadingSpaceEnabled: false,
            codeAware: false
        )
        XCTAssertEqual(out, "fast.")
    }

    func testApplyInjectTransforms_secureInputNoStripNoSpace() {
        let snap = selectReplaceSnapshot(preceding: .known("e"))
        let out = TranscriptionPipeline.applyInjectTransforms(
            expanded: "fast.",
            snapshot: snap,
            secureInput: true,
            smartLeadingSpaceEnabled: true,
            codeAware: false
        )
        XCTAssertEqual(out, "fast.")
    }

    func testApplyInjectTransforms_singleSnapshotStripAndLeadingSpace() {
        // Preceding "e" (letter) → leading space; select-replace + continuing → strip `.`
        let snap = selectReplaceSnapshot(preceding: .known("e"))
        let out = TranscriptionPipeline.applyInjectTransforms(
            expanded: "fast.",
            snapshot: snap,
            secureInput: false,
            smartLeadingSpaceEnabled: true,
            codeAware: false
        )
        XCTAssertEqual(out, " fast")
    }

    func testApplyInjectTransforms_stripOnlyWhenPrecedingIsWhitespace() {
        let snap = selectReplaceSnapshot(preceding: .known(" "))
        let out = TranscriptionPipeline.applyInjectTransforms(
            expanded: "fast.",
            snapshot: snap,
            secureInput: false,
            smartLeadingSpaceEnabled: true,
            codeAware: false
        )
        XCTAssertEqual(out, "fast")
    }

    func testApplyInjectTransforms_historyIntentIsPostStripText() {
        // Documents that callers should log the seam return value (textToInject).
        let snap = selectReplaceSnapshot(preceding: .known(" "))
        let textToInject = TranscriptionPipeline.applyInjectTransforms(
            expanded: "fast.",
            snapshot: snap,
            secureInput: false,
            smartLeadingSpaceEnabled: true,
            codeAware: false
        )
        XCTAssertEqual(textToInject, "fast")
        XCTAssertNotEqual(textToInject, "fast.")
    }
}
