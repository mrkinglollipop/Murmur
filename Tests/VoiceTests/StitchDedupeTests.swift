import XCTest
@testable import Voice

final class StitchDedupeTests: XCTestCase {

    private static let mattParagraphPrefix =
        "I'm wondering if we need to do option C. The reason being is I don't think the local is even working anymore. I had so many issues with getting it to run. Go ahead and verify, audit it, et cetera."

    private static let mattClosingFireclaw =
        "If I recall correctly, the conclusion I came to is I was just better off using Fireclaw for all my searches."

    private static let mattClosingFireCrawl =
        "If I recall correctly, the conclusion I came to is I was just better off using FireCrawl for all my searches."

    // MARK: - stitchWithWordOverlap

    func testStitchOverlapCaseMismatchDoesNotMerge() {
        let left = "Hello World today"
        let right = "tomorrow evening"
        XCTAssertNil(XAIStreamingTranscriber.stitchWithWordOverlap(left, right))
    }

    func testStitchOverlapExactCaseMerges() {
        let left = "Hello world"
        let right = "world tomorrow"
        XCTAssertEqual(
            XAIStreamingTranscriber.stitchWithWordOverlap(left, right),
            "Hello world tomorrow"
        )
    }

    func testStitchOverlapCaseInsensitiveMerges() {
        let left = "Hello World"
        let right = "world tomorrow"
        XCTAssertEqual(
            XAIStreamingTranscriber.stitchWithWordOverlap(left, right),
            "Hello World tomorrow"
        )
    }

    // MARK: - dedupeRepeatedContent

    func testDedupeFalsePositiveOnRepeatedSentences() {
        let text = "The meeting is at three. The meeting is at three."
        XCTAssertEqual(
            XAIStreamingTranscriber.dedupeRepeatedContent(text),
            text
        )
    }

    func testDedupeTruePositiveOnDuplicatedHalves() {
        let half = "Hello world this is a test phrase"
        let duplicated = half + " " + half
        XCTAssertEqual(
            XAIStreamingTranscriber.dedupeRepeatedContent(duplicated),
            half
        )
    }

    func testDedupeIgnoresShortText() {
        let text = "hello hello"
        XCTAssertEqual(XAIStreamingTranscriber.dedupeRepeatedContent(text), text)
    }

    // MARK: - mergeStreamingSegment / near-dup tail

    func testMergeStreamingSegmentFireclawFireCrawlGolden() {
        let chunk1 = Self.mattParagraphPrefix + " " + Self.mattClosingFireclaw
        let chunk2 = Self.mattClosingFireCrawl
        let merged = XAIStreamingTranscriber.mergeStreamingSegment(left: chunk1, right: chunk2)
        XCTAssertEqual(merged, Self.mattParagraphPrefix + " " + Self.mattClosingFireCrawl)
        XCTAssertFalse(merged.contains("Fireclaw"))
    }

    func testMergeSegmentIntoConfirmedFallbackWhenWordsEmpty() {
        let chunk1 = Self.mattParagraphPrefix + " " + Self.mattClosingFireclaw
        let chunk2 = Self.mattClosingFireCrawl
        var accumulated = chunk1
        let first = XAIStreamingTranscriber.mergeSegmentIntoConfirmed(
            confirmed: accumulated,
            text: chunk2,
            incomingWords: [],
            committedWords: [],
            lastCommittedEnd: 0
        )
        accumulated = first.confirmedText
        XCTAssertEqual(accumulated, Self.mattParagraphPrefix + " " + Self.mattClosingFireCrawl)
    }

    func testMergeStreamingSegmentPreservesIntentionalIdenticalRepeat() {
        let left = "The meeting is at three."
        let right = "The meeting is at three."
        XCTAssertEqual(
            XAIStreamingTranscriber.mergeStreamingSegment(left: left, right: right),
            "The meeting is at three. The meeting is at three."
        )
    }

    func testNearDupTailReplaceRequiresTokenDrift() {
        let sentence = "If I recall correctly, the conclusion I came to is I was just better off using FireCrawl for all my searches."
        XCTAssertFalse(XAIStreamingTranscriber.shouldReplaceTail(left: sentence, right: sentence))
        let merged = XAIStreamingTranscriber.mergeStreamingSegment(left: sentence, right: sentence)
        XCTAssertEqual(merged, sentence + " " + sentence)
    }

