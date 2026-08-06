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

    func testShouldPrependSpace_unknownNeverPrepends() {
        // Prefer no glue-fix over double-space when AX-blind.
        XCTAssertFalse(
            CaretContext.shouldPrependSpace(precedingChar: .unknown, transcriptFirstChar: "h")
        )
        XCTAssertFalse(
            CaretContext.shouldPrependSpace(precedingChar: .unknown, transcriptFirstChar: "9")
        )
        XCTAssertFalse(
            CaretContext.shouldPrependSpace(precedingChar: .unknown, transcriptFirstChar: ".")
        )
        XCTAssertFalse(
            CaretContext.shouldPrependSpace(precedingChar: .unknown, transcriptFirstChar: " ")
        )
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

    // MARK: - Mid-sentence select-replace + decap

    func testIsMidSentenceSelectReplace_gates() {
        XCTAssertTrue(CaretContext.isMidSentenceSelectReplace(snapshot: selectReplaceSnapshot()))
        XCTAssertFalse(CaretContext.isMidSentenceSelectReplace(snapshot: .unknown))
        let midCaret = CaretContext.Snapshot(
            value: "The quick brown fox.",
            location: 4,
            selectionLength: .readable(0),
            precedingChar: .known(" "),
            isUnknown: false
        )
        XCTAssertFalse(CaretContext.isMidSentenceSelectReplace(snapshot: midCaret))
        let endField = selectReplaceSnapshot(value: "The end", location: 4, length: 3)
        XCTAssertFalse(CaretContext.isMidSentenceSelectReplace(snapshot: endField))
    }

    func testDecapitalize_titleCaseMidSentence() {
        let snap = selectReplaceSnapshot()
        XCTAssertEqual(
            CaretContext.decapitalizeFirstTokenIfNeeded(
                snapshot: snap,
                transcript: "Fast.",
                capitalizedDictionaryTerms: []
            ),
            "fast."
        )
    }

    func testDecapitalize_keepsAllowlistRussia() {
        let snap = selectReplaceSnapshot()
        XCTAssertEqual(
            CaretContext.decapitalizeFirstTokenIfNeeded(
                snapshot: snap,
                transcript: "Russia",
                capitalizedDictionaryTerms: []
            ),
            "Russia"
        )
    }

    func testDecapitalize_keepsIAndNASA() {
        let snap = selectReplaceSnapshot()
        XCTAssertEqual(
            CaretContext.decapitalizeFirstTokenIfNeeded(
                snapshot: snap, transcript: "I", capitalizedDictionaryTerms: []
            ),
            "I"
        )
        XCTAssertEqual(
            CaretContext.decapitalizeFirstTokenIfNeeded(
                snapshot: snap, transcript: "NASA", capitalizedDictionaryTerms: []
            ),
            "NASA"
        )
    }

    func testDecapitalize_keepsInjectedDictionaryTerm() {
        let snap = selectReplaceSnapshot()
        XCTAssertEqual(
            CaretContext.decapitalizeFirstTokenIfNeeded(
                snapshot: snap,
                transcript: "Murmur",
                capitalizedDictionaryTerms: ["Murmur"]
            ),
            "Murmur"
        )
        XCTAssertEqual(
            CaretContext.decapitalizeFirstTokenIfNeeded(
                snapshot: snap,
                transcript: "Murmur",
                capitalizedDictionaryTerms: []
            ),
            "murmur"
        )
    }

    // MARK: - resolveInjectSnapshot

    func testResolveInjectSnapshot_heldWinsWhenReadableSelection() {
        let held = selectReplaceSnapshot()
        let fresh = CaretContext.Snapshot.unknown
        let resolved = CaretContext.resolveInjectSnapshot(
            held: held,
            fresh: fresh,
            replaceHistoryEntryID: nil
        )
        XCTAssertEqual(resolved, held)
    }

    func testResolveInjectSnapshot_heldRejectedWhenUnknownOrZeroLength() {
        let fresh = selectReplaceSnapshot(value: "fresh", location: 0, length: 2)
        XCTAssertEqual(
            CaretContext.resolveInjectSnapshot(
                held: .unknown, fresh: fresh, replaceHistoryEntryID: nil
            ),
            fresh
        )
        let zeroLen = CaretContext.Snapshot(
            value: "abc",
            location: 1,
            selectionLength: .readable(0),
            precedingChar: .known("a"),
            isUnknown: false
        )
        XCTAssertEqual(
            CaretContext.resolveInjectSnapshot(
                held: zeroLen, fresh: fresh, replaceHistoryEntryID: nil
            ),
            fresh
        )
        XCTAssertEqual(
            CaretContext.resolveInjectSnapshot(
                held: nil, fresh: fresh, replaceHistoryEntryID: nil
            ),
            fresh
        )
    }

    func testResolveInjectSnapshot_historyRetryIgnoresHeld() {
        let held = selectReplaceSnapshot()
        let fresh = CaretContext.Snapshot(
            value: "retry field",
            location: 0,
            selectionLength: .readable(3),
            precedingChar: .startOfField,
            isUnknown: false
        )
        let resolved = CaretContext.resolveInjectSnapshot(
            held: held,
            fresh: fresh,
            replaceHistoryEntryID: UUID()
        )
        XCTAssertEqual(resolved, fresh)
    }

    func testResolveInjectSnapshot_heldUnreadableFallsToFresh() {
        let held = CaretContext.Snapshot(
            value: "abc",
            location: 1,
            selectionLength: .unreadable,
            precedingChar: .known("a"),
            isUnknown: false
        )
        let fresh = selectReplaceSnapshot(value: "fresh", location: 0, length: 2)
        XCTAssertEqual(
            CaretContext.resolveInjectSnapshot(
                held: held, fresh: fresh, replaceHistoryEntryID: nil
            ),
            fresh
        )
    }
}

