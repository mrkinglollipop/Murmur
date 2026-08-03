import Foundation

// MARK: - Multipart form builder

enum HTTPClient {

    static func multipartBody(
        boundary: String,
        fileData: Data,
        fileName: String,
        mimeType: String,
        fields: [String: String]
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
        session: URLSession = .shared
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
