import XCTest
@testable import Voice

final class GeminiLiveTests: XCTestCase {

    func testSetupJSONManualOmitsVADSensitivityFields() throws {
        let json = GeminiLiveOptions.makeSetupMessageJSON(
            language: "en",
            smartMode: true,
            vocabulary: ["Murmur"],
            options: .defaults
        )
        let data = try XCTUnwrap(json.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let setup = try XCTUnwrap(root["setup"] as? [String: Any])
        let realtime = try XCTUnwrap(setup["realtimeInputConfig"] as? [String: Any])
        let aad = try XCTUnwrap(realtime["automaticActivityDetection"] as? [String: Any])
        XCTAssertEqual(aad["disabled"] as? Bool, true)
        XCTAssertNil(aad["startOfSpeechSensitivity"])
        XCTAssertNil(aad["prefixPaddingMs"])
        let transcription = try XCTUnwrap(setup["inputAudioTranscription"] as? [String: Any])
        XCTAssertEqual(transcription["mode"] as? String, "SMART")
        XCTAssertEqual(transcription["languageCodes"] as? [String], ["en-US"])
        XCTAssertEqual(transcription["customVocabulary"] as? [String], ["Murmur"])
        XCTAssertFalse(json.contains("SECRET_KEY"))
    }

    func testSetupJSONAutomaticIncludesVADFields() throws {
        var options = GeminiLiveOptions.defaults
        options.vadMode = .automatic
        let json = GeminiLiveOptions.makeSetupMessageJSON(
            language: "en",
            smartMode: false,
            vocabulary: [],
            options: options
        )
        let data = try XCTUnwrap(json.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let setup = try XCTUnwrap(root["setup"] as? [String: Any])
        let transcription = try XCTUnwrap(setup["inputAudioTranscription"] as? [String: Any])
        XCTAssertEqual(transcription["mode"] as? String, "VERBATIM")
        let realtime = try XCTUnwrap(setup["realtimeInputConfig"] as? [String: Any])
        let aad = try XCTUnwrap(realtime["automaticActivityDetection"] as? [String: Any])
        XCTAssertEqual(aad["disabled"] as? Bool, false)
        XCTAssertEqual(aad["startOfSpeechSensitivity"] as? String, "START_SENSITIVITY_HIGH")
        XCTAssertEqual(aad["endOfSpeechSensitivity"] as? String, "END_SENSITIVITY_HIGH")
        XCTAssertEqual(aad["prefixPaddingMs"] as? Int, 20)
        XCTAssertEqual(aad["silenceDurationMs"] as? Int, 100)
    }

    func testManualPTTFrames() throws {
        let start = GeminiLiveOptions.makeActivityStartFrameJSON()
        XCTAssertTrue(start.contains("activityStart"))
        let end = GeminiLiveOptions.makeActivityEndFrameJSON()
        XCTAssertTrue(end.contains("activityEnd"))
        let audio = GeminiLiveOptions.makeAudioFrameJSON(pcmData: Data([0, 1]))
        let audioJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(audio.utf8)) as? [String: Any])
        let realtime = try XCTUnwrap(audioJSON["realtimeInput"] as? [String: Any])
        let audioNode = try XCTUnwrap(realtime["audio"] as? [String: Any])
        XCTAssertEqual(audioNode["mimeType"] as? String, "audio/pcm;rate=16000")
    }

    func testHybridAudioStreamEndFrame() {
        let frame = GeminiLiveOptions.makeAudioStreamEndFrameJSON()
        XCTAssertTrue(frame.contains("audioStreamEnd"))
    }

    func testSelectVocabularyCapsAt100AndPrefersFixCount() {
        var entries: [DictionaryEntry] = []
        for index in 0..<120 {
            entries.append(DictionaryEntry(term: "term\(index)", variants: [], fixCount: index))
        }
        let selected = GeminiLiveTranscriber.selectVocabulary(from: entries)
        XCTAssertEqual(selected.count, 100)
        XCTAssertEqual(selected.first, "term119")
    }