// MARK: - Held caret lifecycle (token-scoped)

final class HeldCaretLifecycleTests: XCTestCase {

    private func selectReplaceSnapshot() -> CaretContext.Snapshot {
        CaretContext.Snapshot(
            value: "The quick brown fox.",
            location: 4,
            selectionLength: .readable(5),
            precedingChar: .known(" "),
            isUnknown: false
        )
    }

    func testHoldThenClearLeavesNil() {
        let pipeline = TranscriptionPipeline()
        let token = pipeline.test_holdSnapshot(selectReplaceSnapshot())
        XCTAssertNotNil(pipeline.test_heldCaretSnapshot)
        XCTAssertEqual(pipeline.test_heldCaretToken, token)
        pipeline.clearHeldCaretSnapshot(matching: token)
        XCTAssertNil(pipeline.test_heldCaretSnapshot)
    }

    func testClearAfterHoldResolveFallsToFresh() {
        let pipeline = TranscriptionPipeline()
        let held = selectReplaceSnapshot()
        let token = pipeline.test_holdSnapshot(held)
        pipeline.clearHeldCaretSnapshot(matching: token)
        let fresh = CaretContext.Snapshot(
            value: "fresh",
            location: 0,
            selectionLength: .readable(2),
            precedingChar: .startOfField,
            isUnknown: false
        )
        let resolved = CaretContext.resolveInjectSnapshot(
            held: pipeline.test_heldCaretSnapshot,
            fresh: fresh,
            replaceHistoryEntryID: nil
        )
        XCTAssertEqual(resolved, fresh)
    }

    func testOverlappingHoldFinishADoesNotClearB() {
        let pipeline = TranscriptionPipeline()
        let snapA = selectReplaceSnapshot()
        let tokenA = pipeline.test_holdSnapshot(snapA)
        let snapB = CaretContext.Snapshot(
            value: "session B field",
            location: 0,
            selectionLength: .readable(4),
            precedingChar: .startOfField,
            isUnknown: false
        )
        let tokenB = pipeline.test_holdSnapshot(snapB)
        XCTAssertNotEqual(tokenA, tokenB)
        XCTAssertEqual(pipeline.test_heldCaretSnapshot, snapB)

        // Finish A clears matching A's token — must not wipe B.
        pipeline.clearHeldCaretSnapshot(matching: tokenA)
        XCTAssertEqual(pipeline.test_heldCaretToken, tokenB)
        XCTAssertEqual(pipeline.test_heldCaretSnapshot, snapB)

        pipeline.clearHeldCaretSnapshot(matching: tokenB)
        XCTAssertNil(pipeline.test_heldCaretSnapshot)
    }

    func testASREngineSelectorForwardsHoldClear() {
        let selector = ASREngineSelector()
        let token = selector.test_holdSnapshot(selectReplaceSnapshot())
        XCTAssertNotNil(selector.test_heldCaretSnapshot)
        selector.clearHeldCaretSnapshot(matching: token)
        XCTAssertNil(selector.test_heldCaretSnapshot)
    }

    /// Documents the API footgun AudioRecorder must not use on teardown:
    /// `matching: nil` (default) clears unconditionally and wipes a newer hold.
    func testUnscopedClearWipesNewerHold() {
        let pipeline = TranscriptionPipeline()
        let tokenA = pipeline.test_holdSnapshot(selectReplaceSnapshot())
        let snapB = CaretContext.Snapshot(
            value: "session B field",
            location: 0,
            selectionLength: .readable(4),
            precedingChar: .startOfField,
            isUnknown: false
        )
        let tokenB = pipeline.test_holdSnapshot(snapB)
        XCTAssertNotEqual(tokenA, tokenB)

        pipeline.clearHeldCaretSnapshot(matching: nil)
        XCTAssertNil(pipeline.test_heldCaretSnapshot)
        // Token number is unchanged by clear — only the snapshot is dropped.
        XCTAssertEqual(pipeline.test_heldCaretToken, tokenB)
    }

    /// AudioRecorder teardown policy: prefer active, else pending — never
    /// imply an unscoped clear when both are nil.
    func testAudioRecorderTeardownClearTokenPrefersActive() {
        XCTAssertEqual(
            AudioRecorder.teardownHeldCaretClearToken(active: 7, pending: 3),
            7
        )
        XCTAssertEqual(
            AudioRecorder.teardownHeldCaretClearToken(active: nil, pending: 3),
            3
        )
        XCTAssertNil(
            AudioRecorder.teardownHeldCaretClearToken(active: nil, pending: nil)
        )
    }

