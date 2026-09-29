import XCTest
@testable import Voice

final class MuseLiveTests: XCTestCase {

    func testHandshakeJSONEncoding() throws {
        let json = MuseLiveTranscriber.makeHandshakeJSON(
            apiKey: "test-key-value",
            language: "en",
            keywords: ["Murmur", "Swift"]
        )
        let data = try XCTUnwrap(json.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let auth = try XCTUnwrap(root["authorization"] as? [String: Any])
        XCTAssertEqual(auth["accessToken"] as? String, "Bearer test-key-value")
        XCTAssertEqual(root["audioEncoding"] as? String, "PCM_16KHZ")
        XCTAssertEqual(root["model"] as? String, "muse-voice-transcribe-1.0")
        XCTAssertEqual(root["mode"] as? String, "PUSH_TO_TALK")
        XCTAssertEqual(root["partialMode"] as? String, "CUMULATIVE")
        XCTAssertEqual(root["keywords"] as? [String], ["Murmur", "Swift"])
    }

    func testEndStreamJSON() throws {
        let json = MuseLiveTranscriber.makeEndStreamJSON()
        let data = try XCTUnwrap(json.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["type"] as? String, "endStream")
    }

    func testBuildSocketURLIncludesSessionId() {
        let url = MuseLiveTranscriber.buildSocketURL(sessionId: "abc-123")
        XCTAssertEqual(url?.host, "api.meta.ai")
        XCTAssertTrue(url?.absoluteString.contains("sessionId=abc-123") == true)
    }

    func testSelectKeywordsCapsAndPrefersFixCount() {
        var entries: [DictionaryEntry] = []
        for index in 0..<60 {
            entries.append(DictionaryEntry(term: "term\(index)", variants: [], fixCount: index))
        }
        let selected = MuseLiveTranscriber.selectKeywords(from: entries)
        XCTAssertEqual(selected.count, MuseLiveTranscriber.maxKeywords)
        XCTAssertEqual(selected.first, "term59")
    }

    func testStalledSetupSendTimesOutWithinReadinessWindow() async {
        let transcriber = MuseLiveTranscriber(
            apiKey: "test-key",
            readinessTimeoutSeconds: 0.3,
            messageSender: { _ in
                // Never returns and ignores cancellation — a stalled connect. The
                // injected sender replaces the socket, so start() stays off the network.
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
        )
        let started = Date()
        do {
            try await transcriber.start()
            XCTFail("start() must not succeed while the setup send is stalled")
        } catch {
            XCTAssertTrue(error is CloudTranscriptionError)
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            3.0,
            "a stalled setup send must be bounded by the readiness window"
        )
    }

    func testCumulativePartialAfterFinalDoesNotDoubleCommittedHead() {
        let transcriber = MuseLiveTranscriber(apiKey: "key")
        transcriber.handleServerEvent(#"{"type":"transcript","transcript":"send the report","final":true}"#)
        transcriber.handleServerEvent(#"{"type":"transcript","transcript":"Send the report to Dana","final":false}"#)
        XCTAssertEqual(transcriber.joinedTranscriptSnapshot(), "Send the report to Dana")
    }

    func testJoinedTranscriptStillAppendsUnrelatedPartialAndKeepsContainedOne() {
        XCTAssertEqual(
            MuseLiveTranscriber.joinedTranscript(segments: ["hello world"], partial: "second thought"),
            "hello world second thought"
        )
        XCTAssertEqual(
            MuseLiveTranscriber.joinedTranscript(segments: ["hello world again"], partial: "hello world"),
            "hello world again"
        )
    }

    func testTranscriptEventPartial() {
        let transcriber = MuseLiveTranscriber(apiKey: "key")
        transcriber.handleServerEvent("""
        {"type":"transcript","transcript":"hello world","final":false}
        """)
        XCTAssertEqual(transcriber.joinedTranscriptSnapshot(), "hello world")
        XCTAssertTrue(transcriber.hasEverHadNonEmptyStreamText)
    }

    func testTranscriptEventFinal() {
        let transcriber = MuseLiveTranscriber(apiKey: "key")
        transcriber.handleServerEvent("""
        {"type":"transcript","transcript":"hello world","final":true}
        """)
        XCTAssertEqual(transcriber.joinedTranscriptSnapshot(), "hello world")
    }

    func testFinalTranscriptReplacesLongerSpeculativePartial() {
        let session = MuseLiveTranscriber(apiKey: "key")
        session.handleServerEvent("""
        {"type":"transcript","transcript":"It's just an absolute joke.","final":false}
        """)
        session.handleServerEvent("""
        {"type":"transcript","transcript":"It's just an ad.","final":true}
        """)
        XCTAssertEqual(session.joinedTranscriptSnapshot(), "It's just an ad.")
    }

    func testFinalizeWaitsForSpeechCompleteAfterSegmentFinal() async {
        let session = MuseLiveTranscriber(apiKey: "key")
        let probe = MuseCompletionProbe()
        let finalizer = Task {
            let text = await session.finalize(recordingDuration: 0)
            await probe.finish(text)
            return text
        }
        // Beyond the baseline's 600ms pre-signal sleep: the control then
        // exposes its segment-final early-resolution bug.
        try? await Task.sleep(nanoseconds: 700_000_000)
        session.handleServerEvent("""
        {"type":"transcript","transcript":"segment final","final":true}
        """)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let completedBeforeSessionFinal = await probe.isComplete()
        XCTAssertFalse(completedBeforeSessionFinal)

        session.handleServerEvent("""
        {"type":"speechComplete","transcript":"full turn text"}
        """)
        let finalized = await finalizer.value
        XCTAssertEqual(finalized, "full turn text")
    }

    func testHandshakeAckEventHasNoTypeField() {
        let transcriber = MuseLiveTranscriber(apiKey: "key")
        transcriber.handleServerEvent("{\"sessionId\":\"sess-1\"}")
        XCTAssertEqual(transcriber.joinedTranscriptSnapshot(), "")
    }

    func testSpeechCompleteEvent() {
        let transcriber = MuseLiveTranscriber(apiKey: "key")
        transcriber.handleServerEvent("""
        {"type":"speechComplete","transcript":"full turn text"}
        """)
        XCTAssertEqual(transcriber.joinedTranscriptSnapshot(), "full turn text")
    }

    func testBatchDecodeTranscript() throws {
        let data = Data("{\"transcript\":\"hello there\"}".utf8)
        XCTAssertEqual(MuseBatchDecode.decodeTranscript(from: data), "hello there")
    }

    func testJoinedTranscriptDeduplicatesContainedPartial() {
        let joined = MuseLiveTranscriber.joinedTranscript(
            segments: ["hello world"],
            partial: "world"
        )
        XCTAssertEqual(joined, "hello world")
    }
}

private actor MuseCompletionProbe {
    private var completed = false

    func finish(_ text: String) {
        _ = text
        completed = true
    }

    func isComplete() -> Bool { completed }
}
