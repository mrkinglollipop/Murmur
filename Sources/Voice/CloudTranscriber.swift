import Foundation
import os.log

// MARK: - Cloud Provider

/// The four BYO-API-key cloud transcription providers. Distinct from
/// `CloudModel` (which is the picker-facing model choice) so that provider
/// identity — Keychain account, signup link, display name — lives in one
/// place regardless of which specific model a provider exposes.
enum CloudProvider: String, CaseIterable, Identifiable {
    case assemblyAI = "assemblyAI"
    case deepgram   = "deepgram"
    case openAI     = "openAI"
    case groq       = "groq"
    case xai        = "xai"
    case elevenLabs = "elevenLabs"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .assemblyAI: return "AssemblyAI"
        case .deepgram:   return "Deepgram"
        case .openAI:     return "OpenAI"
        case .groq:       return "Groq"
        case .xai:        return "xAI (Grok)"
        case .elevenLabs: return "ElevenLabs"
        }
    }

    /// Keychain account identifier this provider's key is stored under
    /// (service is fixed in `KeychainStore`).
    var keychainAccount: String { rawValue }

    var signupURL: URL {
        switch self {
        case .assemblyAI: return URL(string: "https://www.assemblyai.com/dashboard/signup")!
        case .deepgram:   return URL(string: "https://console.deepgram.com/signup")!
        case .openAI:     return URL(string: "https://platform.openai.com/api-keys")!
        case .groq:       return URL(string: "https://console.groq.com/keys")!
        case .xai:        return URL(string: "https://console.x.ai")!
        case .elevenLabs: return URL(string: "https://elevenlabs.io/app/settings/api-keys")!
        }
    }
}

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
        }
    }
}

// MARK: - Errors

struct CloudTranscriptionError: LocalizedError {
    let provider: CloudProvider
    let message: String

    var errorDescription: String? {
        "\(provider.displayName): \(message)"
    }

    static func httpStatus(_ status: Int, provider: CloudProvider, body: String? = nil) -> CloudTranscriptionError {
        let suffix = body.map { " — \(redactedBodyFragment($0))" } ?? ""
        return CloudTranscriptionError(provider: provider, message: "HTTP \(status)\(suffix)")
    }

    /// Strips anything key-shaped before a body fragment can reach logs:
    /// long unbroken token runs (20+ chars of [A-Za-z0-9_-]) are replaced
    /// with "…". Keeps enough context to diagnose HTTP errors.
    static func redactedBodyFragment(_ body: String, max: Int = 300) -> String {
        let pattern = "[A-Za-z0-9_\\-]{20,}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return String(body.prefix(max))
        }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        let redacted = regex.stringByReplacingMatches(in: body, range: range, withTemplate: "…")
        return String(redacted.prefix(max))
    }
}

// MARK: - Service Protocol

/// One cloud transcription backend. Implementations own their own REST
/// wire format; all consume the same recorded CAF audio file and return
/// plain recognised text.
protocol CloudTranscriptionService {
    func transcribe(audioURL: URL, apiKey: String, model: CloudModel, language: String) async throws -> String
}

// MARK: - Shared helpers

private enum CloudAudioFormat {
    /// Upload format after `CloudAudioTranscoder` converts the on-disk CAF
    /// capture to 16-bit/16kHz mono WAV. Do not upload raw CAF — xAI (and
    /// other batch endpoints) reject it with HTTP 400 (plan 010).
    static let mimeType = CloudAudioTranscoder.uploadMimeType
    static let fileName = CloudAudioTranscoder.uploadFileName
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

        let (data, response) = try await URLSession.shared.data(for: request)
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

        let (data, response) = try await URLSession.shared.data(for: request)
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

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CloudTranscriptionError.httpStatus(status, provider: .deepgram, body: String(data: data, encoding: .utf8))
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let transcript = decoded.results.channels.first?.alternatives.first?.transcript else {
            throw CloudTranscriptionError(provider: .deepgram, message: "No transcript in response")
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

        let (data, response) = try await URLSession.shared.data(for: request)
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
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "audio_url": audioURL,
            "speech_model": "universal",
            "language_code": language
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CloudTranscriptionError.httpStatus(status, provider: .assemblyAI, body: String(data: data, encoding: .utf8))
        }
        return try JSONDecoder().decode(CreateTranscriptResponse.self, from: data).id
    }

    /// Step (c): poll every ~1.5s until `status == "completed"` (or
    /// `"error"`), capped at ~120s total.
    private func poll(transcriptID: String, apiKey: String) async throws -> String {
        let deadline = Date().addingTimeInterval(120)
        let url = URL(string: "https://api.assemblyai.com/v2/transcript/\(transcriptID)")!

        while Date() < deadline {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "Authorization") // raw key, no scheme

            let (data, response) = try await URLSession.shared.data(for: request)
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
                "model": "grok-stt",
                "format": "json",
                "language": language
            ]
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CloudTranscriptionError.httpStatus(status, provider: .xai, body: String(data: data, encoding: .utf8))
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data), !decoded.text.isEmpty else {
            throw CloudTranscriptionError(provider: .xai, message: "No transcript in response")
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
                "language_code": language
            ]
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CloudTranscriptionError.httpStatus(status, provider: .elevenLabs, body: String(data: data, encoding: .utf8))
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data), !decoded.text.isEmpty else {
            throw CloudTranscriptionError(provider: .elevenLabs, message: "No transcript in response")
        }
        return decoded.text
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
        }
    }
}
