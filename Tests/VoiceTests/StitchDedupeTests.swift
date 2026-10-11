import XCTest
@testable import Voice

final class StitchDedupeTests: XCTestCase {

    func testTimedDonePreservesUntimedInterimThroughFinalize() async {
        let session = XAIStreamingTranscriber(apiKey: "offline", messageSender: { _ in })
        session.handleServerEvent(#"{"type":"transcript.partial","text":"Yes.","is_final":true,"words":[{"text":"Yes","start":0,"end":1}]}"#)
        session.handleServerEvent(#"{"type":"transcript.partial","text":"Call Alice.","is_final":false}"#)
        session.handleServerEvent(#"{"type":"transcript.done","text":"Yes.","words":[{"text":"Yes","start":0,"end":1}]}"#)
        let result = await session.finalize()
        XCTAssertEqual(result, "Yes. Call Alice.")
    }

    func testTimedDoneCannotChooseBetweenResetUtteranceOrigins() async {
        let session = XAIStreamingTranscriber(apiKey: "offline", messageSender: { _ in })
        session.handleServerEvent(#"{"type":"transcript.partial","text":"Call Alice.","is_final":true,"speech_final":true,"words":[{"text":"Call Alice","start":0,"end":1}]}"#)
        session.handleServerEvent(#"{"type":"transcript.partial","text":"Call Bob.","is_final":true,"speech_final":true,"words":[{"text":"Call Bob","start":0,"end":1}]}"#)
        session.handleServerEvent(#"{"type":"transcript.done","text":"Wait.","words":[{"text":"Wait","start":0,"end":1}]}"#)
        let result = await session.finalize()
        XCTAssertEqual(result, "Call Alice. Call Bob. Wait.")
    }

    func testOverlappingTimestampsWithoutAnEstablishedOriginPreserveBothSegments() {
        let result = XAIStreamingTranscriber.mergeSegmentIntoConfirmed(
            confirmed: "Do not send.", text: "Wait.",
            incomingWords: [TranscriptWord(text: "Wait", start: 0, end: 1)],
            committedWords: [TranscriptWord(text: "Do not send", start: 0, end: 1)],
            lastCommittedEnd: 1)
        XCTAssertEqual(result.confirmedText, "Do not send. Wait.")
    }

    func testCompletePrefixSentenceSurvivesPostprocessing() {
        let text = "I will send the report. I will send the report only after approval."
        XCTAssertEqual(XAIStreamingTranscriber.postProcessTranscript(text), text)
    }

    func testCompletePrefixSentenceSurvivesFinalDeliveryWithoutTimestamps() async throws {
        let first = "I will send the report."
        let second = "I will send the report only after approval."
        let result = try await replayFinals([(first, nil), (second, nil)], done: second)
        XCTAssertEqual(result, first + " " + second)
    }

    func testSameAudioSpellingRefinementSurvivesFinalDelivery() async throws {
        let original = "Please use Fireclaw for all my searches."
        let corrected = "Please use FireCrawl for all my searches."
        let result = try await replayFinals([(original, 0), (corrected, 0)], done: corrected)
        XCTAssertEqual(result, corrected)
    }

    func testDisjointAudioKeepsRepeatedAndExtendedSentences() async throws {
        for (first, second) in [
            ("I will send the report.", "I will send the report only after approval."),
            ("Please use Fireclaw for all my searches.", "Please use FireCrawl for all my searches."),
            ("Please send all the reports today", "Please send all the reports today"),
            ("Please send all the reports today.", "Please send all the reports today!"),
            ("Please send all the reports today.", "Please send all the reports today.")
        ] {
            let result = try await replayFinals([(first, 0), (second, 10)], done: second)
            XCTAssertEqual(result, first + " " + second)
        }
    }

    func testSameAudioTailRefinementPreservesEarlierAndLaterAudio() async throws {
        let prefix = "The first sentence stays."
        let original = "Please use Fireclaw for all my searches."
        let corrected = "Please use FireCrawl for all my searches."
        let trailer = "Call Alice tomorrow."
        let result = try await replayFinals(
            [(prefix, 0), (original, 4), (trailer, 8), (corrected, 4)], done: corrected)
        XCTAssertEqual(result, prefix + " " + corrected + " " + trailer)
    }

    func testTouchingAudioIntervalsAreDisjoint() async throws {
        let sentence = "Please send all the reports today."
        let result = try await replayFinals([(sentence, 0), (sentence, 1.8)], done: sentence)
        XCTAssertEqual(result, sentence + " " + sentence)
    }

    func testUntimedDoneCannotReplaceConfirmedSentenceByLength() async throws {
        let sentence = "Send the report."
        let result = try await replayFinals([(sentence, nil)], done: "Do not send the report tomorrow.")
        XCTAssertEqual(result, sentence)
    }

    func testUntimedFinalReplacesItsOwnInterim() async {
        let session = XAIStreamingTranscriber(apiKey: "unused", messageSender: { _ in })
        session.handleServerEvent(#"{"type":"transcript.partial","text":"Send the report.","is_final":true}"#)
        session.handleServerEvent(#"{"type":"transcript.partial","text":"Call Alex.","is_final":false}"#)
        session.handleServerEvent(#"{"type":"transcript.partial","text":"Call Alice.","is_final":true}"#)
        session.handleServerEvent(#"{"type":"transcript.done","text":""}"#)
        let result = await session.finalize()
        XCTAssertEqual(result, "Send the report. Call Alice.")
    }

    func testTimestampedDoneRefinesTheSameAudio() async {
        let session = XAIStreamingTranscriber(apiKey: "unused", messageSender: { _ in })
        session.handleServerEvent(#"{"type":"transcript.partial","text":"Fireclaw.","is_final":true,"words":[{"text":"Fireclaw","start":0,"end":1}]}"#)
        session.handleServerEvent(#"{"type":"transcript.done","text":"FireCrawl.","words":[{"text":"FireCrawl","start":0,"end":1}]}"#)
        let result = await session.finalize()
        XCTAssertEqual(result, "FireCrawl.")
    }

    func testTimestampedInterimFromDisjointAudioIsKept() async {
        let session = XAIStreamingTranscriber(apiKey: "unused", messageSender: { _ in })
        session.handleServerEvent(#"{"type":"transcript.partial","text":"Yes.","is_final":true,"words":[{"text":"Yes","start":0,"end":1}]}"#)
        session.handleServerEvent(#"{"type":"transcript.partial","text":"Yes.","is_final":false,"words":[{"text":"Yes","start":1,"end":2}]}"#)
        session.handleServerEvent(#"{"type":"transcript.done","text":""}"#)
        let result = await session.finalize()
        XCTAssertEqual(result, "Yes. Yes.")
    }

    func testIncompleteWordMetadataCannotDeleteUntimedText() async {
        let session = XAIStreamingTranscriber(apiKey: "unused", messageSender: { _ in })
        session.handleServerEvent(#"{"type":"transcript.partial","text":"Keep this sentence. Fireclaw.","is_final":true,"words":[{"text":"Fireclaw","start":0,"end":1}]}"#)
        session.handleServerEvent(#"{"type":"transcript.partial","text":"FireCrawl.","is_final":true,"words":[{"text":"FireCrawl","start":0,"end":1}]}"#)
        session.handleServerEvent(#"{"type":"transcript.done","text":"FireCrawl."}"#)
        let result = await session.finalize()
        // Unaligned metadata cannot authorize deleting the untimed prefix.
        XCTAssertEqual(result, "Keep this sentence. Fireclaw. FireCrawl.")
    }

    func testTimestampedDonePreservesLaterInterimAudio() async {
        let session = XAIStreamingTranscriber(apiKey: "unused", messageSender: { _ in })
        session.handleServerEvent(#"{"type":"transcript.partial","text":"Yes.","is_final":true,"words":[{"text":"Yes","start":0,"end":1}]}"#)
        session.handleServerEvent(#"{"type":"transcript.partial","text":"Call Alice.","is_final":false,"words":[{"text":"Call","start":1,"end":1.5},{"text":"Alice","start":1.5,"end":2}]}"#)
        session.handleServerEvent(#"{"type":"transcript.done","text":"Yes.","words":[{"text":"Yes","start":0,"end":1}]}"#)
        let result = await session.finalize()
        XCTAssertEqual(result, "Yes. Call Alice.")
    }

    private func replayFinals(_ segments: [(String, Double?)], done: String) async throws -> String {
        let session = XAIStreamingTranscriber(apiKey: "unused", messageSender: { _ in })
        for (index, segment) in segments.enumerated() {
            var event: [String: Any] = [
                "type": "transcript.partial", "text": segment.0,
                "is_final": true, "speech_final": index == segments.count - 1
            ]
            if let start = segment.1 {
                event["words"] = segment.0.split(separator: " ").enumerated().map { offset, word in
                    ["text": String(word), "start": start + Double(offset) * 0.3,
                     "end": start + Double(offset + 1) * 0.3] as [String: Any]
                }
            }
            let data = try JSONSerialization.data(withJSONObject: event)
            session.handleServerEvent(String(decoding: data, as: UTF8.self))
        }
        let data = try JSONSerialization.data(withJSONObject: ["type": "transcript.done", "text": done])
        session.handleServerEvent(String(decoding: data, as: UTF8.self))
        return await session.finalize()
    }

    func testPostProcessPreservesNearbyWordsWithDifferentMeanings() {
        for (earlier, later) in [
            ("The dose should increase again this morning.", "The dose should decrease again this morning."),
            ("The shipment was approved by the manager.", "The shipment was disproved by the manager.")
        ] {
            let text = earlier + " " + later
            XCTAssertEqual(XAIStreamingTranscriber.postProcessTranscript(text), text)
        }
    }

    func testDoneBeforeFinalizeDoesNotMergeStaleInterimAgain() async {
        let session = XAIStreamingTranscriber(apiKey: "unused", messageSender: { _ in })
        session.handleServerEvent(#"{"type":"transcript.partial","text":"Turn left.","is_final":false}"#)
        session.handleServerEvent(#"{"type":"transcript.done","text":"Turn right at the traffic lights."}"#)

        XCTAssertEqual(session.joinedTranscriptSnapshot(), "Turn right at the traffic lights.")
        let result = await session.finalize()
        XCTAssertEqual(result, "Turn right at the traffic lights.")
        XCTAssertFalse(session.requiresBufferedAudioRecovery)
    }

    func testEmptyOrShortDonePreservesUnfinalizedTail() async {
        for done in ["", "First sentence."] {
            let session = XAIStreamingTranscriber(apiKey: "unused", messageSender: { _ in })
            session.handleServerEvent(#"{"type":"transcript.partial","text":"First sentence.","is_final":true}"#)
            session.handleServerEvent(#"{"type":"transcript.partial","text":"Call Alice.","is_final":false}"#)
            session.handleServerEvent("{\"type\":\"transcript.done\",\"text\":\"\(done)\"}")
            let result = await session.finalize()
            XCTAssertEqual(result, "First sentence. Call Alice.")
        }
    }

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

    func testDedupeKeepsShortGenuineRepetition() {
        for text in ["I think so I think so", "no no no no", "yes yes yes yes yes yes yes yes"] {
            XCTAssertEqual(XAIStreamingTranscriber.dedupeRepeatedContent(text), text)
        }
    }

    func testDedupeCollapsesTwelveWordDoubledString() {
        let twelve = "one two three four five six"
        XCTAssertEqual(
            XAIStreamingTranscriber.dedupeRepeatedContent(twelve + " " + twelve),
            twelve
        )
    }

    func testDedupeIgnoresShortText() {
        let text = "hello hello"
        XCTAssertEqual(XAIStreamingTranscriber.dedupeRepeatedContent(text), text)
    }

    // MARK: - mergeStreamingSegment / near-dup tail

    func testMergeStreamingSegmentPreservesUnprovenSpellingChange() {
        let chunk1 = Self.mattParagraphPrefix + " " + Self.mattClosingFireclaw
        let chunk2 = Self.mattClosingFireCrawl
        let merged = XAIStreamingTranscriber.mergeStreamingSegment(left: chunk1, right: chunk2)
        XCTAssertEqual(merged, chunk1 + " " + chunk2)
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
        XCTAssertEqual(accumulated, chunk1 + " " + chunk2)
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

    func testNearDuplicateCollapsePreservesChangedContentWords() {
        for (earlier, later) in [
            ("The meeting is scheduled for Monday morning.", "The meeting is scheduled for Tuesday morning."),
            ("Please check the dashboard before the launch tomorrow morning.", "Please check the billing before the launch tomorrow morning."),
            ("Please send the report to Alex tomorrow morning.", "Please send the report to Sam tomorrow morning."),
            ("The meeting is scheduled for 10 tomorrow morning.", "The meeting is scheduled for 11 tomorrow morning.")
        ] {
            let text = earlier + " " + later
            XCTAssertFalse(XAIStreamingTranscriber.shouldCollapseNearDuplicateSentencePair(earlier: earlier, later: later))
            XCTAssertNil(XAIStreamingTranscriber.nearDuplicateTailWindow(in: earlier, right: later))
            XCTAssertEqual(XAIStreamingTranscriber.collapseNearDuplicateWordTail(text), text)
            XCTAssertEqual(XAIStreamingTranscriber.collapseNearDuplicateTail(text), text)
            XCTAssertEqual(XAIStreamingTranscriber.postProcessTranscript(text), text)
            XCTAssertEqual(XAIStreamingTranscriber.mergeStreamingSegment(left: earlier, right: later), text)
        }
    }

    func testNearDuplicateTailPreservesUnprovenSpellingChange() {
        let prefix = Self.mattParagraphPrefix + " "
        let duplicated = prefix + Self.mattClosingFireclaw + " " + Self.mattClosingFireCrawl
        let collapsed = XAIStreamingTranscriber.collapseNearDuplicateTail(duplicated)
        XCTAssertEqual(collapsed, duplicated)
    }

    func testResolveFinalTranscriptPreservesDifferentWordsInLongerStitch() {
        let prefix = Self.mattParagraphPrefix + " "
        let stitched = prefix + Self.mattClosingFireclaw + " " + Self.mattClosingFireCrawl
        let done = prefix + Self.mattClosingFireCrawl
        XCTAssertEqual(
            XAIStreamingTranscriber.resolveFinalTranscript(stitched: stitched, done: done),
            stitched
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

    func testDifferentTailWordsPreserveUnpunctuatedPrefixAndBothTails() {
        let prefix = Self.mattParagraphPrefix
        let left = prefix + " " + Self.mattClosingFireclaw
        let merged = XAIStreamingTranscriber.mergeStreamingSegment(left: left, right: Self.mattClosingFireCrawl)
        XCTAssertEqual(merged, left + " " + Self.mattClosingFireCrawl)
        XCTAssertTrue(merged.hasPrefix(prefix))
    }

    func testUntimedPunctuationRefinementPreservesBothSentences() {
        let chunk1 =
            "The project should be the default. Project, not project with lollipop, unless I'm missing something."
        let chunk2 =
            "The project should be the default project, not project with lollipop, unless I'm missing something."
        let merged = XAIStreamingTranscriber.mergeStreamingSegment(left: chunk1, right: chunk2)
        XCTAssertEqual(merged, chunk1 + " " + chunk2)

        let duplicated = chunk1 + " " + chunk2
        let cleaned = XAIStreamingTranscriber.postProcessTranscript(duplicated)
        XCTAssertEqual(cleaned, duplicated)
    }

    func testUntimedHyphenRefinementPreservesBothSentences() {
        let chunk1 =
            "How did the always-on rule think first help during this conversation?"
        let chunk2 =
            "How did the \"always on rule think first\" help during this conversation?"
        let merged = XAIStreamingTranscriber.mergeStreamingSegment(left: chunk1, right: chunk2)
        XCTAssertEqual(merged, chunk1 + " " + chunk2)

        let duplicated = chunk1 + " " + chunk2
        let cleaned = XAIStreamingTranscriber.postProcessTranscript(duplicated)
        XCTAssertEqual(cleaned, duplicated)
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
            lastCommittedEnd: 1.0,
            timestampOrigin: 0
        )
        XCTAssertEqual(result.committedWords.count, 3)
        XCTAssertEqual(result.committedWords.last?.text, "again")
        XCTAssertEqual(result.lastCommittedEnd, 1.8, accuracy: 0.001)
    }

    func testPostProcessPreservesIntentionalIdenticalRepeat() {
        let text = "The meeting is at three. The meeting is at three."
        XCTAssertEqual(XAIStreamingTranscriber.postProcessTranscript(text), text)
    }

    func testDedupeStitchArtifactsPreservesAppendedDifferentClosing() {
        let prefix = Self.mattParagraphPrefix + " "
        let duplicated = prefix + Self.mattClosingFireclaw + " " + Self.mattClosingFireCrawl
        let cleaned = XAIStreamingTranscriber.dedupeStitchArtifacts(duplicated)
        XCTAssertEqual(cleaned, duplicated)
    }

    func testNearDuplicateTailWindowRejectsUnprovenSpellingChange() {
        let prefix = Self.mattParagraphPrefix + " Some extra words at the boundary"
        let left = prefix + " " + Self.mattClosingFireclaw
        let window = XAIStreamingTranscriber.nearDuplicateTailWindow(in: left, right: Self.mattClosingFireCrawl)
        XCTAssertNil(window)
        let merged = XAIStreamingTranscriber.mergeStreamingSegment(left: left, right: Self.mattClosingFireCrawl)
        XCTAssertEqual(merged, left + " " + Self.mattClosingFireCrawl)
    }

    // MARK: - extension / containment near-dup (Cursor from it)

    private static let mattCursorEarlier =
        "I meant has somebody created something like Cursor?"
    private static let mattCursorRefined =
        "I meant has somebody created something like Cursor from it?"
    private static let mattADETrailer =
        "An ADE though, not an IDE."

    func testUntimedExtensionWithTrailerPreservesAllSentences() {
        let stitched = Self.mattCursorEarlier + " " + Self.mattCursorRefined + " " + Self.mattADETrailer
        let expected = stitched
        XCTAssertEqual(XAIStreamingTranscriber.dedupeStitchArtifacts(stitched), expected)
        XCTAssertEqual(XAIStreamingTranscriber.postProcessTranscript(stitched), expected)
    }

    func testMergeStreamingSegmentCursorExtensionRefinement() {
        let merged = XAIStreamingTranscriber.mergeStreamingSegment(
            left: Self.mattCursorEarlier,
            right: Self.mattCursorRefined
        )
        XCTAssertEqual(merged, Self.mattCursorEarlier + " " + Self.mattCursorRefined)
    }

    func testUntimedMiddleSentenceIsNotDeleted() {
        let stitched = Self.mattCursorEarlier + " " + Self.mattCursorRefined + " " + Self.mattADETrailer
        let collapsed = XAIStreamingTranscriber.collapseNearDuplicateTail(stitched)
        XCTAssertEqual(collapsed, stitched)
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

    func testUntimedShortClauseExtensionPreservesBothSentences() {
        let stitched = Self.mattConnectCursorStub + " " + Self.mattConnectCursorNotion
        XCTAssertEqual(
            XAIStreamingTranscriber.dedupeStitchArtifacts(stitched),
            stitched
        )
        XCTAssertEqual(
            XAIStreamingTranscriber.postProcessTranscript(stitched),
            stitched
        )
    }

    func testMergeStreamingSegmentShortClauseExtension() {
        let merged = XAIStreamingTranscriber.mergeStreamingSegment(
            left: Self.mattConnectCursorStub,
            right: Self.mattConnectCursorNotion
        )
        XCTAssertEqual(merged, Self.mattConnectCursorStub + " " + Self.mattConnectCursorNotion)
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
        // Unfinished fragments retain exact suffix/prefix chunk stitching.
        let left = "I'm wondering about setup How do I connect Cursor"
        let right = "How do I connect Cursor into Notion"
        let merged = XAIStreamingTranscriber.mergeStreamingSegment(left: left, right: right)
        XCTAssertEqual(merged, "I'm wondering about setup How do I connect Cursor into Notion")
        XCTAssertFalse(merged.contains("Cursor How do I connect"))
    }
}
