import Foundation
import os.log
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Everything a Transform run needs to pick a backend: the user's configured
/// cleanup backend plus the keys behind the cloud options. Passed as one value
/// so callers wire a single provider closure instead of one per key, and so the
/// Settings choice reaches every call site.
struct TransformCredentials {
    let backend: CleanupBackend
    let openAIKey: String?
    let xaiKey: String?

    /// Placeholder for the window where the settings store is gone (weak
    /// reference cleared during teardown).
    static let unavailable = TransformCredentials(backend: .onDevice, openAIKey: nil, xaiKey: nil)

    /// Whether a Transform can run right now — used to disable the Run button up
    /// front rather than spinning and failing with `.noBackendAvailable`.
    var backendAvailable: Bool {
        switch backend {
        case .onDevice: return TransformRunner.onDeviceModelAvailable
        case .cloud:    return !(openAIKey ?? "").isEmpty
        case .xaiGrok:  return !(xaiKey ?? "").isEmpty
        }
    }
}

/// Runs an arbitrary rewrite instruction over a block of text — the apply
/// path for saved Transforms. Backend selection follows the user's configured
/// `CleanupBackend`, the same choice `CleanupFactory` honors, but with a
/// caller-supplied prompt instead of the fixed cleanup instructions, since a
/// Transform's instruction is user-authored.
enum TransformRunner {

    private static let logger = Logger(subsystem: "com.matt.voice-dictation", category: "transform-runner")

    static var onDeviceModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
        #else
        return false
        #endif
    }

    /// Runs `prompt` as the instruction over `text` and returns the rewritten
    /// result.
    ///
    /// On-device selection never sends text to a cloud backend. Explicit cloud
    /// selections may fall back to another configured cloud backend.
    static func run(prompt: String, over text: String, credentials: TransformCredentials) async throws -> String {
        guard !text.isEmpty else { return text }

        for backend in orderedBackends(preferring: credentials.backend) {
            switch backend {
            case .onDevice:
                #if canImport(FoundationModels)
                if #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability {
                    let session = LanguageModelSession(instructions: prompt)
                    let response = try await session.respond(to: text)
                    let result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    return result.isEmpty ? text : result
                }
                #endif
            case .cloud:
                if let key = credentials.openAIKey, !key.isEmpty {
                    return try await runCloud(
                        prompt: prompt,
                        text: text,
                        apiKey: key,
                        endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
                        model: "gpt-4o-mini"
                    )
                }
            case .xaiGrok:
                if let key = credentials.xaiKey, !key.isEmpty {
                    return try await runCloud(
                        prompt: prompt,
                        text: text,
                        apiKey: key,
                        endpoint: URL(string: "https://api.x.ai/v1/chat/completions")!,
                        model: GrokCleanupSettings.modelID
                    )
                }
            }
        }

        logger.error("Transform run failed: no usable backend for the current settings")
        if credentials.backend == .onDevice {
            throw TransformRunnerError.onDeviceUnavailable
        }
        throw TransformRunnerError.noBackendAvailable
    }

    /// On-device stays local; cloud selections retain their configured fallbacks.
    /// Pure so the ordering is testable without a model or a key.
    static func orderedBackends(preferring preferred: CleanupBackend) -> [CleanupBackend] {
        guard preferred != .onDevice else { return [.onDevice] }
        return [preferred] + CleanupBackend.allCases.filter { $0 != preferred }
    }

    /// Cloud path — the OpenAI-compatible chat-completions shape shared by both
    /// cloud backends, with the Transform's own prompt as the system instruction.
    private static func runCloud(
        prompt: String,
        text: String,
        apiKey: String,
        endpoint: URL,
        model: String
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": text]
            ],
            "temperature": 0
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await HTTPClient.session.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            logger.error("Transform cloud run failed with status \(status)")
            throw TransformRunnerError.requestFailed(status: status)
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String,
            !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw TransformRunnerError.emptyResponse
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TransformRunnerError: LocalizedError {
    case onDeviceUnavailable
    case noBackendAvailable
    case requestFailed(status: Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .onDeviceUnavailable:
            return "The on-device model is unavailable. This transform stayed on device; no text was sent to a cloud backend."
        case .noBackendAvailable:
            return "No on-device model or cloud key available to run this transform."
        case .requestFailed(let status):
            return "Transform request failed (status \(status))."
        case .emptyResponse:
            return "Transform response was empty."
        }
    }
}
