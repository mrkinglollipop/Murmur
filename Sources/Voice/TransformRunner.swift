import Foundation
import os.log
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Runs an arbitrary rewrite instruction over a block of text — the apply
/// path for saved Transforms. Mirrors `CleanupFactory`'s backend-selection
/// logic (on-device first, cloud OpenAI key as fallback) but takes a
/// caller-supplied prompt instead of the fixed cleanup instructions, since a
/// Transform's instruction is user-authored, not the cleanup grammar/filler
/// pass.
enum TransformRunner {

    private static let logger = Logger(subsystem: "com.matt.voice-dictation", category: "transform-runner")

    /// Runs `prompt` as the instruction over `text` and returns the rewritten
    /// result. Backend selection: on-device (FoundationModels) if available,
    /// else cloud (BYO OpenAI key from Keychain) if a key is present, else
    /// throws — mirroring the cleanup fail-safe posture, except a Transform
    /// run has no "fall back to raw text" caller path of its own, so the
    /// caller (TransformsView) is responsible for surfacing the failure
    /// rather than silently swallowing it.
    static func run(prompt: String, over text: String, openAIKey: String?) async throws -> String {
        guard !text.isEmpty else { return text }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            let session = LanguageModelSession(instructions: prompt)
            let response = try await session.respond(to: text)
            let result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.isEmpty ? text : result
        }
        #endif

        guard let key = openAIKey, !key.isEmpty else {
            logger.error("Transform run failed: no on-device model and no cloud key configured")
            throw TransformRunnerError.noBackendAvailable
        }

        return try await runCloud(prompt: prompt, text: text, apiKey: key)
    }

    /// Cloud path — same OpenAI chat-completions shape as `CloudLLMCleanup`,
    /// but with the Transform's own prompt as the system instruction.
    private static func runCloud(prompt: String, text: String, apiKey: String) async throws -> String {
        let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": text]
            ],
            "temperature": 0
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

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
    case noBackendAvailable
    case requestFailed(status: Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .noBackendAvailable:
            return "No on-device model or cloud key available to run this transform."
        case .requestFailed(let status):
            return "Transform request failed (status \(status))."
        case .emptyResponse:
            return "Transform response was empty."
        }
    }
}
