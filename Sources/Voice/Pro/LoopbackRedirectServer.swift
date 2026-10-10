// PRO ONLY — this file is part of the paid feature set and must never merge
// into `main`. See the "Clipboard manager" section of CLAUDE.md.

import Foundation
import Network

/// Loopback HTTP listener for the OAuth browser round trip.
///
/// A browser cannot render a `murmur://` custom-scheme redirect — macOS hands
/// the URL to the app, but the tab itself is left spinning forever. Binding a
/// local port for the duration of sign-in lets Supabase redirect the browser
/// to `http://127.0.0.1:<port>/auth-callback?...` instead: this listener
/// answers with a small "you can close this tab" page while handing the auth
/// code to the flow controller. The custom-scheme path remains as fallback.
final class LoopbackRedirectServer {

    enum RequestHeadResult: Equatable {
        case waitForMore
        case target(String)
        case badRequest
    }

    /// Fixed ports registered verbatim in Supabase's redirect allow-list.
    /// Explicit entries because the allow-list's glob rules don't clearly
    /// cover port wildcards. Tried in order; all taken → caller falls back
    /// to the `murmur://` deep link.
    static let allowedPorts: [UInt16] = [52795, 52796, 52797, 52798, 52799]
    static let callbackPath = "/auth-callback"

    /// The redirect URI Supabase should send the browser to for `port`.
    static func redirectURI(port: UInt16) -> String {
        "http://127.0.0.1:\(port)\(callbackPath)"
    }

    // MARK: - Pure request parsing

    /// "GET /auth-callback?code=x HTTP/1.1" → "/auth-callback?code=x".
    static func requestTarget(fromRequestHead head: String) -> String? {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == "GET",
              parts[1].first == "/",
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return nil }
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  line[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                return nil
            }
        }
        return String(parts[1])
    }

    static func responseStatus(forRequestHead head: String) -> String {
        requestTarget(fromRequestHead: head) == nil ? "400 Bad Request" : "200 OK"
    }

    static func requestHeadResult(
        accumulated: Data,
        received: Data,
        complete: Bool
    ) -> RequestHeadResult {
        let next = accumulated + received
        guard next.count <= maximumRequestHeadBytes else { return .badRequest }
        guard let terminator = next.range(of: Data("\r\n\r\n".utf8)) else {
            return complete ? .badRequest : .waitForMore
        }
        guard let head = String(data: next[..<terminator.upperBound], encoding: .utf8),
              let target = requestTarget(fromRequestHead: head) else {
            return .badRequest
        }
        return .target(target)
    }

    /// nil when the target isn't the callback path (favicon and friends);
    /// otherwise the parsed auth code or the error Supabase reported.
    static func callbackResult(fromTarget target: String) -> Result<String, SupabaseAuthClient.AuthError>? {
        guard let components = URLComponents(string: target),
              components.path == callbackPath else { return nil }
        return SupabaseAuthClient.parseCallbackItems(components.queryItems ?? [])
    }

    static func responseHTML() -> String {
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Murmur</title>
        <style>
        body{font-family:-apple-system,system-ui,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#faf7f2;color:#3a3532}
        @media(prefers-color-scheme:dark){body{background:#1c1a18;color:#e8e2da}}
        main{text-align:center}h1{font-size:22px;font-weight:600;margin:0 0 8px}p{font-size:14px;opacity:.7;margin:0}
        </style></head><body><main><h1>You can return to Murmur.</h1><p>You can close this tab.</p></main></body></html>
        """
    }

    // MARK: - Listener

    let port: UInt16
    var redirectURI: String { Self.redirectURI(port: port) }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.matt.voice-dictation.loopback-auth")
    /// A callback needs one short-lived connection. Keep a small cap so a
    /// local process cannot make the listener retain an unbounded array while
    /// a browser attempt is open.
    private static let maximumConnections = 8
    private static let maximumRequestHeadBytes = 8 * 1024
    private var connections: [NWConnection] = []
    private var onResult: ((Result<String, SupabaseAuthClient.AuthError>) -> Void)?
    private var isStopped = false

    static func shouldAcceptConnection(
        retainedCount: Int,
        hasResultHandler: Bool,
        isStopped: Bool
    ) -> Bool {
        !isStopped && hasResultHandler && retainedCount < maximumConnections
    }

    /// Binds the first free allow-listed port, or nil when none is available.
    /// `onResult` fires for each callback candidate, on an internal queue — hop
    /// to the main actor before touching UI state. The controller keeps the
    /// first code that successfully exchanges and then stops this listener.
    static func start(
        ports: [UInt16] = allowedPorts,
        onResult: @escaping (Result<String, SupabaseAuthClient.AuthError>) -> Void
    ) -> LoopbackRedirectServer? {
        for port in ports {
            if let server = try? LoopbackRedirectServer(port: port, onResult: onResult) {
                return server
            }
        }
        vlog("auth loopback: all ports taken, falling back to deep link")
        return nil
    }

    private init(
        port: UInt16,
        onResult: @escaping (Result<String, SupabaseAuthClient.AuthError>) -> Void
    ) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw POSIXError(.EINVAL) }
        let params = NWParameters.tcp
        // Loopback only — never reachable from the network.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        self.listener = try NWListener(using: params)
        self.port = port
        self.onResult = onResult
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        // A taken port surfaces as an async .failed state, not an init throw —
        // wait for the verdict so the try-each-port loop actually works. Bind
        // resolves in single-digit milliseconds; 1s is a generous ceiling.
        let ready = DispatchSemaphore(value: 0)
        var bound = false
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: bound = true; ready.signal()
            case .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 1) == .success, bound else {
            listener.cancel()
            throw POSIXError(.EADDRINUSE)
        }
        listener.stateUpdateHandler = nil
    }

    func stop() {
        queue.async { [self] in
            isStopped = true
            onResult = nil
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    deinit {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        guard Self.shouldAcceptConnection(
            retainedCount: connections.count,
            hasResultHandler: onResult != nil,
            isStopped: isStopped
        ) else {
            connection.cancel()
            return
        }
        connections.append(connection)
        connection.start(queue: queue)
        receiveRequestHead(from: connection, accumulated: Data())
    }

    private func receiveRequestHead(from connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, complete, error in
            guard let self, error == nil, let data else {
                self?.close(connection)
                return
            }
            switch Self.requestHeadResult(accumulated: accumulated, received: data, complete: complete) {
            case .target(let target):
                self.respond(to: connection, target: target)
            case .badRequest:
                self.send(connection, status: "400 Bad Request", body: "")
            case .waitForMore:
                self.receiveRequestHead(from: connection, accumulated: accumulated + data)
            }
        }
    }

    private func respond(to connection: NWConnection, target: String) {
        guard let result = Self.callbackResult(fromTarget: target) else {
            // Favicon or other stray request: close it, keep listening.
            send(connection, status: "404 Not Found", body: "")
            return
        }
        send(connection, status: "200 OK", body: Self.responseHTML())
        onResult?(result)
    }

    private func send(_ connection: NWConnection, status: String, body: String) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { [weak self] _ in
            self?.close(connection)
        })
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        connections.removeAll { $0 === connection }
    }
}
