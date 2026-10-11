import Foundation
import os.log

extension CloudModel {
    /// Which provider backs this cloud model.
    var provider: CloudProvider {
        switch self {
        case .assemblyAIUniversal3:       return .assemblyAI
        case .deepgramNova3:              return .deepgram
        case .openAIGPT4oTranscribe:      return .openAI
        case .groqWhisperLargeV3Turbo:    return .groq
        case .xaiGrokSTT:                 return .xai
        case .elevenLabsScribeV2Realtime: return .elevenLabs
        case .gemini35TranscribeLive:     return .gemini
        case .museVoiceTranscribeLive:    return .meta
        }
    }
}

// MARK: - Service Protocol

/// One cloud transcription backend. Implementations own their own REST
/// wire format; all consume the same recorded CAF audio file and return
/// plain recognised text.
protocol CloudTranscriptionService {
    func transcribe(audioURL: URL, apiKey: String, model: CloudModel, language: String) async throws -> String
}

/// Loads audio for cloud batch: always transcode to WAV first. Throws a
/// `CloudTranscriptionError` naming the transcode step on failure — never
/// fall back to raw CAF (proven dead for xAI).
private func cloudUploadAudio(from audioURL: URL, provider: CloudProvider) throws -> (data: Data, fileName: String, mimeType: String) {
    do {
        return try CloudAudioTranscoder.wavUploadPayload(from: audioURL)
    } catch {
        throw CloudTranscriptionError(
            provider: provider,
            message: "Audio transcode to WAV failed: \(error.localizedDescription)"
        )
    }
}

private let cloudLogger = Logger(subsystem: "com.matt.voice-dictation", category: "cloud-asr")

// MARK: - OpenAI

final class OpenAITranscriptionService: CloudTranscriptionService {
    private struct Response: Decodable { let text: String }

    func transcribe(audioURL: URL, apiKey: String, model: CloudModel, language: String) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        let payload = try cloudUploadAudio(from: audioURL, provider: .openAI)

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = HTTPClient.multipartBody(
            boundary: boundary,
            fileData: payload.data,
            fileName: payload.fileName,
            mimeType: payload.mimeType,
            fields: [
                "model": "gpt-4o-transcribe",
                "response_format": "json",
                "language": language
            ]
        )

        let (data, response) = try await HTTPClient.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CloudTranscriptionError.httpStatus(status, provider: .openAI, body: String(data: data, encoding: .utf8))
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.text
    }
}

// MARK: - Groq (OpenAI-compatible)

final class GroqTranscriptionService: CloudTranscriptionService {
    private struct Response: Decodable { let text: String }

    func transcribe(audioURL: URL, apiKey: String, model: CloudModel, language: String) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        let payload = try cloudUploadAudio(from: audioURL, provider: .groq)

        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = HTTPClient.multipartBody(
            boundary: boundary,
            fileData: payload.data,
            fileName: payload.fileName,
            mimeType: payload.mimeType,
            fields: [
                "model": "whisper-large-v3-turbo",
                "response_format": "json",
                "language": language
            ]
        )

        let (data, response) = try await HTTPClient.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CloudTranscriptionError.httpStatus(status, provider: .groq, body: String(data: data, encoding: .utf8))
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.text
    }
}

// MARK: - Deepgram

final class DeepgramTranscriptionService: CloudTranscriptionService {
    private struct Response: Decodable {
        struct Results: Decodable {
            struct Channel: Decodable {
                struct Alternative: Decodable { let transcript: String }
                let alternatives: [Alternative]
            }
            let channels: [Channel]
        }
        let results: Results
    }

    func transcribe(audioURL: URL, apiKey: String, model: CloudModel, language: String) async throws -> String {
        let payload = try cloudUploadAudio(from: audioURL, provider: .deepgram)

        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "language", value: language)
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(payload.mimeType, forHTTPHeaderField: "Content-Type")
        request.httpBody = payload.data

        let (data, response) = try await HTTPClient.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CloudTranscriptionError.httpStatus(status, provider: .deepgram, body: String(data: data, encoding: .utf8))
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let transcript = decoded.results.channels.first?.alternatives.first?.transcript else {
            throw CloudTranscriptionError(provider: .deepgram, message: "No transcript in response")
        }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudTranscriptionError.emptyTranscript(provider: .deepgram)
        }
        return transcript
    }
}

// MARK: - AssemblyAI

final class AssemblyAITranscriptionService: CloudTranscriptionService {
    private struct UploadResponse: Decodable { let upload_url: String }
    private struct CreateTranscriptResponse: Decodable { let id: String }
    private struct PollResponse: Decodable {
        let status: String
        let text: String?
        let error: String?
    }