    func testCollapseNearDuplicateTail() {
        let prefix = Self.mattParagraphPrefix + " "
        let duplicated = prefix + Self.mattClosingFireclaw + " " + Self.mattClosingFireCrawl
        let collapsed = XAIStreamingTranscriber.collapseNearDuplicateTail(duplicated)
        XCTAssertEqual(collapsed, prefix + Self.mattClosingFireCrawl)
    }

    func testResolveFinalTranscriptPrefersDoneWhenStitchDuplicated() {
        let prefix = Self.mattParagraphPrefix + " "
        let stitched = prefix + Self.mattClosingFireclaw + " " + Self.mattClosingFireCrawl
        let done = prefix + Self.mattClosingFireCrawl
        XCTAssertEqual(
            XAIStreamingTranscriber.resolveFinalTranscript(stitched: stitched, done: done),
            done
        )
    }

    func testResolveFinalTranscriptRejectsShorterDoneSegment() {
        let full = Self.mattParagraphPrefix + " " + Self.mattClosingFireCrawl
        let segmentOnly = Self.mattClosingFireCrawl
        XCTAssertEqual(
            XAIStreamingTranscriber.resolveFinalTranscript(stitched: full, done: segmentOnly),
            full
        )
    }

    func testReplaceOverlappingTailPreservesUnpunctuatedPrefix() {
        let prefix = Self.mattParagraphPrefix
        let left = prefix + " " + Self.mattClosingFireclaw
        let merged = XAIStreamingTranscriber.mergeStreamingSegment(left: left, right: Self.mattClosingFireCrawl)
        XCTAssertEqual(merged, prefix + " " + Self.mattClosingFireCrawl)
        XCTAssertTrue(merged.hasPrefix(prefix))
    }

    func testMattProjectLollipopGolden() {
        let chunk1 =
            "The project should be the default. Project, not project with lollipop, unless I'm missing something."
        let chunk2 =
            "The project should be the default project, not project with lollipop, unless I'm missing something."
        let merged = XAIStreamingTranscriber.mergeStreamingSegment(left: chunk1, right: chunk2)
        XCTAssertEqual(merged, chunk2)

        let duplicated = chunk1 + " " + chunk2
        let cleaned = XAIStreamingTranscriber.postProcessTranscript(duplicated)
        XCTAssertEqual(cleaned, chunk2)
    }

    func testMattAlwaysOnRuleThinkFirstGolden() {
        let chunk1 =
            "How did the always-on rule think first help during this conversation?"
        let chunk2 =
            "How did the \"always on rule think first\" help during this conversation?"
        let merged = XAIStreamingTranscriber.mergeStreamingSegment(left: chunk1, right: chunk2)
        XCTAssertEqual(merged, chunk2)

        let duplicated = chunk1 + " " + chunk2
        let cleaned = XAIStreamingTranscriber.postProcessTranscript(duplicated)
        XCTAssertEqual(cleaned, chunk2)
    }

    func testPostProcessPreservesDistinctHyphenatedSentences() {
        let text = "The always-on backup runs daily. The always-on backup runs weekly."
        XCTAssertEqual(XAIStreamingTranscriber.postProcessTranscript(text), text)
    }

    func testMergeSegmentIntoConfirmedSkipsOverlappingWordTimestamps() {
        let existing: [TranscriptWord] = [
            TranscriptWord(text: "hello", start: 0, end: 0.5),
            TranscriptWord(text: "world", start: 0.5, end: 1.0)
        ]
        let incoming: [TranscriptWord] = [
            TranscriptWord(text: "world", start: 0.9, end: 1.2),
            TranscriptWord(text: "again", start: 1.3, end: 1.8)
        ]
        let result = XAIStreamingTranscriber.mergeSegmentIntoConfirmed(
            confirmed: "hello world",
            text: "world again",
            incomingWords: incoming,
            committedWords: existing,
            lastCommittedEnd: 1.0
        )
        XCTAssertEqual(result.committedWords.count, 3)
        XCTAssertEqual(result.committedWords.last?.text, "again")
        XCTAssertEqual(result.lastCommittedEnd, 1.8, accuracy: 0.001)
    }