    /// WhisperKit stream-start promote then async fallback re-promote with
    /// nil pending must leave the already-active token intact.
    func testPromotePendingHeldCaretIsIdempotentWhenPendingNil() {
        let first = AudioRecorder.heldCaretTokensAfterPromote(
            active: nil,
            pending: 11
        )
        XCTAssertEqual(first.active, 11)
        XCTAssertNil(first.pending)

        let fallback = AudioRecorder.heldCaretTokensAfterPromote(
            active: first.active,
            pending: nil
        )
        XCTAssertEqual(fallback.active, 11)
        XCTAssertNil(fallback.pending)
    }

    /// Mimics older-session matched teardown after a newer hold promoted:
    /// clear(matching: old) must leave the newer snapshot intact.
    func testMatchedTeardownOfOlderSessionLeavesNewerHeld() {
        let pipeline = TranscriptionPipeline()
        let tokenOld = pipeline.test_holdSnapshot(selectReplaceSnapshot())
        let snapNew = CaretContext.Snapshot(
            value: "newer hold",
            location: 1,
            selectionLength: .readable(0),
            precedingChar: .known("a"),
            isUnknown: false
        )
        let tokenNew = pipeline.test_holdSnapshot(snapNew)

        // AudioRecorder would call clear(matching: activeHeldCaretToken) with
        // the older session's captured token — same as pipeline matching API.
        let teardownToken = AudioRecorder.teardownHeldCaretClearToken(
            active: tokenOld,
            pending: nil
        )
        XCTAssertEqual(teardownToken, tokenOld)
        pipeline.clearHeldCaretSnapshot(matching: teardownToken)
        XCTAssertEqual(pipeline.test_heldCaretToken, tokenNew)
        XCTAssertEqual(pipeline.test_heldCaretSnapshot, snapNew)
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
            codeAware: false,
            accessibilityTrusted: true
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
            codeAware: false,
            accessibilityTrusted: true
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
            codeAware: false,
            accessibilityTrusted: true
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
            codeAware: false,
            accessibilityTrusted: true
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
            codeAware: false,
            accessibilityTrusted: true
        )
        XCTAssertEqual(textToInject, "fast")
        XCTAssertNotEqual(textToInject, "fast.")
    }

    func testApplyInjectTransforms_decapAndStripWithDictionaryKeep() {
        let snap = selectReplaceSnapshot(preceding: .known(" "))
        let out = TranscriptionPipeline.applyInjectTransforms(
            expanded: "Fast.",
            snapshot: snap,
            secureInput: false,
            smartLeadingSpaceEnabled: true,
            codeAware: false,
            capitalizedDictionaryTerms: [],
            accessibilityTrusted: true
        )
        XCTAssertEqual(out, "fast")

        let kept = TranscriptionPipeline.applyInjectTransforms(
            expanded: "Murmur.",
            snapshot: snap,
            secureInput: false,
            smartLeadingSpaceEnabled: true,
            codeAware: false,
            capitalizedDictionaryTerms: ["Murmur"],
            accessibilityTrusted: true
        )
        XCTAssertEqual(kept, "Murmur")
    }

    func testApplyInjectTransforms_untrustedSkipsStripAndDecapKeepsSpace() {
        let snap = selectReplaceSnapshot(preceding: .known("e"))
        let out = TranscriptionPipeline.applyInjectTransforms(
            expanded: "Fast.",
            snapshot: snap,
            secureInput: false,
            smartLeadingSpaceEnabled: true,
            codeAware: false,
            accessibilityTrusted: false
        )
        // Fail-open: keep period + Title Case; leading space still runs.
        XCTAssertEqual(out, " Fast.")
    }

    func testApplyInjectTransforms_unknownSnapshotNoLeadingSpace() {
        let out = TranscriptionPipeline.applyInjectTransforms(
            expanded: "hello",
            snapshot: .unknown,
            secureInput: false,
            smartLeadingSpaceEnabled: true,
            codeAware: false,
            accessibilityTrusted: true
        )
        XCTAssertEqual(out, "hello")
    }
}

// MARK: - Code-aware preprocess gate (independent of Cleanup)

final class CodeAwarePreprocessGateTests: XCTestCase {

    func testSpokenPunctuationRunsWhenCodeAwareRegardlessOfCleanup() {
        // preprocessBeforeCleanup is the gate before optional LLM cleanup —
        // codeAware alone must join spoken "period"/"dot".
        let out = TranscriptionPipeline.preprocessBeforeCleanup(
            "SettingsStore period swift",
            codeAware: true
        )
        XCTAssertEqual(out, "SettingsStore.swift")
    }

    func testSpokenPunctuationSkippedWhenCodeAwareOff() {
        let out = TranscriptionPipeline.preprocessBeforeCleanup(
            "SettingsStore period swift",
            codeAware: false
        )
        XCTAssertEqual(out, "SettingsStore period swift")
    }
}