    func transcribe(audioURL: URL, apiKey: String, model: CloudModel, language: String) async throws -> String {
        let uploadURL = try await upload(audioURL: audioURL, apiKey: apiKey)
        let transcriptID = try await createTranscript(audioURL: uploadURL, apiKey: apiKey, language: language)
        return try await poll(transcriptID: transcriptID, apiKey: apiKey)
    }

    /// Step (a): upload WAV bytes (transcoded from CAF), get back an `upload_url`.
    private func upload(audioURL: URL, apiKey: String) async throws -> String {
        let payload = try cloudUploadAudio(from: audioURL, provider: .assemblyAI)

        var request = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/upload")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization") // raw key, no scheme
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload.data

        let (data, response) = try await HTTPClient.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CloudTranscriptionError.httpStatus(status, provider: .assemblyAI, body: String(data: data, encoding: .utf8))
        }
        return try JSONDecoder().decode(UploadResponse.self, from: data).upload_url
    }

    /// Step (b): submit the uploaded audio URL for transcription, get back an `id`.
    private func createTranscript(audioURL: String, apiKey: String, language: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/transcript")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization") // raw key, no scheme
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.makeTranscriptRequestBody(audioURL: audioURL, language: language)

        let (data, response) = try await HTTPClient.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CloudTranscriptionError.httpStatus(status, provider: .assemblyAI, body: String(data: data, encoding: .utf8))
        }
        return try JSONDecoder().decode(CreateTranscriptResponse.self, from: data).id
    }

    /// Universal-3.5 Pro is the current pre-recorded model; Universal-2 is
    /// the documented fallback for languages it does not support. AssemblyAI
    /// deprecated the singular `speech_model` parameter in favor of this
    /// priority-ordered `speech_models` array.
    static func makeTranscriptRequestBody(audioURL: String, language: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "audio_url": audioURL,
            "speech_models": ["universal-3-5-pro", "universal-2"],
            "language_code": language
        ])
    }

    /// The transcript id is server-supplied and lands in a URL path, so accept
    /// only id-shaped characters (no `/`, `..`, `?`, whitespace).
    static func pollURL(transcriptID: String) -> URL? {
        guard !transcriptID.isEmpty,
              transcriptID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        return URL(string: "https://api.assemblyai.com/v2/transcript/\(transcriptID)")
    }

    /// Step (c): poll every ~1.5s until `status == "completed"` (or
    /// `"error"`), capped at ~120s total.
    private func poll(transcriptID: String, apiKey: String) async throws -> String {
        let deadline = Date().addingTimeInterval(120)
        guard let url = Self.pollURL(transcriptID: transcriptID) else {
            throw CloudTranscriptionError(provider: .assemblyAI, message: "Invalid transcript id in response")
        }

        while Date() < deadline {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "Authorization") // raw key, no scheme

            let (data, response) = try await HTTPClient.session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw CloudTranscriptionError.httpStatus(status, provider: .assemblyAI, body: String(data: data, encoding: .utf8))
            }

            let decoded = try JSONDecoder().decode(PollResponse.self, from: data)
            switch decoded.status {
            case "completed":
                return decoded.text ?? ""
            case "error":
                throw CloudTranscriptionError(provider: .assemblyAI, message: decoded.error ?? "unknown transcription error")
            default:
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        throw CloudTranscriptionError(provider: .assemblyAI, message: "Polling timed out after 120s")
    }
}

// MARK: - xAI (Grok)

final class XAITranscriptionService: CloudTranscriptionService {
    /// Shared by batch and `XAIStreamingTranscriber`. Pinned explicitly because
    /// xAI changes which model serves requests that omit `model`.
    static let modelID = "grok-voice-transcribe-2.0"

    private struct Response: Decodable { let text: String }

    func transcribe(audioURL: URL, apiKey: String, model: CloudModel, language: String) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        let payload = try cloudUploadAudio(from: audioURL, provider: .xai)

        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/stt")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = HTTPClient.multipartBody(
            boundary: boundary,
            fileData: payload.data,
            fileName: payload.fileName,
            mimeType: payload.mimeType,
            fields: [
                "model": Self.modelID,
                "format": "json",
                "language": language
            ]
        )

        let (data, response) = try await HTTPClient.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CloudTranscriptionError.httpStatus(status, provider: .xai, body: String(data: data, encoding: .utf8))
        }
        return try Self.decodeTranscript(from: data)
    }

    static func decodeTranscript(from data: Data) throws -> String {
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw CloudTranscriptionError(provider: .xai, message: "No transcript in response")
        }
        guard !decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudTranscriptionError.emptyTranscript(provider: .xai)
        }
        return decoded.text
    }
}

// MARK: - ElevenLabs (Scribe) — batch fallback

