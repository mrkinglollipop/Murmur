import AVFoundation
import XCTest
@testable import Voice

/// Covers the pure (non-networked) parts of `ElevenLabsRealtimeTranscriber`:
/// the `input_audio_chunk` frame encoding, server event decoding (the
/// `message_type` discriminator, NOT `type` — differs from xAI's protocol),
/// and committed/partial transcript accumulation. Mirrors the style of
/// `StitchDedupeTests`/`GoldenTranscriptTests` (static-method testing via
/// `@testable import`), but for Scribe RT there is no stitch/dedupe
/// machinery to test — just ordered accumulation.
final class ElevenLabsRealtimeTests: XCTestCase {

    // MARK: - Outbound frame encoding

    func testInputAudioChunkFrameContainsAllRequiredFields() throws {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let frame = ElevenLabsRealtimeTranscriber.makeInputAudioChunkFrame(pcmData: pcm, commit: false)

        let json = try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any]
        XCTAssertEqual(json?["message_type"] as? String, "input_audio_chunk")
        XCTAssertEqual(json?["audio_base_64"] as? String, pcm.base64EncodedString())
        XCTAssertEqual(json?["commit"] as? Bool, false)
        XCTAssertEqual(json?["sample_rate"] as? Int, 16000)
    }

    func testInputAudioChunkFrameCommitTrueOnFinalFrame() throws {
        let frame = ElevenLabsRealtimeTranscriber.makeInputAudioChunkFrame(pcmData: Data(), commit: true)
        let json = try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any]
        XCTAssertEqual(json?["commit"] as? Bool, true)
        XCTAssertEqual(json?["audio_base_64"] as? String, "")
    }

    // MARK: - Server event decoding (message_type discriminator, NOT "type")

    private func decode(_ json: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    }

    func testDecodesPartialTranscriptEvent() {
        let event = decode("""
        {"message_type":"partial_transcript","text":"The first move is what sets"}
        """)
        XCTAssertEqual(event?["message_type"] as? String, "partial_transcript")
        XCTAssertEqual(event?["text"] as? String, "The first move is what sets")
    }

    func testDecodesCommittedTranscriptEvent() {
        let event = decode("""
        {"message_type":"committed_transcript","text":"The first move is what sets everything in motion."}
        """)
        XCTAssertEqual(event?["message_type"] as? String, "committed_transcript")
        XCTAssertEqual(event?["text"] as? String, "The first move is what sets everything in motion.")
    }

    func testDecodesSessionStartedEvent() {
        let event = decode("""
        {"message_type":"session_started","session_id":"abc123","config":{"model_id":"scribe_v2_realtime"}}
        """)
        XCTAssertEqual(event?["message_type"] as? String, "session_started")
        XCTAssertEqual(event?["session_id"] as? String, "abc123")
    }

    // MARK: - joinedTranscript (committed-segment accumulation)

    func testJoinedTranscriptSingleCommittedSegment() {
        let result = ElevenLabsRealtimeTranscriber.joinedTranscript(
            segments: ["The first move is what sets everything in motion."],
            partial: ""
        )
        XCTAssertEqual(result, "The first move is what sets everything in motion.")
    }

    func testJoinedTranscriptMultipleCommittedSegmentsInOrder() {
        // Scribe RT commits are sequential, non-overlapping passages — no
        // stitching/dedup needed, just ordered concatenation.
        let result = ElevenLabsRealtimeTranscriber.joinedTranscript(
            segments: ["We need to finish the report by Friday.", "Then send it to the team."],
            partial: ""
        )
        XCTAssertEqual(result, "We need to finish the report by Friday. Then send it to the team.")
    }

    func testJoinedTranscriptAppendsInFlightPartialTail() {
        // A read taken mid-hold (or a finalize that timed out before the
        // last commit arrived) should still surface the in-progress text.
        let result = ElevenLabsRealtimeTranscriber.joinedTranscript(
            segments: ["We need to finish the report."],
            partial: "Then send it to the"
        )
        XCTAssertEqual(result, "We need to finish the report. Then send it to the")
    }

    func testJoinedTranscriptPartialOnlyBeforeAnyCommit() {
        let result = ElevenLabsRealtimeTranscriber.joinedTranscript(
            segments: [],
            partial: "The first move is what sets"
        )
        XCTAssertEqual(result, "The first move is what sets")
    }

    func testJoinedTranscriptDropsPartialAlreadyContainedInCommitted() {
        // Guards a race where a stale partial arrives just after its own
        // commit event — must not duplicate the tail.
        let result = ElevenLabsRealtimeTranscriber.joinedTranscript(
            segments: ["The first move is what sets everything in motion."],
            partial: "everything in motion"
        )
        XCTAssertEqual(result, "The first move is what sets everything in motion.")
    }

    func testJoinedTranscriptEmptyWhenNothingReceived() {
        XCTAssertEqual(ElevenLabsRealtimeTranscriber.joinedTranscript(segments: [], partial: ""), "")
    }

    // MARK: - Empty commit must not wipe in-flight partial (ghost Class A)

    func testEmptyCommittedTranscriptRetainsPartialAndEverHadLatch() {
        let session = ElevenLabsRealtimeTranscriber(apiKey: "test-key")
        session.handleServerEvent("""
        {"message_type":"partial_transcript","text":"hello there"}
        """)
        XCTAssertTrue(session.hasEverHadNonEmptyStreamText)
        XCTAssertEqual(session.joinedTranscriptSnapshot(), "hello there")

        session.handleServerEvent("""
        {"message_type":"committed_transcript","text":""}
        """)
        XCTAssertTrue(
            session.hasEverHadNonEmptyStreamText,
            "empty commit must not clear everHad latch"
        )
        XCTAssertEqual(
            session.joinedTranscriptSnapshot(),
            "hello there",
            "empty commit must not wipe latestPartial"
        )
    }

    func testEmptyPartialTranscriptRetainsPriorPartialAndEverHadLatch() {
        let session = ElevenLabsRealtimeTranscriber(apiKey: "test-key")
        session.handleServerEvent("""
        {"message_type":"partial_transcript","text":"hello there"}
        """)
        XCTAssertTrue(session.hasEverHadNonEmptyStreamText)
        XCTAssertEqual(session.joinedTranscriptSnapshot(), "hello there")

        session.handleServerEvent("""
        {"message_type":"partial_transcript","text":""}
        """)
        XCTAssertTrue(
            session.hasEverHadNonEmptyStreamText,
            "empty partial must not clear everHad latch"
        )
        XCTAssertEqual(
            session.joinedTranscriptSnapshot(),
            "hello there",
            "empty partial must not wipe latestPartial"
        )

        session.handleServerEvent("""
        {"message_type":"partial_transcript","text":"   "}
        """)
        XCTAssertEqual(
            session.joinedTranscriptSnapshot(),
            "hello there",
            "whitespace-only partial must not wipe latestPartial"
        )
    }

    func testNonEmptyCommittedTranscriptClearsPartial() {
        let session = ElevenLabsRealtimeTranscriber(apiKey: "test-key")
        session.handleServerEvent("""
        {"message_type":"partial_transcript","text":"hello there friend"}
        """)
        session.handleServerEvent("""
        {"message_type":"committed_transcript","text":"hello there friend"}
        """)
        XCTAssertEqual(session.joinedTranscriptSnapshot(), "hello there friend")
        XCTAssertTrue(session.hasEverHadNonEmptyStreamText)
    }

    // MARK: - tornDown / doneContinuation concurrency (audit item E)

    /// A start-failure `cancel()` racing a stop-triggered `finalize()` on the
    /// same session must never leak the `doneContinuation` — either
    /// `cancel()` wins and `finalize()` returns immediately, or `finalize()`
    /// wins and its own bounded (~3s here, since recordingDuration is 0)
    /// timeout resolves it. Neither ordering may hang forever. The
    /// expectation timeout (5s) is well above that bound so a real hang
    /// fails loudly instead of silently passing.
    func testConcurrentCancelAndFinalizeDoesNotHang() {
        let transcriber = ElevenLabsRealtimeTranscriber(apiKey: "test-key")
        let expectation = expectation(description: "finalize completes without hanging")

        Task {
            _ = await transcriber.finalize(recordingDuration: 0)
            expectation.fulfill()
        }
        transcriber.cancel()

        wait(for: [expectation], timeout: 5.0)
    }

    func testRepeatedCancelDoesNotCrash() {
        let transcriber = ElevenLabsRealtimeTranscriber(apiKey: "test-key")
        transcriber.cancel()
        transcriber.cancel()
        transcriber.cancel()
        // Smoke: second/third cancel() must be a no-op under tornDown.
        // Observable state isn't exposed without widening API — assert we
        // can still send after cancel without trapping.
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 1
        transcriber.send(buffer)
        XCTAssertTrue(true, "repeated cancel + send after cancel must not trap")
    }

    func testSendAfterCancelIsSafeNoOp() {
        let transcriber = ElevenLabsRealtimeTranscriber(apiKey: "test-key")
        transcriber.cancel()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 1
        transcriber.send(buffer)
        XCTAssertTrue(true, "send after cancel must return without trapping")
    }

    func testRepeatedFinalizeIsIdempotent() async {
        let transcriber = ElevenLabsRealtimeTranscriber(apiKey: "test-key")
        let first = await transcriber.finalize(recordingDuration: 0)
        let second = await transcriber.finalize(recordingDuration: 0)
        XCTAssertEqual(first, second)
    }
}
