// PRO ONLY — this file is part of the paid feature set and must never merge
// into `main`. See the "Clipboard manager" section of CLAUDE.md.

import Foundation
import Network

/// One-shot loopback HTTP listener for the OAuth browser round trip.
///
/// A browser cannot render a `murmur://` custom-scheme redirect — macOS hands
/// the URL to the app, but the tab itself is left spinning forever. Binding a
/// local port for the duration of sign-in lets Supabase redirect the browser
/// to `http://127.0.0.1:<port>/auth-callback?...` instead: this listener
/// answers with a small "you can close this tab" page while handing the auth
/// code to the flow controller. The custom-scheme path remains as fallback.
final class LoopbackRedirectServer {

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
        let parts = head.split(separator: "\r\n").first?.split(separator: " ") ?? []
        guard parts.count >= 3, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    /// nil when the target isn't the callback path (favicon and friends);
    /// otherwise the parsed auth code or the error Supabase reported.
    static func callbackResult(fromTarget target: String) -> Result<String, SupabaseAuthClient.AuthError>? {
        guard let components = URLComponents(string: target),
              components.path == callbackPath else { return nil }
        return SupabaseAuthClient.parseCallbackItems(components.queryItems ?? [])
    }

    static func responseHTML(success: Bool) -> String {
        let headline = success ? "You&#8217;re signed in" : "Sign-in didn&#8217;t complete"
        let detail = success
            ? "You can close this tab and return to Murmur."
            : "You can close this tab and try again in Murmur."
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Murmur</title>
        <style>
        body{font-family:-apple-system,system-ui,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#faf7f2;color:#3a3532}
        @media(prefers-color-scheme:dark){body{background:#1c1a18;color:#e8e2da}}
        main{text-align:center}h1{font-size:22px;font-weight:600;margin:0 0 8px}p{font-size:14px;opacity:.7;margin:0}
        </style></head><body><main><h1>\(headline)</h1><p>\(detail)</p></main></body></html>
        """
    }

    // MARK: - Listener

    let port: UInt16
    var redirectURI: String { Self.redirectURI(port: port) }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.matt.voice-dictation.loopback-auth")
    private var connections: [NWConnection] = []
    private var onResult: ((Result<String, SupabaseAuthClient.AuthError>) -> Void)?
    private var hasDelivered = false

    /// Binds the first free allow-listed port, or nil when none is available.
    /// `onResult` fires at most once, on an internal queue — hop to the main
    /// actor before touching UI state.
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

    private init(port: UInt16, onResult: @escaping (Result<String, SupabaseAuthClient.AuthError>) -> Void) throws {
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
        connections.append(connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, error in
            guard let self, error == nil, let data,
                  let head = String(data: data, encoding: .utf8),
                  let target = Self.requestTarget(fromRequestHead: head) else {
                connection.cancel()
                return
            }
            self.respond(to: connection, target: target)
        }
    }

    private func respond(to connection: NWConnection, target: String) {
        guard let result = Self.callbackResult(fromTarget: target) else {
            // Favicon or other stray request: close it, keep listening.
            send(connection, status: "404 Not Found", body: "")
            return
        }
        let success: Bool
        if case .success = result { success = true } else { success = false }
        send(connection, status: "200 OK", body: Self.responseHTML(success: success))
        if !hasDelivered {
            hasDelivered = true
            onResult?(result)
            onResult = nil
        }
    }

    private func send(_ connection: NWConnection, status: String, body: String) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
