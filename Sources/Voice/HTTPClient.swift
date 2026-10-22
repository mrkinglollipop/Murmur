import Foundation

// MARK: - Multipart form builder

enum HTTPClient {

    /// Every outbound request in the app goes through this session.
    ///
    /// `URLSession.shared` defaults to a 60 s request timeout and a **7 day**
    /// resource timeout. A cloud provider that accepts the connection and then
    /// stalls would pin the HUD in `.processing` with no cancel affordance for
    /// as long as it liked. `timeoutIntervalForRequest` is an idle timeout
    /// between packets, not a total budget, so 20 s does not penalise a slow
    /// upload that is still making progress; `timeoutIntervalForResource` caps
    /// the whole task.
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    static func multipartBody(
        boundary: String,
        fileData: Data,
        fileName: String,
        mimeType: String,
        fields: [String: String],
        repeatedFields: [(name: String, value: String)] = []
    ) -> Data {
        var body = Data()
        func append(_ string: String) {
            body.append(string.data(using: .utf8)!)
        }

        for (key, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        // Same field name once per value, in order (e.g. ElevenLabs `keyterms`).
        for (key, value) in repeatedFields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")

        return body
    }

    // MARK: - JSON POST

    struct JSONResponse {
        let data: Data
        let statusCode: Int
    }

    /// POSTs a JSON object and returns the raw response body + HTTP status.
    static func postJSON(
        url: URL,
        body: [String: Any],
        headers: [String: String] = [:],
        session: URLSession = HTTPClient.session
    ) async throws -> JSONResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return JSONResponse(data: data, statusCode: status)
    }
}
