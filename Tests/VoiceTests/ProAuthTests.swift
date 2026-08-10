import XCTest
@testable import Voice

/// Pro sign-in plumbing: PKCE primitives, authorize URL, callback parsing,
/// session decoding, and the AuthFlowController's pure decision seams. The
/// network legs (code exchange, refresh) are exercised end-to-end once the
/// OAuth providers exist — until then everything decidable offline is pinned
/// here.
final class ProAuthTests: XCTestCase {

    // MARK: - PKCE

    func testCodeChallengeMatchesRFC7636TestVector() {
        // RFC 7636 appendix B: the canonical verifier/challenge pair.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(
            SupabaseAuthClient.codeChallenge(for: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testCodeVerifierShapeAndUniqueness() {
        let a = SupabaseAuthClient.makeCodeVerifier()
        let b = SupabaseAuthClient.makeCodeVerifier()
        // 32 octets → 43 base64url chars, no padding, URL-safe alphabet only.
        for v in [a, b] {
            XCTAssertEqual(v.count, 43)
            XCTAssertNil(v.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        }
        XCTAssertNotEqual(a, b)
    }

    func testDeterministicVerifierFromFixedBytes() {
        let v = SupabaseAuthClient.makeCodeVerifier(randomBytes: Array(repeating: 0, count: 32))
        XCTAssertEqual(v, String(repeating: "A", count: 43))
    }

    // MARK: - Authorize URL

    func testAuthorizeURLCarriesPKCEAndRedirect() throws {
        let url = SupabaseAuthClient.authorizeURL(provider: .apple, verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.host, "bodfkiwketsdmkzndjme.supabase.co")
        XCTAssertEqual(comps.path, "/auth/v1/authorize")
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["provider"], "apple")
        XCTAssertEqual(q["redirect_to"], "murmur://auth-callback")
        XCTAssertEqual(q["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(q["code_challenge_method"], "s256")
    }

    // MARK: - Callback parsing

    func testCallbackParsingExtractsCode() {
        let url = URL(string: "murmur://auth-callback?code=abc123")!
        XCTAssertEqual(SupabaseAuthClient.parseCallback(url), .success("abc123"))
    }

    func testCallbackParsingSurfacesProviderError() {
        let url = URL(string: "murmur://auth-callback?error=access_denied&error_description=User%20cancelled")!
        XCTAssertEqual(
            SupabaseAuthClient.parseCallback(url),
            .failure(.callbackCarriedError("User cancelled"))
        )
    }

    func testCallbackParsingRejectsMissingCodeAndForeignURLs() {
        XCTAssertEqual(
            SupabaseAuthClient.parseCallback(URL(string: "murmur://auth-callback")!),
            .failure(.callbackMissingCode)
        )
        XCTAssertEqual(
            SupabaseAuthClient.parseCallback(URL(string: "murmur://something-else?code=x")!),
            .failure(.callbackMissingCode)
        )
        XCTAssertFalse(SupabaseAuthClient.isAuthCallback(URL(string: "https://evil.example/auth-callback?code=x")!))
    }

    // MARK: - Session decoding

    func testSessionDecodingFromTokenPayload() throws {
        let json = """
        {"access_token":"at","token_type":"bearer","expires_in":3600,
         "refresh_token":"rt","user":{"id":"user-1","email":"m@example.com","role":"authenticated"}}
        """
        let now = Date(timeIntervalSince1970: 1_000_000)
        let s = try XCTUnwrap(SupabaseAuthClient.decodeSession(Data(json.utf8), now: now))
        XCTAssertEqual(s.accessToken, "at")
        XCTAssertEqual(s.refreshToken, "rt")
        XCTAssertEqual(s.userID, "user-1")
        XCTAssertEqual(s.email, "m@example.com")
        XCTAssertEqual(s.expiresAt, now.addingTimeInterval(3600))
    }

    func testSessionDecodingRejectsIncompletePayloads() {
        XCTAssertNil(SupabaseAuthClient.decodeSession(Data("{}".utf8)))
        XCTAssertNil(SupabaseAuthClient.decodeSession(Data(#"{"access_token":"at"}"#.utf8)))
        XCTAssertNil(SupabaseAuthClient.decodeSession(Data("not json".utf8)))
    }

    // MARK: - AuthFlowController pure seams

    func testCallbackOnlyHandledWhileWaiting() {
        XCTAssertTrue(
            AuthFlowController.shouldHandleCallback(
                state: .waitingForBrowser(provider: .apple, startedAt: Date())
            )
        )
        XCTAssertFalse(AuthFlowController.shouldHandleCallback(state: .signedOut))
        XCTAssertFalse(AuthFlowController.shouldHandleCallback(state: .exchanging))
        XCTAssertFalse(AuthFlowController.shouldHandleCallback(state: .failed("x")))
    }

    func testWaitingExpiryUsesFiveMinuteBudget() {
        let start = Date(timeIntervalSince1970: 0)
        let waiting = AuthFlowController.State.waitingForBrowser(provider: .google, startedAt: start)
        XCTAssertFalse(
            AuthFlowController.waitingHasExpired(state: waiting, now: start.addingTimeInterval(299))
        )
        XCTAssertTrue(
            AuthFlowController.waitingHasExpired(state: waiting, now: start.addingTimeInterval(301))
        )
        XCTAssertFalse(
            AuthFlowController.waitingHasExpired(state: .signedOut, now: start.addingTimeInterval(9999))
        )
    }
}
