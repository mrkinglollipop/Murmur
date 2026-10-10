import AVFoundation
import Security
import XCTest
@testable import Voice

/// Opt-in service check. Write the path to a synthetic recording ending in
/// "absolute joke" to `/tmp/.murmur-run-tail-replay`. Never records the
/// microphone or changes keys.
final class LiveTailReplayTests: XCTestCase {
    private static let sentinelPath = "/tmp/.murmur-run-tail-replay"

    private func fixture() throws -> URL {
        guard FileManager.default.fileExists(atPath: Self.sentinelPath) else {
            throw XCTSkip("Live replay is opt-in; create \(Self.sentinelPath) containing the fixture path.")
        }
        let path = try String(contentsOfFile: Self.sentinelPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw XCTSkip("\(Self.sentinelPath) is empty.") }
        let url = URL(fileURLWithPath: path)
        let file = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(file.length, 0, "The replay fixture must contain audio.")
        return url
    }

    private func key(_ provider: CloudProvider) throws -> String {
        // The legacy file-based keychain can ignore kSecUseAuthenticationUI.
        // This switch is scoped to the test process, never the running app.
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        var query = KeychainStore.baseQuery(
            service: KeychainStore.defaultService, account: provider.keychainAccount
        )
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var value: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        guard status == errSecSuccess, let data = value as? Data,
              let result = String(data: data, encoding: .utf8), !result.isEmpty else {
            throw XCTSkip("\(provider.displayName) credential unavailable without a prompt (OSStatus \(status)).")
        }
        return result
    }

    private func assertTail(_ text: String, label: String) {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        XCTAssertEqual(Array(words.suffix(2)), ["absolute", "joke"], "\(label): \(text)")
        print("TAIL_REPLAY \(label): \(text)")
    }

    private func stream(
        url: URL, send: (AVAudioPCMBuffer) -> Void,
        finalize: (TimeInterval) async -> String
    ) async throws -> String {
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        while file.framePosition < file.length {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1600))
            try file.read(into: buffer)
            send(buffer)
            try await Task.sleep(nanoseconds: UInt64(Double(buffer.frameLength) / file.processingFormat.sampleRate * 1_000_000_000))
        }
        return await finalize(duration)
    }

    func testElevenLabsStreamingTail() async throws {
        try await elevenLabsStream(filterBackgroundAudio: false)
    }

    func testElevenLabsFilteredStreamingTail() async throws {
        try await elevenLabsStream(filterBackgroundAudio: true)
    }

    private func elevenLabsStream(filterBackgroundAudio: Bool) async throws {
        let url = try fixture()
        var options = ElevenLabsRealtimeOptions.defaults
        options.filterBackgroundAudio = filterBackgroundAudio
        let session = ElevenLabsRealtimeTranscriber(apiKey: try key(.elevenLabs), realtimeOptions: options)
        defer { session.cancel() }
        try await session.start()
        let text = try await stream(url: url, send: session.send) { await session.finalize(recordingDuration: $0) }
        assertTail(text, label: "ElevenLabs streaming filter=\(filterBackgroundAudio)")
    }

    func testXAIStreamingTail() async throws {
        let url = try fixture()
        let session = XAIStreamingTranscriber(apiKey: try key(.xai))
        defer { session.cancel() }
        try await session.start()
        let text = try await stream(url: url, send: session.send) { await session.finalize(recordingDuration: $0) }
        assertTail(text, label: "xAI streaming")
    }

    func testGeminiStreamingTail() async throws {
        let url = try fixture()
        let session = GeminiLiveTranscriber(apiKey: try key(.gemini))
        defer { session.cancel() }
        try await session.start()
        let text = try await stream(url: url, send: session.send) { await session.finalize(recordingDuration: $0) }
        assertTail(text, label: "Gemini streaming")
    }

    func testMuseStreamingTail() async throws {
        let url = try fixture()
        let session = MuseLiveTranscriber(apiKey: try key(.meta))
        defer { session.cancel() }
        try await session.start()
        let text = try await stream(url: url, send: session.send) { await session.finalize(recordingDuration: $0) }
        assertTail(text, label: "Muse streaming")
    }

    private func batch(_ service: CloudTranscriptionService, model: CloudModel) async throws {
        let url = try fixture()
        let text = try await service.transcribe(audioURL: url, apiKey: key(model.provider), model: model, language: "en")
        assertTail(text, label: "\(model.provider.displayName) batch")
    }

    func testElevenLabsBatchTail() async throws { try await batch(ElevenLabsTranscriptionService(), model: .elevenLabsScribeV2Realtime) }
    func testXAIBatchTail() async throws { try await batch(XAITranscriptionService(), model: .xaiGrokSTT) }
    func testGeminiBatchTail() async throws { try await batch(GeminiTranscriptionService(), model: .gemini35TranscribeLive) }
    func testMuseBatchTail() async throws { try await batch(MuseTranscriptionService(), model: .museVoiceTranscribeLive) }
    func testOpenAIBatchTail() async throws { try await batch(OpenAITranscriptionService(), model: .openAIGPT4oTranscribe) }
    func testGroqBatchTail() async throws { try await batch(GroqTranscriptionService(), model: .groqWhisperLargeV3Turbo) }
    func testDeepgramBatchTail() async throws { try await batch(DeepgramTranscriptionService(), model: .deepgramNova3) }
    func testAssemblyAIBatchTail() async throws { try await batch(AssemblyAITranscriptionService(), model: .assemblyAIUniversal3) }

    func testWhisperKitTail() async throws {
        let url = try fixture()
        let model = LocalModel.whisperBase
        let folder = try XCTUnwrap(ModelManager.modelFolderURL(for: model))
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw XCTSkip("Whisper base is not installed; replay does not download models.")
        }
        let engine = WhisperKitEngine(
            modelID: try XCTUnwrap(model.whisperKitModelID),
            displayName: model.displayName, localModel: model
        )
        assertTail(try await engine.transcribe(audioURL: url), label: "WhisperKit base")
    }
}
