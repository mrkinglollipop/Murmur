import XCTest
@testable import Voice

final class XAIIngestionCoverageTests: XCTestCase {
    private func partial(_ text: String, final: Bool = false, speechFinal: Bool = false,
                         words: [[String: Any]]? = nil) throws -> String {
        var event: [String: Any] = ["type": "transcript.partial", "text": text,
                                    "is_final": final, "speech_final": speechFinal]
        if let words { event["words"] = words }
        return String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
    }

    func testMalformedEventsLatchRecoveryWithoutDiscardingTranscript() throws {
        for malformed in ["not json", "[]", "{}", #"{"type":12}"#] {
            let session = XAIStreamingTranscriber(apiKey: "unused")
            session.handleServerEvent(try partial("Keep this text"))
            session.handleServerEvent(malformed)
            XCTAssertTrue(session.requiresBufferedAudioRecovery)
            XCTAssertTrue(session.hasEverHadNonEmptyStreamText)
            XCTAssertEqual(session.joinedTranscriptSnapshot(), "Keep this text")
        }
    }

    func testUnknownEventsDoNotCorruptOrFailTheStream() throws {
        let session = XAIStreamingTranscriber(apiKey: "unused")
        session.handleServerEvent(try partial("Keep this text"))
        session.handleServerEvent(#"{"type":"future.keepalive","text":"not a transcript"}"#)
        XCTAssertEqual(session.joinedTranscriptSnapshot(), "Keep this text")
        XCTAssertFalse(session.requiresBufferedAudioRecovery)
    }

    func testMissingNonStringAndEmptyPartialTextPreservePriorInterim() throws {
        let session = XAIStreamingTranscriber(apiKey: "unused")
        var previews: [String] = []
        session.onInterim = { previews.append($0) }
        session.handleServerEvent(try partial("café 👋"))
        for event in [#"{"type":"transcript.partial"}"#, #"{"type":"transcript.partial","text":42}"#,
                      #"{"type":"transcript.partial","text":""}"#] {
            session.handleServerEvent(event)
            XCTAssertEqual(session.joinedTranscriptSnapshot(), "café 👋")
        }
        XCTAssertEqual(previews, Array(repeating: "café 👋", count: 4))
        XCTAssertFalse(session.requiresBufferedAudioRecovery)
    }

    func testWhitespaceOnlyFinalDoesNotCreateSpeech() throws {
        let session = XAIStreamingTranscriber(apiKey: "unused")
        session.handleServerEvent(try partial(" \n\t ", final: true, speechFinal: true))
        XCTAssertEqual(session.joinedTranscriptSnapshot().trimmingCharacters(in: .whitespacesAndNewlines), "")
        // Bug: handleServerEvent marks everHadNonEmptyStreamText before
        // trimming a final partial; whitespace can defeat the silence bypass.
        XCTExpectFailure("Whitespace-only xAI final incorrectly counts as speech") {
            XCTAssertFalse(session.hasEverHadNonEmptyStreamText)
        }
    }

    func testSpeechFinalCumulativeTextReplacesEarlierChunkWithoutDuplication() throws {
        let session = XAIStreamingTranscriber(apiKey: "unused")
        session.handleServerEvent(try partial("hello world", final: true))
        session.handleServerEvent(try partial("Hello world again", final: true, speechFinal: true,
                                              words: [["text": "Hello", "start": 0, "end": 0.5],
                                                      ["text": "world", "start": 0.5, "end": 1],
                                                      ["text": "again", "start": 1, "end": 1.5]]))
        XCTAssertEqual(session.joinedTranscriptSnapshot(), "Hello world again")
        XCTAssertTrue(session.hasEverHadNonEmptyStreamText)
        XCTAssertFalse(session.requiresBufferedAudioRecovery)
    }

    func testDoneWithMissingTextKeepsUnfinalizedTailAndResetsAfterFinalize() async throws {
        let session = XAIStreamingTranscriber(apiKey: "unused")
        session.handleServerEvent(try partial("first words", final: true))
        session.handleServerEvent(try partial("another tail"))
        session.handleServerEvent(#"{"type":"transcript.done"}"#)
        XCTAssertEqual(session.joinedTranscriptSnapshot(), "first words another tail")
        let result = await session.finalize()
        XCTAssertEqual(result, "first words another tail")
        XCTAssertEqual(session.joinedTranscriptSnapshot(), "")
        XCTAssertFalse(session.hasEverHadNonEmptyStreamText)
        XCTAssertFalse(session.requiresBufferedAudioRecovery)
    }

    func testCorrectedDoneDoesNotReappendStaleInterim() async throws {
        let session = XAIStreamingTranscriber(apiKey: "unused")
        session.handleServerEvent(try partial("Send invoice to Alice."))
        session.handleServerEvent(#"{"type":"transcript.done","text":"Send invoice to Robert."}"#)
        let snapshot = session.joinedTranscriptSnapshot()
        let result = await session.finalize()
        // R-56: transcript.done assigns confirmedText without clearing
        // latestInterim, so the pre-resolved finalize path appends the old name.
        XCTExpectFailure("R-56: corrected transcript.done retains stale interim text") {
            XCTAssertEqual(snapshot, "Send invoice to Robert.")
            XCTAssertEqual(result, "Send invoice to Robert.")
        }
    }

    func testParseWordsAcceptsNumericTimestampsAndSkipsMalformedEntries() {
        let words = XAIStreamingTranscriber.parseWords(from: ["words": [
            ["text": "café", "start": 0, "end": 0.5],
            ["text": "世界", "start": NSNumber(value: 0.5), "end": NSNumber(value: 1)],
            ["text": "missing end", "start": 1],
            ["text": 42, "start": 1, "end": 2],
            ["text": "string timestamp", "start": "1", "end": 2],
            ["text": "null", "start": NSNull(), "end": 2]
        ]])
        XCTAssertEqual(words, [TranscriptWord(text: "café", start: 0, end: 0.5),
                               TranscriptWord(text: "世界", start: 0.5, end: 1)])
        XCTAssertEqual(XAIStreamingTranscriber.parseWords(from: [:]), [])
        XCTAssertEqual(XAIStreamingTranscriber.parseWords(from: ["words": "invalid"]), [])
    }

    func testEmptyIncomingSegmentPreservesTimestampState() {
        let committed = [TranscriptWord(text: "hello", start: 0, end: 1)]
        let result = XAIStreamingTranscriber.mergeSegmentIntoConfirmed(
            confirmed: "hello", text: "", incomingWords: [TranscriptWord(text: "noise", start: 1, end: 2)],
            committedWords: committed, lastCommittedEnd: 1)
        XCTAssertEqual(result.confirmedText, "hello")
        XCTAssertEqual(result.committedWords, committed)
        XCTAssertEqual(result.lastCommittedEnd, 1)
    }

    func testTimestampBoundaryIsInclusiveAndOverlapsDoNotAdvanceWatermark() {
        let committed = [TranscriptWord(text: "first", start: 0, end: 1)]
        let incoming = [TranscriptWord(text: "overlap", start: 0.99, end: 8),
                        TranscriptWord(text: "next", start: 1, end: 2)]
        let result = XAIStreamingTranscriber.mergeSegmentIntoConfirmed(
            confirmed: "first", text: "next", incomingWords: incoming,
            committedWords: committed, lastCommittedEnd: 1)
        XCTAssertEqual(result.confirmedText, "first next")
        XCTAssertEqual(result.committedWords, committed + [incoming[1]])
        XCTAssertEqual(result.lastCommittedEnd, 2)
    }
}
