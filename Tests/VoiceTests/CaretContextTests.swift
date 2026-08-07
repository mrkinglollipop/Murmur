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

    func testShouldPrependSpace_unknownPrecedingCharAloneNeverPrepends() {
        // PrecedingChar.unknown (non-wholesale) still prefers no glue-fix.
        XCTAssertFalse(
            CaretContext.shouldPrependSpace(precedingChar: .unknown, transcriptFirstChar: "h")
        )
    }

    func testShouldPrependSpace_wholesaleUnknownAlphanumericPrepends() {
        XCTAssertTrue(
            CaretContext.shouldPrependSpace(snapshot: .unknown, transcriptFirstChar: "h")
        )
        XCTAssertTrue(
            CaretContext.shouldPrependSpace(snapshot: .unknown, transcriptFirstChar: "9")
        )
        XCTAssertFalse(
            CaretContext.shouldPrependSpace(snapshot: .unknown, transcriptFirstChar: ".")
        )
        XCTAssertFalse(
            CaretContext.shouldPrependSpace(snapshot: .unknown, transcriptFirstChar: " ")
        )
        XCTAssertFalse(
            CaretContext.shouldPrependSpace(snapshot: .unknown, transcriptFirstChar: nil)
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
        let token = pipeline.test_holdSnapshot(selectReplaceSnapshot(), frontmostPID: 4242)
        XCTAssertNotNil(pipeline.test_heldCaretSnapshot)
        XCTAssertEqual(pipeline.test_heldCaretToken, token)
        XCTAssertEqual(pipeline.test_heldFrontmostPID, 4242)
        pipeline.clearHeldCaretSnapshot(matching: token)
        XCTAssertNil(pipeline.test_heldCaretSnapshot)
        XCTAssertNil(pipeline.test_heldFrontmostPID)
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
    /// When active and pending differ, teardown prefers pending (newer
    /// session). Single-slot / nil cases still resolve that token.
    func testAudioRecorderTeardownClearTokenPrefersPendingWhenBothDiffer() {
        XCTAssertEqual(
            AudioRecorder.teardownHeldCaretClearToken(active: 7, pending: 3),
            3
        )
        XCTAssertEqual(
            AudioRecorder.teardownHeldCaretClearToken(active: nil, pending: 3),
            3
        )
        XCTAssertEqual(
            AudioRecorder.teardownHeldCaretClearToken(active: 7, pending: nil),
            7
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

    /// Stop-sampled session hold must win over a later `test_holdSnapshot`
    /// (simulates async IO/finalize gap before `transcribeAndLog` entry).
    func testExplicitSessionHoldIgnoresLaterHold() {
        let pipeline = TranscriptionPipeline()
        let snapA = selectReplaceSnapshot()
        let tokenA = pipeline.test_holdSnapshot(snapA, frontmostPID: 111)
        let snapB = CaretContext.Snapshot(
            value: "poison hold from re-press",
            location: 0,
            selectionLength: .readable(0),
            precedingChar: .startOfField,
            isUnknown: false
        )
        let tokenB = pipeline.test_holdSnapshot(snapB, frontmostPID: 222)
        XCTAssertNotEqual(tokenA, tokenB)

        let resolved = TranscriptionPipeline.resolveSessionHold(
            providedToken: tokenA,
            providedSnapshot: snapA,
            providedPID: 111,
            currentToken: pipeline.test_heldCaretToken,
            currentSnapshot: pipeline.test_heldCaretSnapshot,
            currentPID: pipeline.test_heldFrontmostPID
        )
        XCTAssertEqual(resolved.token, tokenA)
        XCTAssertEqual(resolved.snapshot, snapA)
        XCTAssertEqual(resolved.pid, 111)

        // Nil provided → entry sample sees the newer hold (history-retry path).
        let entrySampled = TranscriptionPipeline.resolveSessionHold(
            providedToken: nil,
            providedSnapshot: nil,
            providedPID: nil,
            currentToken: pipeline.test_heldCaretToken,
            currentSnapshot: pipeline.test_heldCaretSnapshot,
            currentPID: pipeline.test_heldFrontmostPID
        )
        XCTAssertEqual(entrySampled.token, tokenB)
        XCTAssertEqual(entrySampled.snapshot, snapB)
        XCTAssertEqual(entrySampled.pid, 222)

        // copyHeldCaretMatching only succeeds for the current owner.
        let stale = pipeline.copyHeldCaretMatching(tokenA)
        XCTAssertNil(stale.0)
        XCTAssertNil(stale.1)
        let live = pipeline.copyHeldCaretMatching(tokenB)
        XCTAssertEqual(live.0, snapB)
        XCTAssertEqual(live.1, 222)
    }

    /// AudioRecorder session cache must still return hold A's snapshot/PID
    /// after a later hold steals the live pipeline slot (copyHeldCaretMatching
    /// for A would fail).
    func testCachedSessionHoldSurvivesLaterPipelineSteal() {
        let pipeline = TranscriptionPipeline()
        let snapA = selectReplaceSnapshot()
        let tokenA = pipeline.test_holdSnapshot(snapA, frontmostPID: 111)
        let cache = AudioRecorder.makeCachedSessionHold(
            token: tokenA,
            snapshot: snapA,
            pid: 111
        )

        let snapB = CaretContext.Snapshot(
            value: "stolen by re-press",
            location: 0,
            selectionLength: .readable(0),
            precedingChar: .startOfField,
            isUnknown: false
        )
        let tokenB = pipeline.test_holdSnapshot(snapB, frontmostPID: 222)
        XCTAssertNotEqual(tokenA, tokenB)
        XCTAssertNil(pipeline.copyHeldCaretMatching(tokenA).0)
        XCTAssertEqual(pipeline.copyHeldCaretMatching(tokenB).0, snapB)

        let sampled = AudioRecorder.sampleCachedSessionHold(
            activeToken: tokenA,
            cache: cache
        )
        XCTAssertEqual(sampled.token, tokenA)
        XCTAssertEqual(sampled.snapshot, snapA)
        XCTAssertEqual(sampled.pid, 111)
    }

    /// Per-token cache: inserting B must not erase A's frozen triple.
    func testPerTokenCachedSessionHoldSurvivesLaterInsert() {
        let snapA = selectReplaceSnapshot()
        let snapB = CaretContext.Snapshot(
            value: "session B hold",
            location: 2,
            selectionLength: .readable(0),
            precedingChar: .known("x"),
            isUnknown: false
        )
        let tokenA: UInt64 = 101
        let tokenB: UInt64 = 202

        var cache = AudioRecorder.makeCachedSessionHold(
            token: tokenA,
            snapshot: snapA,
            pid: 111
        )
        cache = AudioRecorder.insertCachedSessionHold(
            into: cache,
            token: tokenB,
            snapshot: snapB,
            pid: 222
        )

        let sampledA = AudioRecorder.sampleCachedSessionHold(
            activeToken: tokenA,
            cache: cache
        )
        XCTAssertEqual(sampledA.token, tokenA)
        XCTAssertEqual(sampledA.snapshot, snapA)
        XCTAssertEqual(sampledA.pid, 111)

        let sampledB = AudioRecorder.sampleCachedSessionHold(
            activeToken: tokenB,
            cache: cache
        )
        XCTAssertEqual(sampledB.token, tokenB)
        XCTAssertEqual(sampledB.snapshot, snapB)
        XCTAssertEqual(sampledB.pid, 222)

        // Token-matched remove leaves the other entry.
        let afterClearA = AudioRecorder.removeCachedSessionHold(
            from: cache,
            token: tokenA
        )
        XCTAssertNil(
            AudioRecorder.sampleCachedSessionHold(
                activeToken: tokenA,
                cache: afterClearA
            ).snapshot
        )
        XCTAssertEqual(
            AudioRecorder.sampleCachedSessionHold(
                activeToken: tokenB,
                cache: afterClearA
            ).snapshot,
            snapB
        )
    }

    /// Stop-before-promote: sample token is preferredSessionHoldToken, so a
    /// pending session still resolves its cached triple when active is nil.
    func testSampleCachedSessionHoldUsesPendingWhenActiveNil() {
        let snapA = selectReplaceSnapshot()
        let tokenA: UInt64 = 303
        let cache = AudioRecorder.makeCachedSessionHold(
            token: tokenA,
            snapshot: snapA,
            pid: 333
        )
        let sampleToken = AudioRecorder.preferredSessionHoldToken(
            active: nil,
            pending: tokenA
        )
        XCTAssertEqual(sampleToken, tokenA)

        let sampled = AudioRecorder.sampleCachedSessionHold(
            activeToken: sampleToken,
            cache: cache
        )
        XCTAssertEqual(sampled.token, tokenA)
        XCTAssertEqual(sampled.snapshot, snapA)
        XCTAssertEqual(sampled.pid, 333)
    }

    /// When active and pending differ, sample must prefer pending (newer
    /// session) so a stale uncleared active from a prior take cannot win.
    func testSamplePrefersPendingWhenActiveAndPendingDiffer() {
        let snapActive = selectReplaceSnapshot()
        let snapPending = CaretContext.Snapshot(
            value: "newer pending hold",
            location: 4,
            selectionLength: .readable(0),
            precedingChar: .known("n"),
            isUnknown: false
        )
        let tokenActive: UInt64 = 401
        let tokenPending: UInt64 = 402
        var cache = AudioRecorder.makeCachedSessionHold(
            token: tokenActive,
            snapshot: snapActive,
            pid: 111
        )
        cache = AudioRecorder.insertCachedSessionHold(
            into: cache,
            token: tokenPending,
            snapshot: snapPending,
            pid: 222
        )

        let preferred = AudioRecorder.preferredSessionHoldToken(
            active: tokenActive,
            pending: tokenPending
        )
        XCTAssertEqual(preferred, tokenPending)

        let sampled = AudioRecorder.sampleCachedSessionHold(
            activeToken: preferred,
            cache: cache
        )
        XCTAssertEqual(sampled.token, tokenPending)
        XCTAssertEqual(sampled.snapshot, snapPending)
        XCTAssertEqual(sampled.pid, 222)
    }

    /// Teardown clear token must prefer pending when both slots differ.
    func testTeardownTokenPrefersPendingWhenBothDiffer() {
        let tokenActive: UInt64 = 501
        let tokenPending: UInt64 = 502
        XCTAssertEqual(
            AudioRecorder.teardownHeldCaretClearToken(
                active: tokenActive,
                pending: tokenPending
            ),
            tokenPending
        )
        // Same-token / single-slot cases still resolve that token.
        XCTAssertEqual(
            AudioRecorder.teardownHeldCaretClearToken(
                active: tokenActive,
                pending: tokenActive
            ),
            tokenActive
        )
        XCTAssertEqual(
            AudioRecorder.teardownHeldCaretClearToken(
                active: tokenActive,
                pending: nil
            ),
            tokenActive
        )
    }

    /// Secure abort must not prefer-pending wipe a newer re-armed hold.
    /// active≠pending + wantsRecording → clear only active; !wantsRecording → both.
    func testSecureAbortClearTokensPreservesPendingWhenReArmed() {
        let tokenActive: UInt64 = 701
        let tokenPending: UInt64 = 702
        XCTAssertEqual(
            AudioRecorder.secureAbortClearTokens(
                active: tokenActive,
                pending: tokenPending,
                wantsRecording: true
            ),
            [tokenActive]
        )
        XCTAssertEqual(
            AudioRecorder.secureAbortClearTokens(
                active: tokenActive,
                pending: tokenPending,
                wantsRecording: false
            ),
            [tokenActive, tokenPending]
        )
        // Single-slot / same-token still clear that session only.
        XCTAssertEqual(
            AudioRecorder.secureAbortClearTokens(
                active: tokenActive,
                pending: tokenActive,
                wantsRecording: true
            ),
            [tokenActive]
        )
        XCTAssertEqual(
            AudioRecorder.secureAbortClearTokens(
                active: tokenActive,
                pending: nil,
                wantsRecording: false
            ),
            [tokenActive]
        )
        XCTAssertEqual(
            AudioRecorder.secureAbortClearTokens(
                active: nil,
                pending: tokenPending,
                wantsRecording: true
            ),
            [tokenPending]
        )
        XCTAssertEqual(
            AudioRecorder.secureAbortClearTokens(
                active: nil,
                pending: nil,
                wantsRecording: true
            ),
            []
        )
    }

    /// Success-path consume clears the active token's cache entry and slot
    /// without wiping an unrelated newer pending.
    func testConsumeClearRemovesActiveCachePreservesNewerPending() {
        let snapActive = selectReplaceSnapshot()
        let snapPending = CaretContext.Snapshot(
            value: "pending after re-press",
            location: 0,
            selectionLength: .readable(0),
            precedingChar: .startOfField,
            isUnknown: false
        )
        let tokenActive: UInt64 = 601
        let tokenPending: UInt64 = 602
        var cache = AudioRecorder.makeCachedSessionHold(
            token: tokenActive,
            snapshot: snapActive,
            pid: 111
        )
        cache = AudioRecorder.insertCachedSessionHold(
            into: cache,
            token: tokenPending,
            snapshot: snapPending,
            pid: 222
        )

        let clearToken = AudioRecorder.consumedSessionHoldClearToken(
            sampled: tokenActive,
            active: tokenActive,
            pending: tokenPending
        )
        XCTAssertEqual(clearToken, tokenActive)
        guard let clearToken else {
            return
        }

        let next = AudioRecorder.sessionHoldStateAfterConsume(
            active: tokenActive,
            pending: tokenPending,
            cache: cache,
            clearToken: clearToken
        )
        XCTAssertNil(next.active)
        XCTAssertEqual(next.pending, tokenPending)
        XCTAssertNil(
            AudioRecorder.sampleCachedSessionHold(
                activeToken: tokenActive,
                cache: next.cache
            ).snapshot
        )
        XCTAssertEqual(
            AudioRecorder.sampleCachedSessionHold(
                activeToken: tokenPending,
                cache: next.cache
            ).snapshot,
            snapPending
        )
    }

    /// Nil sampled consume token must prefer pending when active≠pending
    /// (same rule as preferredSessionHoldToken) — not stale active.
    func testConsumedClearTokenNilSampledPrefersPendingWhenBothDiffer() {
        let tokenActive: UInt64 = 701
        let tokenPending: UInt64 = 702
        XCTAssertEqual(
            AudioRecorder.consumedSessionHoldClearToken(
                sampled: nil,
                active: tokenActive,
                pending: tokenPending
            ),
            tokenPending
        )
        XCTAssertEqual(
            AudioRecorder.consumedSessionHoldClearToken(
                sampled: nil,
                active: tokenActive,
                pending: nil
            ),
            tokenActive
        )
        XCTAssertEqual(
            AudioRecorder.consumedSessionHoldClearToken(
                sampled: nil,
                active: nil,
                pending: tokenPending
            ),
            tokenPending
        )
        // Explicit sampled still wins over prefer-pending.
        XCTAssertEqual(
            AudioRecorder.consumedSessionHoldClearToken(
                sampled: tokenActive,
                active: tokenActive,
                pending: tokenPending
            ),
            tokenActive
        )
    }

    /// Sampled token A, then B starts (active/pending B): token-matched clear
    /// of A must not wipe B's slots or cache entry.
    func testTokenMatchedClearOfOlderSessionPreservesNewerSlotsAndCache() {
        let snapA = selectReplaceSnapshot()
        let snapB = CaretContext.Snapshot(
            value: "session B after re-press",
            location: 2,
            selectionLength: .readable(0),
            precedingChar: .known("B"),
            isUnknown: false
        )
        let tokenA: UInt64 = 801
        let tokenB: UInt64 = 802
        var cache = AudioRecorder.makeCachedSessionHold(
            token: tokenA,
            snapshot: snapA,
            pid: 111
        )
        cache = AudioRecorder.insertCachedSessionHold(
            into: cache,
            token: tokenB,
            snapshot: snapB,
            pid: 222
        )

        // Late teardown of sampled A while active/pending already hold B.
        let clearToken = AudioRecorder.consumedSessionHoldClearToken(
            sampled: tokenA,
            active: tokenB,
            pending: tokenB
        )
        XCTAssertEqual(clearToken, tokenA)
        guard let clearToken else {
            return
        }

        let next = AudioRecorder.sessionHoldStateAfterConsume(
            active: tokenB,
            pending: tokenB,
            cache: cache,
            clearToken: clearToken
        )
        XCTAssertEqual(next.active, tokenB)
        XCTAssertEqual(next.pending, tokenB)
        XCTAssertNil(
            AudioRecorder.sampleCachedSessionHold(
                activeToken: tokenA,
                cache: next.cache
            ).snapshot
        )
        XCTAssertEqual(
            AudioRecorder.sampleCachedSessionHold(
                activeToken: tokenB,
                cache: next.cache
            ).snapshot,
            snapB
        )
        XCTAssertEqual(
            AudioRecorder.sampleCachedSessionHold(
                activeToken: tokenB,
                cache: next.cache
            ).pid,
            222
        )
    }

    /// Queued doStop must skip when re-press re-armed wantsRecording or a
    /// newer stop bumped the generation.
    func testShouldSkipStaleDoStop() {
        XCTAssertTrue(
            AudioRecorder.shouldSkipStaleDoStop(
                wantsRecording: true,
                capturedGeneration: 1,
                currentGeneration: 1
            ),
            "re-armed wantsRecording must skip prior doStop"
        )
        XCTAssertTrue(
            AudioRecorder.shouldSkipStaleDoStop(
                wantsRecording: false,
                capturedGeneration: 1,
                currentGeneration: 2
            ),
            "stale generation must skip prior doStop"
        )
        XCTAssertFalse(
            AudioRecorder.shouldSkipStaleDoStop(
                wantsRecording: false,
                capturedGeneration: 2,
                currentGeneration: 2
            ),
            "matching generation with wantsRecording=false must proceed"
        )
    }

    /// finishTranscription must prefer a non-nil stop-time session snapshot
    /// even when the live slot still matches the session token but was cleared.
    func testResolveHeldAtStartPrefersNonNilSessionSnapshot() {
        let snapA = selectReplaceSnapshot()
        let preferred = TranscriptionPipeline.resolveHeldAtStart(
            sessionHeldSnapshot: snapA,
            sessionHeldToken: 7,
            liveToken: 7,
            liveSnapshot: nil
        )
        XCTAssertEqual(preferred, snapA)

        let fallback = TranscriptionPipeline.resolveHeldAtStart(
            sessionHeldSnapshot: nil,
            sessionHeldToken: 7,
            liveToken: 7,
            liveSnapshot: snapA
        )
        XCTAssertEqual(fallback, snapA)

        let stale = TranscriptionPipeline.resolveHeldAtStart(
            sessionHeldSnapshot: nil,
            sessionHeldToken: 7,
            liveToken: 9,
            liveSnapshot: snapA
        )
        XCTAssertNil(stale)
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

    func testApplyInjectTransforms_unknownSnapshotContinuationLeadingSpace() {
        let out = TranscriptionPipeline.applyInjectTransforms(
            expanded: "hello",
            snapshot: .unknown,
            secureInput: false,
            smartLeadingSpaceEnabled: true,
            codeAware: false,
            accessibilityTrusted: true
        )
        XCTAssertEqual(out, " hello")
    }

    func testApplyInjectTransforms_unknownSnapshotNonAlphanumericNoLeadingSpace() {
        let out = TranscriptionPipeline.applyInjectTransforms(
            expanded: "...",
            snapshot: .unknown,
            secureInput: false,
            smartLeadingSpaceEnabled: true,
            codeAware: false,
            accessibilityTrusted: true
        )
        XCTAssertEqual(out, "...")
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
