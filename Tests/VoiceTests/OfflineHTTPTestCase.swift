import Foundation
import ObjectiveC
import XCTest
@testable import Voice

/// Catch every HTTP(S) request while these tests run; an unscripted request
/// fails locally rather than falling through to a provider.
final class CoverageURLProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var body = Data(#"{"text":"fixture transcript"}"#.utf8)
        var error: Error?
    }

    struct Captured {
        let request: URLRequest
        let body: Data
    }

    private static let lock = NSLock()
    private static var replies: [Reply] = []
    private static var captured: [Captured] = []
    private static var active = false

    static func setActive(_ active: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.active = active
    }

    static func script(_ replies: [Reply]) {
        lock.lock()
        defer { lock.unlock() }
        self.replies = replies
        captured = []
    }

    static var requests: [Captured] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    static var remainingReplies: Int {
        lock.lock()
        defer { lock.unlock() }
        return replies.count
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active && ["http", "https"].contains(request.url?.scheme ?? "")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 {
                    client?.urlProtocol(self, didFailWithError: stream.streamError ?? URLError(.cannotDecodeContentData))
                    return
                }
                if count == 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.lock.lock()
        Self.captured.append(Captured(request: request, body: body))
        let reply = Self.replies.isEmpty ? nil : Self.replies.removeFirst()
        Self.lock.unlock()
        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status,
                                             httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLSessionConfiguration {
    @objc dynamic class func coverageDefaultConfiguration() -> URLSessionConfiguration {
        // During the exchange this selector calls Foundation's original
        // getter. Only the lazily-created HTTPClient session keeps the stub.
        let configuration = coverageDefaultConfiguration()
        configuration.protocolClasses = [CoverageURLProtocol.self] + (configuration.protocolClasses ?? [])
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return configuration
    }
}

class OfflineHTTPTestCase: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        CoverageURLProtocol.setActive(true)
        guard let original = class_getClassMethod(URLSessionConfiguration.self,
                                                  #selector(getter: URLSessionConfiguration.default)),
              let replacement = class_getClassMethod(URLSessionConfiguration.self,
                                                      #selector(URLSessionConfiguration.coverageDefaultConfiguration)) else {
            XCTFail("cannot install offline URLSession configuration")
            throw URLError(.unsupportedURL)
        }
        method_exchangeImplementations(original, replacement)
        let session: URLSession
        do {
            defer { method_exchangeImplementations(original, replacement) }
            session = HTTPClient.session
        }
        // Refuse to issue requests unless the production session includes the
        // interceptor. This also catches an unexpectedly early session init.
        let installed = session.configuration.protocolClasses?.contains {
            ObjectIdentifier($0) == ObjectIdentifier(CoverageURLProtocol.self)
        } ?? false
        guard installed else {
            XCTFail("HTTPClient session was initialized without the offline interceptor")
            throw URLError(.unsupportedURL)
        }
        CoverageURLProtocol.script([])
    }

    override func tearDownWithError() throws {
        CoverageURLProtocol.script([])
        CoverageURLProtocol.setActive(false)
        try super.tearDownWithError()
    }

    func onlyRequest() throws -> CoverageURLProtocol.Captured {
        XCTAssertEqual(CoverageURLProtocol.requests.count, 1)
        XCTAssertEqual(CoverageURLProtocol.remainingReplies, 0)
        return try XCTUnwrap(CoverageURLProtocol.requests.first)
    }

    func assertRequest(_ captured: CoverageURLProtocol.Captured, url: String,
                       keyHeader: String = "Authorization", keyValue: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(captured.request.url?.absoluteString, url, file: file, line: line)
        XCTAssertEqual(captured.request.httpMethod, "POST", file: file, line: line)
        XCTAssertEqual(captured.request.value(forHTTPHeaderField: keyHeader), keyValue, file: file, line: line)
        XCTAssertFalse(captured.request.url?.absoluteString.contains("coverage-dummy-secret") ?? true, file: file, line: line)
    }

    func jsonBody(_ captured: CoverageURLProtocol.Captured) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: captured.body) as? [String: Any])
    }
}
