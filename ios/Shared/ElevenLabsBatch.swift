import Foundation

enum ElevenLabsBatch {
    private struct Response: Decodable { let text: String }

    static func transcribe(audioURL: URL, apiKey: String, language: String) async throws -> String {
        let payload = try WAVTranscoder.wavUploadPayload(from: audioURL)
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) {
            body.append(Data(string.utf8))
        }
        for (key, value) in ["model_id": "scribe_v2", "language_code": language] {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(payload.fileName)\"\r\n")
        append("Content-Type: \(payload.mimeType)\r\n\r\n")
        body.append(payload.data)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw ElevenLabsError.http(status, snippet)
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              !decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ElevenLabsError.noTranscript
        }
        return decoded.text
    }
}

enum ElevenLabsError: Error, LocalizedError {
    case http(Int, String)
    case noTranscript

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            return "ElevenLabs HTTP \(code) \(body.prefix(160))"
        case .noTranscript:
            return "No transcript in response"
        }
    }
}
