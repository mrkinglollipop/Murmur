import CryptoKit
import Foundation

/// Browser-based OAuth (PKCE) against the Murmur Pro Supabase project.
///
/// Deliberately hand-rolled over URLSession instead of pulling in
/// supabase-swift: the app needs exactly three requests (authorize URL
/// construction, code exchange, refresh), every decision seam here is a pure
/// function a unit test can reach, and the dependency wall stays where it is.
///
/// Flow: `authorizeURL` opens in the system browser → Supabase redirects to
/// `murmur://auth-callback?code=…` → `exchangeCode` posts the code + verifier
/// for a session. Native Sign in with Apple is unavailable to Developer ID
/// apps, so this round trip is the only sign-in path (Murmur-server/plans/001).
struct SupabaseAuthClient {

    /// Anon key is a public client identifier by design (RLS is the guard);
    /// embedding it in source is normal Supabase practice.
    static let projectURL = URL(string: "https://bodfkiwketsdmkzndjme.supabase.co")!
    // Publishable key: public by design (ships in every client); all access
    // control lives in RLS policies server-side. Rotating it in the dashboard
    // requires updating it here.
    static let anonKey = "sb_publishable_zkTW2u3iywE1KeVGUZDPng_-z1RpKc_"
    static let redirectURI = "murmur://auth-callback"

    enum Provider: String {
        case apple
        case google
    }

    struct Session: Equatable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
        let userID: String
        let email: String?
    }

    enum AuthError: Error, Equatable {
        case callbackCarriedError(String)
        case callbackMissingCode
        /// Supabase documents these stable refresh errors. Only these mean the
        /// stored session is definitely gone; an HTTP status alone may be a
        /// transient server or transport failure.
        case invalidRefreshToken
        case badResponse(Int)
        case malformedSession
    }

    // MARK: - PKCE (pure)

    /// RFC 7636 §4.1 — 32 random octets, base64url without padding (43 chars).
    static func makeCodeVerifier(randomBytes: [UInt8]? = nil) -> String {
        let bytes = randomBytes ?? (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        return base64URL(Data(bytes))
    }

    /// RFC 7636 §4.2 — S256: base64url(SHA256(ascii(verifier))).
    static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The browser destination. Supabase drives the provider hop and lands
    /// back on `redirectTo` with a single-use code (5-minute lifetime).
    /// Default is the custom-scheme deep link; sign-in normally passes a
    /// loopback URI instead so the browser tab gets a real page to render.
    static func authorizeURL(provider: Provider, verifier: String, redirectTo: String = redirectURI) -> URL {
        var c = URLComponents(url: projectURL.appendingPathComponent("/auth/v1/authorize"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "provider", value: provider.rawValue),
            URLQueryItem(name: "redirect_to", value: redirectTo),
            URLQueryItem(name: "code_challenge", value: codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
        ]
        return c.url!
    }

    // MARK: - Callback (pure)

    static func isAuthCallback(_ url: URL) -> Bool {
        url.scheme == "murmur" && url.host == "auth-callback"
    }

    /// Extract the auth code from the deep link, or the error Supabase sent.
    static func parseCallback(_ url: URL) -> Result<String, AuthError> {
        guard isAuthCallback(url) else { return .failure(.callbackMissingCode) }
        return parseCallbackItems(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
    }

    /// Shared by the deep-link and loopback callback paths.
    static func parseCallbackItems(_ items: [URLQueryItem]) -> Result<String, AuthError> {
        if let err = items.first(where: { $0.name == "error_description" })?.value
            ?? items.first(where: { $0.name == "error" })?.value {
            return .failure(.callbackCarriedError(err))
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            return .failure(.callbackMissingCode)
        }
        return .success(code)
    }

    // MARK: - Session decoding (pure)

    /// Token endpoint payload → Session. Lenient: only the four fields the
    /// app actually needs are required; Supabase adds others freely.
    static func decodeSession(_ data: Data, now: Date = Date()) -> Session? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let access = obj["access_token"] as? String,
            let refresh = obj["refresh_token"] as? String,
            let user = obj["user"] as? [String: Any],
            let userID = user["id"] as? String
        else { return nil }
        let expiresIn = (obj["expires_in"] as? Double) ?? 3600
        return Session(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: now.addingTimeInterval(expiresIn),
            userID: userID,
            email: user["email"] as? String
        )
    }

    // MARK: - Network

    private static func tokenRequest(grantType: String, body: [String: String]) -> URLRequest {
        var c = URLComponents(url: projectURL.appendingPathComponent("/auth/v1/token"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "grant_type", value: grantType)]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    static func exchangeCode(_ code: String, verifier: String) async throws -> Session {
        let req = tokenRequest(grantType: "pkce", body: ["auth_code": code, "code_verifier": verifier])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            vlog("supabase auth: code exchange failed (\(status))")
            throw AuthError.badResponse(status)
        }
        guard let session = decodeSession(data) else { throw AuthError.malformedSession }
        vlog("supabase auth: session established (user \(session.userID.prefix(8))…)")
        return session
    }

    static func refresh(refreshToken: String) async throws -> Session {
        let req = tokenRequest(grantType: "refresh_token", body: ["refresh_token": refreshToken])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if isExplicitlyInvalidRefreshResponse(data) {
                throw AuthError.invalidRefreshToken
            }
            throw AuthError.badResponse(status)
        }
        guard let session = decodeSession(data) else { throw AuthError.malformedSession }
        return session
    }

    /// Only documented machine-readable codes revoke a local session. Generic
    /// 400/401/5xx responses can come from an unavailable server or proxy and
    /// must leave the signed-in session intact for an offline retry.
    static func isExplicitlyInvalidRefreshResponse(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let code = object["error_code"] as? String ?? object["code"] as? String
        return code == "refresh_token_already_used" || code == "refresh_token_not_found"
    }
}
