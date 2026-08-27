import Foundation

enum GeminiBatch {
    static func transcribe(
        audioURL: URL,
        apiKey: String,
        language: String,
        smartMode: Bool = true,
        vocabulary: [String] = []
    ) async throws -> String {
        let payload = try WAVTranscoder.wavUploadPayload(from: audioURL)
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
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw GeminiBatchError.http(status, snippet)
        }
        guard let text = GeminiBatchDecode.decodeTranscript(from: data),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiBatchError.noTranscript
        }
        return text
    }
}

enum GeminiBatchError: Error, LocalizedError {
    case http(Int, String)
    case noTranscript

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            return "Gemini HTTP \(code) \(CloudTranscriptionError.redactedBodyFragment(body, max: 160))"
        case .noTranscript:
            return "No transcript in response"
        }
    }
}