    func testJoinedTranscriptDeduplicatesContainedPartial() {
        let joined = GeminiLiveTranscriber.joinedTranscript(
            segments: ["hello world"],
            partial: "world"
        )
        XCTAssertEqual(joined, "hello world")
    }

    func testBuildSocketURLHostPathAndKeyQuery() {
        let url = GeminiLiveTranscriber.buildSocketURL(apiKey: "test-key-value")
        XCTAssertEqual(url?.host, "generativelanguage.googleapis.com")
        XCTAssertTrue(url?.path.contains("BidiGenerateContent") == true)
        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "key" })?.value, "test-key-value")
    }

    func testSessionCapHelper() {
        XCTAssertFalse(GeminiLiveTranscriber.sessionCapExceeded(elapsed: 580))
        XCTAssertTrue(GeminiLiveTranscriber.sessionCapExceeded(elapsed: 581))
    }

    func testBatchDecodeOutputText() throws {
        let data = Data("{\"output_text\":\"hello\"}".utf8)
        XCTAssertEqual(GeminiBatchDecode.decodeTranscript(from: data), "hello")
    }

    func testServerErrorMakesFinalizeShortCircuit() async {
        let transcriber = GeminiLiveTranscriber(apiKey: "test-key-value")
        transcriber.handleServerEvent("{\"error\":{\"code\":400,\"message\":\"PERMISSION_DENIED\"}}")
        let started = Date()
        let text = await transcriber.finalize(recordingDuration: 10)
        XCTAssertEqual(text, "")
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            1.5,
            "server error must not wait out the finalize timeout"
        )
    }

    func testBatchRequestBodyRespectsFillerAndVocabulary() throws {
        let verbatim = GeminiLiveOptions.makeBatchRequestBody(
            wavBase64: "AA==",
            mimeType: "audio/wav",
            smartMode: false,
            vocabulary: ["Murmur"]
        )
        XCTAssertEqual(verbatim["model"] as? String, "gemini-3.5-transcribe")
        let config = try XCTUnwrap(
            (verbatim["generation_config"] as? [String: Any])?["transcription_config"] as? [String: Any]
        )
        XCTAssertEqual((config["mode"] as? [String: Any])?["type"] as? String, "verbatim")
        XCTAssertEqual(config["custom_vocabulary"] as? [String], ["Murmur"])

        let smartEmpty = GeminiLiveOptions.makeBatchRequestBody(
            wavBase64: "AA==",
            mimeType: "audio/wav",
            smartMode: true,
            vocabulary: []
        )
        let smartConfig = try XCTUnwrap(
            (smartEmpty["generation_config"] as? [String: Any])?["transcription_config"] as? [String: Any]
        )
        XCTAssertEqual((smartConfig["mode"] as? [String: Any])?["type"] as? String, "smart")
        XCTAssertNil(smartConfig["custom_vocabulary"])
    }

    func testBCP47LanguageCodesMapISO6391() {
        XCTAssertEqual(GeminiLiveOptions.bcp47LanguageCodes(from: "en"), ["en-US"])
        XCTAssertEqual(GeminiLiveOptions.bcp47LanguageCodes(from: "en-GB"), ["en-GB"])
        XCTAssertEqual(GeminiLiveOptions.bcp47LanguageCodes(from: ""), [])
        XCTAssertEqual(GeminiLiveOptions.bcp47LanguageCodes(from: "xx"), [])
    }

    func testBinaryWebSocketPayloadDecodesAsUTF8JSON() {
        let binary = Data("{\"setupComplete\":{}}\n".utf8)
        XCTAssertEqual(
            GeminiLiveTranscriber.utf8JSONText(fromWebSocketData: binary),
            "{\"setupComplete\":{}}\n"
        )
    }

    func testBatchDecodeStepsContentText() {
        let stepsBody = Data("""
        {"status":"completed","steps":[{"content":[{"type":"text","text":"hello from steps"}]}]}
        """.utf8)
        XCTAssertEqual(GeminiBatchDecode.decodeTranscript(from: stepsBody), "hello from steps")
    }
}