    func testPostProcessPreservesIntentionalIdenticalRepeat() {
        let text = "The meeting is at three. The meeting is at three."
        XCTAssertEqual(XAIStreamingTranscriber.postProcessTranscript(text), text)
    }

    func testDedupeStitchArtifactsCollapsesAppendedNearDuplicateClosing() {
        let prefix = Self.mattParagraphPrefix + " "
        let duplicated = prefix + Self.mattClosingFireclaw + " " + Self.mattClosingFireCrawl
        let cleaned = XAIStreamingTranscriber.dedupeStitchArtifacts(duplicated)
        XCTAssertEqual(cleaned, prefix + Self.mattClosingFireCrawl)
    }

    func testNearDuplicateTailWindowFindsLongerLeftSuffix() {
        let prefix = Self.mattParagraphPrefix + " Some extra words at the boundary"
        let left = prefix + " " + Self.mattClosingFireclaw
        let window = XAIStreamingTranscriber.nearDuplicateTailWindow(in: left, right: Self.mattClosingFireCrawl)
        XCTAssertNotNil(window)
        let merged = XAIStreamingTranscriber.mergeStreamingSegment(left: left, right: Self.mattClosingFireCrawl)
        XCTAssertEqual(merged, prefix + " " + Self.mattClosingFireCrawl)
        XCTAssertFalse(merged.contains("Fireclaw"))
    }

    // MARK: - extension / containment near-dup (Cursor from it)

    private static let mattCursorEarlier =
        "I meant has somebody created something like Cursor?"
    private static let mattCursorRefined =
        "I meant has somebody created something like Cursor from it?"
    private static let mattADETrailer =
        "An ADE though, not an IDE."

    func testMattCursorFromItGoldenCollapsesWithADETrailer() {
        let stitched = Self.mattCursorEarlier + " " + Self.mattCursorRefined + " " + Self.mattADETrailer
        let expected = Self.mattCursorRefined + " " + Self.mattADETrailer
        XCTAssertEqual(XAIStreamingTranscriber.dedupeStitchArtifacts(stitched), expected)
        XCTAssertEqual(XAIStreamingTranscriber.postProcessTranscript(stitched), expected)
    }

    func testMergeStreamingSegmentCursorExtensionRefinement() {
        let merged = XAIStreamingTranscriber.mergeStreamingSegment(
            left: Self.mattCursorEarlier,
            right: Self.mattCursorRefined
        )
        XCTAssertEqual(merged, Self.mattCursorRefined)
    }

    func testCollapseNearDuplicateTailScansMidListWithTrailingShortSentence() {
        let stitched = Self.mattCursorEarlier + " " + Self.mattCursorRefined + " " + Self.mattADETrailer
        let collapsed = XAIStreamingTranscriber.collapseNearDuplicateTail(stitched)
        XCTAssertEqual(collapsed, Self.mattCursorRefined + " " + Self.mattADETrailer)
    }

    func testExtensionNearDuplicatePreservesIntentionalIdenticalRepeat() {
        let left = "The meeting is at three o'clock today."
        let right = "The meeting is at three o'clock today."
        XCTAssertFalse(
            XAIStreamingTranscriber.isExtensionNearDuplicate(earlier: left, later: right)
        )
        XCTAssertFalse(
            XAIStreamingTranscriber.shouldCollapseNearDuplicateSentencePair(earlier: left, later: right)
        )
        XCTAssertEqual(
            XAIStreamingTranscriber.mergeStreamingSegment(left: left, right: right),
            "The meeting is at three o'clock today. The meeting is at three o'clock today."
        )
        let duplicated = left + " " + right
        XCTAssertEqual(XAIStreamingTranscriber.dedupeStitchArtifacts(duplicated), duplicated)
    }

