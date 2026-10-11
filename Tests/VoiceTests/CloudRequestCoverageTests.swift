import AVFoundation
import XCTest
@testable import Voice

final class CloudRequestCoverageTests: OfflineHTTPTestCase {
    private var directory: URL!
    private var audioURL: URL!
    private let key = "coverage-dummy-secret"

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent(".coverage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        audioURL = directory.appendingPathComponent("fixture.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        buffer.frameLength = 1600
        for i in 0..<1600 { buffer.floatChannelData?[0][i] = 0.1 * sinf(Float(i) * 0.05) }
        let audio = try AVAudioFile(forWriting: audioURL, settings: format.settings)
        try audio.write(from: buffer)
        audio.close()
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private struct Part {
        let headers: String
        let data: Data
    }

    private func multipart(_ captured: CoverageURLProtocol.Captured) throws -> [String: Part] {
        let type = try XCTUnwrap(captured.request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary="))
        let boundary = try XCTUnwrap(type.components(separatedBy: "boundary=").last)
        XCTAssertFalse(boundary.isEmpty)
        let marker = Data("--\(boundary)".utf8)
        XCTAssertTrue(captured.body.starts(with: Data("--\(boundary)\r\n".utf8)))
        XCTAssertTrue(captured.body.suffix(marker.count + 4).elementsEqual(Data("--\(boundary)--\r\n".utf8)))
        var parts: [String: Part] = [:]
        var cursor = captured.body.startIndex
        while let delimiter = captured.body.range(of: marker, in: cursor..<captured.body.endIndex) {
            let start = delimiter.upperBound
            guard let next = captured.body.range(of: marker, in: start..<captured.body.endIndex) else { break }
            let chunk = Data(captured.body[start..<next.lowerBound])
            let split = try XCTUnwrap(chunk.range(of: Data("\r\n\r\n".utf8)))
            let headers = String(decoding: chunk[..<split.lowerBound], as: UTF8.self)
            let namePrefix = try XCTUnwrap(headers.range(of: "name=\""))
            let nameTail = headers[namePrefix.upperBound...]
            let nameEnd = try XCTUnwrap(nameTail.firstIndex(of: "\""))
            let name = String(nameTail[..<nameEnd])
            XCTAssertNil(parts[name], "duplicate multipart field \(name)")
            parts[name] = Part(headers: headers, data: Data(chunk[split.upperBound..<chunk.endIndex - 2]))
            cursor = next.lowerBound
        }
        return parts
    }

    private func assertMultipart(_ request: CoverageURLProtocol.Captured, fields: [String: String],
                                 audioField: String = "file") throws {
        let parts = try multipart(request)
        XCTAssertEqual(Set(parts.keys), Set(fields.keys).union([audioField]))
        for (name, value) in fields {
            XCTAssertEqual(parts[name].map { String(decoding: $0.data, as: UTF8.self) }, value)
        }
        let audio = try XCTUnwrap(parts[audioField])
        XCTAssertTrue(audio.headers.contains("filename=\"\(CloudAudioTranscoder.uploadFileName)\""))
        XCTAssertTrue(audio.headers.contains("Content-Type: \(CloudAudioTranscoder.uploadMimeType)"))
        XCTAssertEqual(audio.data.prefix(4), Data("RIFF".utf8))
        XCTAssertGreaterThan(audio.data.count, 44)
        XCTAssertFalse(request.body.range(of: Data(key.utf8)) != nil)
    }

    func testOpenAIRequest() async throws {
        CoverageURLProtocol.script([.init()])
        let text = try await OpenAITranscriptionService().transcribe(audioURL: audioURL, apiKey: key,
                                                                  model: .openAIGPT4oTranscribe, language: "fr")
        XCTAssertEqual(text, "fixture transcript")
        let request = try onlyRequest()
        assertRequest(request, url: "https://api.openai.com/v1/audio/transcriptions", keyValue: "Bearer \(key)")
        try assertMultipart(request, fields: ["model": "gpt-4o-transcribe", "response_format": "json", "language": "fr"])
    }

    func testGroqRequest() async throws {
        CoverageURLProtocol.script([.init()])
        _ = try await GroqTranscriptionService().transcribe(audioURL: audioURL, apiKey: key,
                                                          model: .groqWhisperLargeV3Turbo, language: "de")
        let request = try onlyRequest()
        assertRequest(request, url: "https://api.groq.com/openai/v1/audio/transcriptions", keyValue: "Bearer \(key)")
        try assertMultipart(request, fields: ["model": "whisper-large-v3-turbo", "response_format": "json", "language": "de"])
    }

    func testXAIRequest() async throws {
        CoverageURLProtocol.script([.init()])
        _ = try await XAITranscriptionService().transcribe(audioURL: audioURL, apiKey: key, model: .xaiGrokSTT, language: "es")
        let request = try onlyRequest()
        assertRequest(request, url: "https://api.x.ai/v1/stt", keyValue: "Bearer \(key)")
        try assertMultipart(request, fields: ["model": "grok-voice-transcribe-2.0", "format": "json", "language": "es"])
    }

    func testElevenLabsRequest() async throws {
        CoverageURLProtocol.script([.init()])
        _ = try await ElevenLabsTranscriptionService().transcribe(audioURL: audioURL, apiKey: key,
                                                                model: .elevenLabsScribeV2Realtime, language: "ja")
        let request = try onlyRequest()
        assertRequest(request, url: "https://api.elevenlabs.io/v1/speech-to-text", keyHeader: "xi-api-key", keyValue: key)
        XCTAssertNil(request.request.value(forHTTPHeaderField: "Authorization"))
        try assertMultipart(request, fields: ["model_id": "scribe_v2", "language_code": "ja", "tag_audio_events": "false"])
    }

    func testMuseRequestUsesJSONAndAudioParts() async throws {
        CoverageURLProtocol.script([.init(body: Data(#"{"transcript":"fixture transcript"}"#.utf8))])
        _ = try await MuseTranscriptionService().transcribe(audioURL: audioURL, apiKey: key,
                                                          model: .museVoiceTranscribeLive, language: "it")
        let request = try onlyRequest()
        assertRequest(request, url: "https://api.meta.ai/v1/asr/transcribe", keyValue: "Bearer \(key)")
        let parts = try multipart(request)
        XCTAssertEqual(Set(parts.keys), ["request", "audio"])
        let config = try XCTUnwrap(parts["request"])
        XCTAssertTrue(config.headers.contains("Content-Type: application/json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: config.data) as? [String: String])
        XCTAssertEqual(json, ["model": "muse-voice-transcribe-1.0", "mode": "PUSH_TO_TALK", "language": "it"])
        let audio = try XCTUnwrap(parts["audio"])
        XCTAssertTrue(audio.headers.contains("filename=\"\(CloudAudioTranscoder.uploadFileName)\""))
        XCTAssertTrue(audio.headers.contains("Content-Type: \(CloudAudioTranscoder.uploadMimeType)"))
        XCTAssertEqual(audio.data.prefix(4), Data("RIFF".utf8))
        XCTAssertGreaterThan(audio.data.count, 44)
    }

    func testDeepgramRequestUsesRawWAVAndEncodedLanguageQuery() async throws {
        CoverageURLProtocol.script([.init(body: Data(#"{"results":{"channels":[{"alternatives":[{"transcript":"fixture transcript"}]}]}}"#.utf8))])
        let text = try await DeepgramTranscriptionService().transcribe(audioURL: audioURL, apiKey: key,
                                                                     model: .deepgramNova3, language: "fr&key=not-a-key")
        XCTAssertEqual(text, "fixture transcript")
        let request = try onlyRequest()
        let url = try XCTUnwrap(request.request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "api.deepgram.com")
        XCTAssertEqual(components.path, "/v1/listen")
        let items = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }),
                       ["model": "nova-3", "smart_format": "true", "punctuate": "true", "language": "fr&key=not-a-key"])
        XCTAssertFalse(url.absoluteString.contains(key))
        XCTAssertEqual(request.request.httpMethod, "POST")
        XCTAssertEqual(request.request.value(forHTTPHeaderField: "Authorization"), "Token \(key)")
        XCTAssertEqual(request.request.value(forHTTPHeaderField: "Content-Type"), CloudAudioTranscoder.uploadMimeType)
        XCTAssertEqual(request.body.prefix(4), Data("RIFF".utf8))
    }

    func testAssemblyAIUploadCreateAndPollRequests() async throws {
        CoverageURLProtocol.script([
            .init(body: Data(#"{"upload_url":"https://example.invalid/fixture.wav"}"#.utf8)),
            .init(body: Data(#"{"id":"fixture-id_1"}"#.utf8)),
            .init(body: Data(#"{"status":"completed","text":"fixture transcript"}"#.utf8))
        ])
        let text = try await AssemblyAITranscriptionService().transcribe(audioURL: audioURL, apiKey: key,
                                                                       model: .assemblyAIUniversal3, language: "nl")
        XCTAssertEqual(text, "fixture transcript")
        let requests = CoverageURLProtocol.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(CoverageURLProtocol.remainingReplies, 0)
        guard requests.count == 3 else { return }
        assertRequest(requests[0], url: "https://api.assemblyai.com/v2/upload", keyValue: key)
        XCTAssertEqual(requests[0].request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(requests[0].body.prefix(4), Data("RIFF".utf8))
        assertRequest(requests[1], url: "https://api.assemblyai.com/v2/transcript", keyValue: key)
        XCTAssertEqual(requests[1].request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try jsonBody(requests[1])
        XCTAssertEqual(body["audio_url"] as? String, "https://example.invalid/fixture.wav")
        XCTAssertEqual(body["language_code"] as? String, "nl")
        XCTAssertEqual(requests[2].request.url?.absoluteString, "https://api.assemblyai.com/v2/transcript/fixture-id_1")
        XCTAssertEqual(requests[2].request.httpMethod, "GET")
        XCTAssertEqual(requests[2].request.value(forHTTPHeaderField: "Authorization"), key)
        XCTAssertTrue(requests[2].body.isEmpty)
        for request in requests { XCTAssertFalse(request.request.url?.absoluteString.contains(key) ?? true) }
    }

    func testGeminiRequestUsesHeaderKeyAndBase64WAV() async throws {
        CoverageURLProtocol.script([.init(body: Data(#"{"output_text":"fixture transcript"}"#.utf8))])
        let service = GeminiTranscriptionService()
        service.smartMode = false
        service.vocabulary = ["Murmur", "SwiftUI"]
        _ = try await service.transcribe(audioURL: audioURL, apiKey: key, model: .gemini35TranscribeLive, language: "fr")
        let request = try onlyRequest()
        assertRequest(request, url: "https://generativelanguage.googleapis.com/v1beta/interactions",
                      keyHeader: "x-goog-api-key", keyValue: key)
        XCTAssertNil(request.request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try jsonBody(request)
        XCTAssertEqual(body["model"] as? String, "gemini-3.5-transcribe")
        let inputs = try XCTUnwrap(body["input"] as? [[String: String]])
        XCTAssertEqual(inputs.count, 1)
        let input = try XCTUnwrap(inputs.first)
        XCTAssertEqual(input["type"], "audio")
        XCTAssertEqual(input["mime_type"], CloudAudioTranscoder.uploadMimeType)
        let audio = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(input["data"])))
        XCTAssertEqual(audio.prefix(4), Data("RIFF".utf8))
        let generation = try XCTUnwrap(body["generation_config"] as? [String: Any])
        let config = try XCTUnwrap(generation["transcription_config"] as? [String: Any])
        XCTAssertEqual((config["mode"] as? [String: String])?["type"], "verbatim")
        XCTAssertEqual(config["custom_vocabulary"] as? [String], ["Murmur", "SwiftUI"])
    }

    func testHTTPClientTimeoutConfiguration() {
        let config = HTTPClient.session.configuration
        XCTAssertEqual(config.timeoutIntervalForRequest, 20)
        XCTAssertEqual(config.timeoutIntervalForResource, 120)
        XCTAssertFalse(config.waitsForConnectivity)
    }
}