/// Batch (non-realtime) fallback used only when `ElevenLabsRealtimeTranscriber`
/// fails to open its WebSocket session — mirrors `XAITranscriptionService`'s
/// role as the batch fallback for xAI streaming. The primary path for this
/// provider is the realtime WebSocket (`ElevenLabsRealtimeTranscriber`);
/// this class exists so `CloudTranscriberFactory.service(for:)` stays
/// exhaustive and a dropped/failed socket still produces a transcript from
/// the buffered recording instead of losing the utterance.
final class ElevenLabsTranscriptionService: CloudTranscriptionService {
    private struct Response: Decodable { let text: String }

    func transcribe(audioURL: URL, apiKey: String, model: CloudModel, language: String) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        let payload = try cloudUploadAudio(from: audioURL, provider: .elevenLabs)

        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key") // NOT bearer
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = HTTPClient.multipartBody(
            boundary: boundary,
            fileData: payload.data,
            fileName: payload.fileName,
            mimeType: payload.mimeType,
            fields: [
                "model_id": "scribe_v2",
                "language_code": language,
                // Scribe otherwise returns captions such as "[coughing]" for
                // audio events. Dictation wants spoken words only.
                "tag_audio_events": "false"
            ]
        )

        let (data, response) = try await HTTPClient.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CloudTranscriptionError.httpStatus(status, provider: .elevenLabs, body: String(data: data, encoding: .utf8))
        }
        return try Self.decodeTranscript(from: data)
    }

    static func decodeTranscript(from data: Data) throws -> String {
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw CloudTranscriptionError(provider: .elevenLabs, message: "No transcript in response")
        }
        guard !decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudTranscriptionError.emptyTranscript(provider: .elevenLabs)
        }
        return decoded.text
    }
}

// MARK: - Gemini (batch fallback)

final class GeminiTranscriptionService: CloudTranscriptionService {
    /// Matches Live `SMART`/`VERBATIM`. Set by `TranscriptionPipeline` from
    /// `SettingsStore.removeFillerWords` before `transcribe`.
    var smartMode: Bool = true
    /// Canonical dictionary terms (cap 100). Empty omits `custom_vocabulary`.
    var vocabulary: [String] = []

    func transcribe(audioURL: URL, apiKey: String, model: CloudModel, language: String) async throws -> String {
        let payload = try cloudUploadAudio(from: audioURL, provider: .gemini)
        let body = GeminiLiveOptions.makeBatchRequestBody(
            wavBase64: payload.data.base64EncodedString(),
            mimeType: payload.mimeType,
            smartMode: smartMode,
            vocabulary: vocabulary
        )

        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await HTTPClient.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CloudTranscriptionError.httpStatus(status, provider: .gemini, body: String(data: data, encoding: .utf8))
        }
        guard let text = GeminiBatchDecode.decodeTranscript(from: data),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudTranscriptionError(provider: .gemini, message: "No transcript in response")
        }
        return text
    }
}

// MARK: - Meta (Muse Voice Transcribe) — batch fallback

final class MuseTranscriptionService: CloudTranscriptionService {
    func transcribe(audioURL: URL, apiKey: String, model: CloudModel, language: String) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        let payload = try cloudUploadAudio(from: audioURL, provider: .meta)
        let requestJSON = try JSONSerialization.data(withJSONObject: [
            "model": "muse-voice-transcribe-1.0",
            "mode": "PUSH_TO_TALK",
            "language": language
        ])

        var body = Data()
        func append(_ string: String) {
            body.append(string.data(using: .utf8)!)
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"request\"\r\n")
        append("Content-Type: application/json\r\n\r\n")
        body.append(requestJSON)
        append("\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(payload.fileName)\"\r\n")
        append("Content-Type: \(payload.mimeType)\r\n\r\n")
        body.append(payload.data)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: URL(string: "https://api.meta.ai/v1/asr/transcribe")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await HTTPClient.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CloudTranscriptionError.httpStatus(status, provider: .meta, body: String(data: data, encoding: .utf8))
        }
        guard let text = MuseBatchDecode.decodeTranscript(from: data),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudTranscriptionError(provider: .meta, message: "No transcript in response")
        }
        return text
    }
}

// MARK: - Factory

enum CloudTranscriberFactory {
    static func service(for model: CloudModel) -> CloudTranscriptionService {
        switch model.provider {
        case .assemblyAI: return AssemblyAITranscriptionService()
        case .deepgram:   return DeepgramTranscriptionService()
        case .openAI:     return OpenAITranscriptionService()
        case .groq:       return GroqTranscriptionService()
        case .xai:        return XAITranscriptionService()
        case .elevenLabs: return ElevenLabsTranscriptionService()
        case .gemini:     return GeminiTranscriptionService()
        case .meta:       return MuseTranscriptionService()
        }
    }
}
