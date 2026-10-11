import AVFoundation
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
        XCTAssertFalse(session.hasEverHadNonEmptyStreamText)
    }

    private func whitespaceSession() throws -> XAIStreamingTranscriber {
        let session = XAIStreamingTranscriber(apiKey: "unused", finalizeBudgetOverride: 0.01)
        for text in [" \n\t ", "\r\n", "\u{00a0}\u{2003}"] {
            session.handleServerEvent(try partial(text, final: true, speechFinal: true))
        }
        return session
    }

    func testWhitespaceOnlyFinalsStayEmptyAcrossFinalizePaths() async throws {
        for path in ["done", "timeout", "error", "sendFailure"] {
            let session: XAIStreamingTranscriber
            if path == "sendFailure" {
                session = XAIStreamingTranscriber(apiKey: "unused", messageSender: { _ in
                    throw URLError(.cannotConnectToHost)
                })
                session.handleServerEvent(try partial(" \n\t ", final: true))
            } else {
                session = try whitespaceSession()
            }
            if path == "done" {
                session.handleServerEvent(#"{"type":"transcript.done","text":" \t\n "}"#)
            } else if path == "error" {
                session.handleServerEvent(#"{"type":"error","message":"fixture"}"#)
            }
            XCTAssertFalse(session.hasEverHadNonEmptyStreamText, path)
            XCTAssertEqual(session.joinedTranscriptSnapshot().trimmingCharacters(in: .whitespacesAndNewlines), "", path)
            let result = await session.finalize()
            XCTAssertEqual(result, "", path)
            XCTAssertFalse(session.hasEverHadNonEmptyStreamText, path)
            XCTAssertEqual(session.joinedTranscriptSnapshot(), "", path)
            let repeatedResult = await session.finalize()
            XCTAssertEqual(repeatedResult, "", path)
            XCTAssertEqual(session.requiresBufferedAudioRecovery, path != "done", path)
        }
    }

    func testWhitespacePartialAndFinalPreserveRealInterim() async throws {
        for final in [false, true] {
            let session = XAIStreamingTranscriber(apiKey: "unused")
            session.handleServerEvent(try partial("Keep these words"))
            session.handleServerEvent(try partial(" \n\t ", final: final, speechFinal: final))
            XCTAssertEqual(session.joinedTranscriptSnapshot(), "Keep these words")
            XCTAssertTrue(session.hasEverHadNonEmptyStreamText)
            session.handleServerEvent(#"{"type":"transcript.done"}"#)
            let result = await session.finalize()
            XCTAssertEqual(result, "Keep these words")
        }
    }

    func testWhitespaceInterimDoesNotCreateSpeech() throws {
        let session = XAIStreamingTranscriber(apiKey: "unused")
        session.handleServerEvent(try partial(" \n\t "))
        XCTAssertFalse(session.hasEverHadNonEmptyStreamText)
        XCTAssertEqual(session.joinedTranscriptSnapshot(), "")
    }

    private func audioBuffer(seconds: Double) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(frames))
        return buffer
    }

    func testWhitespaceOnlyFinalsTakeSameTinyHoldSilencePathAsNoTranscript() async throws {
        for seconds in [0.0, 0.33, StreamingCoordinator.silenceCancelMaxBufferedSeconds] {
            for whitespace in [false, true] {
                let session = whitespace ? try whitespaceSession() : XAIStreamingTranscriber(apiKey: "unused")
                session.handleServerEvent(#"{"type":"transcript.done"}"#)
                let coordinator = StreamingCoordinator(xaiSession: session)
                let buffers = seconds == 0 ? [] : [try audioBuffer(seconds: seconds)]
                let stopped = expectation(description: "empty tiny hold stopped")
                var silences = 0
                XCTAssertTrue(coordinator.handleStopXAI(
                    context: .init(duration: seconds, hadSpeech: false, bufferedAudio: buffers, streamTextEver: false),
                    onSilence: { silences += 1; stopped.fulfill() },
                    onStreamSuccess: { _ in XCTFail("Whitespace must not be stream success"); stopped.fulfill() },
                    onBatchFallback: { _, _ in XCTFail("Empty tiny holds must not enter batch"); stopped.fulfill() }
                ))
                await fulfillment(of: [stopped], timeout: 2)
                XCTAssertEqual(silences, 1)
                XCTAssertNil(coordinator.xaiSession)
            }
        }
    }

    private struct EmptyCloud: CloudTranscriptionService {
        func transcribe(audioURL: URL, apiKey: String, model: CloudModel, language: String) async throws -> String {
            try XAITranscriptionService.decodeTranscript(from: Data(#"{"text":" \t\n "}"#.utf8))
        }
    }

    private struct LocalStub: ASREngine {
        let id = "whitespace-local-stub"
        let displayName = "Whitespace local stub"
        let text: String
        func transcribe(audioURL: URL) async throws -> String { text }
    }

    @MainActor
    func testWhitespaceOnlyFinalsPreserveBatchRecoveryAndHistoryLikeNoTranscript() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent(".xai-whitespace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("audio.caf")
        try Data([1, 2, 3, 4]).write(to: audioURL)
        for recoveredText in [" \n\t ", "Recovered quiet speech."] {
            for whitespace in [false, true] {
                let historyURL = directory.appendingPathComponent("\(UUID().uuidString).json")
                let history = HistoryStore(fileURL: historyURL)
                let session = whitespace ? try whitespaceSession() : XAIStreamingTranscriber(apiKey: "unused")
                session.handleServerEvent(#"{"type":"transcript.done"}"#)
                XCTAssertFalse(session.hasEverHadNonEmptyStreamText)
                let coordinator = StreamingCoordinator(xaiSession: session)
                let selector = ASREngineSelector()
                selector.cloudModel = .xaiGrokSTT
                selector.apiKeyProvider = { _ in "dummy-test-key" }
                let pipeline = selector.pipeline
                pipeline.cleanupEnabled = false
                pipeline.cloudServiceProvider = { _ in EmptyCloud() }
                pipeline.localEngineProvider = { LocalStub(text: recoveredText) }
                pipeline.onTranscriptionLogged = { text, engine, injected, path, failed, replacement in
                    history.append(text: text, engine: engine, injected: injected, audioPath: path,
                                   failed: failed, replaceEntryID: replacement)
                }
                pipeline.onAbandonedHoldSaved = { text, engine, path in
                    history.append(text: text, engine: engine, injected: false, audioPath: path,
                                   savedWithoutInsertion: true)
                }
                pipeline.onFailure = { _ in XCTFail("Empty batch recovery must stay quiet") }
                pipeline.onTextInserted = { _ in XCTFail("Background recovery must not inject") }
                let token = pipeline.test_holdSnapshot(.unknown)
                let completed = expectation(description: "empty stream recovered through batch and History")
                let buffer = try audioBuffer(seconds: 1.93)
                var fallbacks = 0
                XCTAssertTrue(coordinator.handleStopXAI(
                    context: .init(duration: 1.93, hadSpeech: false, bufferedAudio: [buffer], streamTextEver: false),
                    onSilence: { XCTFail("Quiet buffered audio must be rescued"); completed.fulfill() },
                    onStreamSuccess: { _ in XCTFail("Whitespace must not reach stream success"); completed.fulfill() },
                    onBatchFallback: { buffers, duration in
                        fallbacks += 1
                        XCTAssertEqual(buffers.count, 1)
                        XCTAssertTrue(buffers.first === buffer)
                        XCTAssertEqual(duration, 1.93)
                        pipeline.transcribeAndLog(audioURL: audioURL, sessionHeldToken: token) { result in
                            XCTAssertEqual(result, recoveredText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                           ? .failed : .savedToHistory)
                            completed.fulfill()
                        }
                    }
                ))
                await fulfillment(of: [completed], timeout: 3)
                XCTAssertEqual(fallbacks, 1)
                XCTAssertNil(coordinator.xaiSession)
                let entry = try XCTUnwrap(history.entries.first)
                XCTAssertEqual(history.entries.count, 1)
                XCTAssertFalse(entry.injected)
                XCTAssertEqual(entry.audioPath, audioURL.path)
                XCTAssertEqual(entry.failed, recoveredText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                XCTAssertEqual(entry.savedWithoutInsertion, !entry.failed)
                XCTAssertEqual(entry.text, entry.failed ? HistoryEntry.failedPlaceholderText : recoveredText)
                history.flush()
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = .sortedKeys
                XCTAssertEqual(try encoder.encode(HistoryStore(fileURL: historyURL).entries),
                               try encoder.encode(history.entries))
            }
        }
    }

    func testOtherRealtimeProvidersIgnoreWhitespaceFinals() {
        let eleven = ElevenLabsRealtimeTranscriber(apiKey: "unused")
        eleven.handleServerEvent(#"{"message_type":"committed_transcript","text":" \t\n "}"#)
        XCTAssertFalse(eleven.hasEverHadNonEmptyStreamText)
        XCTAssertEqual(eleven.joinedTranscriptSnapshot(), "")
        eleven.cancel()

        let gemini = GeminiLiveTranscriber(apiKey: "unused")
        gemini.handleServerEvent(#"{"serverContent":{"inputTranscription":{"text":" \t\n "},"turnComplete":true}}"#)
        XCTAssertFalse(gemini.hasEverHadNonEmptyStreamText)
        XCTAssertEqual(gemini.joinedTranscriptSnapshot(), "")
        gemini.cancel()

        let muse = MuseLiveTranscriber(apiKey: "unused")
        muse.handleServerEvent(#"{"type":"transcript","transcript":" \t\n ","final":true}"#)
        muse.handleServerEvent(#"{"type":"speechComplete","transcript":" \t\n "}"#)
        XCTAssertFalse(muse.hasEverHadNonEmptyStreamText)
        XCTAssertEqual(muse.joinedTranscriptSnapshot(), "")
        muse.cancel()
    }

    func testSpeechFinalCumulativeTextReplacesEarlierChunkWithoutDuplication() throws {
        let session = XAIStreamingTranscriber(apiKey: "unused")
        session.handleServerEvent(try partial("hello world", final: true,
                                              words: [["text": "hello", "start": 0, "end": 0.5],
                                                      ["text": "world", "start": 0.5, "end": 1]]))
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
        XCTAssertTrue(session.requiresBufferedAudioRecovery, "Ambiguous untimed final and interim require recovery after reset.")
    }

    func testCorrectedDoneDoesNotReappendStaleInterim() async throws {
        let session = XAIStreamingTranscriber(apiKey: "unused")
        session.handleServerEvent(try partial("Send invoice to Alice."))
        session.handleServerEvent(#"{"type":"transcript.done","text":"Send invoice to Robert."}"#)
        let snapshot = session.joinedTranscriptSnapshot()
        let result = await session.finalize()
        XCTAssertEqual(snapshot, "Send invoice to Robert.")
        XCTAssertEqual(result, "Send invoice to Robert.")
    }

    func testAmbiguousDoneHandsConservativeTextToBufferedRecovery() async throws {
        let session = XAIStreamingTranscriber(apiKey: "unused")
        session.handleServerEvent(try partial("I will send the report tomorrow.", final: true, speechFinal: true,
                                              words: [["text": "I", "start": 0, "end": 0.1],
                                                      ["text": "will", "start": 0.1, "end": 0.3],
                                                      ["text": "send", "start": 0.3, "end": 0.5],
                                                      ["text": "the", "start": 0.5, "end": 0.6],
                                                      ["text": "report", "start": 0.6, "end": 0.9],
                                                      ["text": "tomorrow", "start": 0.9, "end": 1.2]]))
        session.handleServerEvent(#"{"type":"transcript.done","text":"I will send the report only after approval."}"#)
        let conservative = "I will send the report tomorrow."
        XCTAssertEqual(session.joinedTranscriptSnapshot(), conservative)
        XCTAssertTrue(session.requiresBufferedAudioRecovery)

        let coordinator = StreamingCoordinator(xaiSession: session)
        let buffer = try audioBuffer(seconds: 1.0)
        let handedOff = expectation(description: "ambiguous done handed to buffered recovery")
        XCTAssertTrue(coordinator.handleStopXAI(
            context: .init(duration: 1.0, hadSpeech: true, bufferedAudio: [buffer], streamTextEver: true),
            onSilence: { XCTFail("Nonempty conservative text must not be discarded") },
            onStreamSuccess: { _ in XCTFail("Ambiguous done must not be delivered as stream success") },
            onBatchFallback: { buffers, duration in
                XCTAssertEqual(buffers.count, 1)
                XCTAssertTrue(buffers.first === buffer)
                XCTAssertEqual(duration, 1.0)
                handedOff.fulfill()
            }
        ))
        await fulfillment(of: [handedOff], timeout: 2)
        XCTAssertNil(coordinator.xaiSession)
    }

    func testAmbiguousDoneFinalizePreservesConservativeText() async throws {
        let session = XAIStreamingTranscriber(apiKey: "unused")
        session.handleServerEvent(try partial("I will send the report tomorrow.", final: true, speechFinal: true,
                                              words: [["text": "I", "start": 0, "end": 0.1],
                                                      ["text": "will", "start": 0.1, "end": 0.3],
                                                      ["text": "send", "start": 0.3, "end": 0.5],
                                                      ["text": "the", "start": 0.5, "end": 0.6],
                                                      ["text": "report", "start": 0.6, "end": 0.9],
                                                      ["text": "tomorrow", "start": 0.9, "end": 1.2]]))
        session.handleServerEvent(#"{"type":"transcript.done","text":"I will send the report only after approval."}"#)
        XCTAssertTrue(session.requiresBufferedAudioRecovery)
        let result = await session.finalize()
        XCTAssertEqual(result, "I will send the report tomorrow.")
        XCTAssertTrue(session.requiresBufferedAudioRecovery, "Reset must not clear the recovery latch.")
        XCTAssertEqual(session.joinedTranscriptSnapshot(), "")
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