    func testExtensionNearDuplicateRejectsKeywordSwapParaphrase() {
        let earlier = "Please check the dashboard before the launch tomorrow morning."
        let later = "Please check the billing before the launch tomorrow morning."
        XCTAssertFalse(
            XAIStreamingTranscriber.isExtensionNearDuplicate(earlier: earlier, later: later)
        )

        let midListWithTrailer =
            earlier + " " + later + " " + Self.mattADETrailer
        XCTAssertEqual(
            XAIStreamingTranscriber.collapseNearDuplicateTail(midListWithTrailer),
            midListWithTrailer
        )
        XCTAssertEqual(
            XAIStreamingTranscriber.dedupeStitchArtifacts(midListWithTrailer),
            midListWithTrailer
        )
    }

    func testReverseStitchRefinedBeforeStubPreservesRefinement() {
        let reverseStitched =
            Self.mattCursorRefined + " " + Self.mattCursorEarlier + " " + Self.mattADETrailer
        let collapsed = XAIStreamingTranscriber.collapseNearDuplicateTail(reverseStitched)
        let deduped = XAIStreamingTranscriber.dedupeStitchArtifacts(reverseStitched)

        XCTAssertTrue(collapsed.contains("from it"), "collapsed must not drop refined tail words")
        XCTAssertTrue(deduped.contains("from it"), "deduped must not drop refined tail words")
        XCTAssertFalse(
            collapsed == Self.mattCursorEarlier + " " + Self.mattADETrailer,
            "must not collapse reverse stitch to stub-only"
        )
    }

    // MARK: - short clause-extension (5-token stub)

    private static let mattConnectCursorStub = "How do I connect Cursor?"
    private static let mattConnectCursorNotion = "How do I connect Cursor into Notion?"

    func testMattConnectCursorIntoNotionGolden() {
        let stitched = Self.mattConnectCursorStub + " " + Self.mattConnectCursorNotion
        XCTAssertEqual(
            XAIStreamingTranscriber.dedupeStitchArtifacts(stitched),
            Self.mattConnectCursorNotion
        )
        XCTAssertEqual(
            XAIStreamingTranscriber.postProcessTranscript(stitched),
            Self.mattConnectCursorNotion
        )
    }

    func testMergeStreamingSegmentShortClauseExtension() {
        let merged = XAIStreamingTranscriber.mergeStreamingSegment(
            left: Self.mattConnectCursorStub,
            right: Self.mattConnectCursorNotion
        )
        XCTAssertEqual(merged, Self.mattConnectCursorNotion)
    }

    func testShortClauseExtensionRequiresFiveTokenPrefix() {
        XCTAssertTrue(
            XAIStreamingTranscriber.isExtensionNearDuplicate(
                earlier: Self.mattConnectCursorStub,
                later: Self.mattConnectCursorNotion
            )
        )
        // 4-token stubs stay out of the extension path (too aggressive).
        XCTAssertFalse(
            XAIStreamingTranscriber.isExtensionNearDuplicate(
                earlier: "How do I connect?",
                later: "How do I connect Cursor into Notion?"
            )
        )
    }

    func testShortIdenticalRepeatStillPreserved() {
        let left = "How do I connect Cursor?"
        let right = "How do I connect Cursor?"
        XCTAssertFalse(
            XAIStreamingTranscriber.isExtensionNearDuplicate(earlier: left, later: right)
        )
        XCTAssertFalse(
            XAIStreamingTranscriber.shouldCollapseNearDuplicateSentencePair(earlier: left, later: right)
        )
        let duplicated = left + " " + right
        XCTAssertEqual(XAIStreamingTranscriber.dedupeStitchArtifacts(duplicated), duplicated)
    }

    func testMidHoldUnpunctuatedFiveTokenSuffixExtension() {
        // No sentence boundary — collapseNearDuplicateTail cannot help; merge
        // must replace the 5-token trailing stub via nearDuplicateTailWindow.
        let left = "I'm wondering about setup How do I connect Cursor"
        let right = "How do I connect Cursor into Notion"
        let merged = XAIStreamingTranscriber.mergeStreamingSegment(left: left, right: right)
        XCTAssertEqual(merged, "I'm wondering about setup How do I connect Cursor into Notion")
        XCTAssertFalse(merged.contains("Cursor How do I connect"))
    }
}
