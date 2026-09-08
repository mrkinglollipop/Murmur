import XCTest
@testable import Voice

/// Pro sign-in plumbing: PKCE primitives, authorize URL, callback parsing,
/// session decoding, and the AuthFlowController's pure decision seams. The
/// network legs (code exchange, refresh) are exercised end-to-end once the
/// OAuth providers exist — until then everything decidable offline is pinned
/// here.
final class ProAuthTests: XCTestCase {

    private actor SessionGate {
        private var continuations: [CheckedContinuation<SupabaseAuthClient.Session, Error>] = []
        private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        private var startCount = 0

        func fetch() async throws -> SupabaseAuthClient.Session {
            startCount += 1
            let ready = startWaiters.filter { $0.0 <= startCount }
            startWaiters.removeAll { $0.0 <= startCount }
            ready.forEach { $0.1.resume() }
            return try await withCheckedThrowingContinuation { continuation in
                self.continuations.append(continuation)
            }
        }

        func waitUntilStarted(count: Int = 1) async {
            guard startCount < count else { return }
            await withCheckedContinuation { startWaiters.append((count, $0)) }
        }

        func succeed(_ session: SupabaseAuthClient.Session) {
            guard !continuations.isEmpty else { return }
            continuations.removeFirst().resume(returning: session)
        }

        func fail() {
            guard !continuations.isEmpty else { return }
            continuations.removeFirst().resume(throwing: SupabaseAuthClient.AuthError.badResponse(400))
        }
    }

    private func session(refreshToken: String = "refreshed") -> SupabaseAuthClient.Session {
        SupabaseAuthClient.Session(
            accessToken: "access",
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(3600),
            userID: "user-1",
            email: nil
        )
    }

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

    func testLoopbackCallbackMustMatchItsBrowserAttempt() {
        let waiting = AuthFlowController.State.waitingForBrowser(provider: .google, startedAt: Date())
        XCTAssertFalse(
            AuthFlowController.shouldHandleLoopbackCallback(
                generation: 4,
                currentGeneration: 5,
                state: waiting
            )
        )
        XCTAssertTrue(
            AuthFlowController.shouldHandleLoopbackCallback(
                generation: 5,
                currentGeneration: 5,
                state: waiting
            )
        )
    }

    @MainActor
    func testCancelledExchangeCannotResurrectSession() async {
        let gate = SessionGate()
        var storedToken: String?
        let controller = AuthFlowController(
            exchangeCode: { _, _ in try await gate.fetch() },
            openBrowser: { _ in },
            readStoredToken: { storedToken },
            writeStoredToken: { storedToken = $0 },
            deleteStoredToken: { storedToken = nil }
        )

        controller.beginSignIn(provider: .google)
        XCTAssertTrue(controller.handleCallback(URL(string: "murmur://auth-callback?code=late")!))
        await gate.waitUntilStarted()
        controller.cancelSignIn()
        await gate.succeed(session())
        for _ in 0..<4 { await Task.yield() }

        XCTAssertEqual(controller.state, .signedOut)
        XCTAssertNil(storedToken)
    }

    @MainActor
    func testRejectedCallbackKeepsBrowserAttemptAvailableForCurrentCallback() async throws {
        let gate = SessionGate()
        let controller = AuthFlowController(
            exchangeCode: { _, _ in try await gate.fetch() },
            openBrowser: { _ in },
            readStoredToken: { nil },
            writeStoredToken: { _ in },
            deleteStoredToken: {}
        )

        controller.beginSignIn(provider: .google)
        XCTAssertTrue(controller.handleCallback(URL(string: "murmur://auth-callback?code=stale")!))
        await gate.waitUntilStarted()
        // Simulate Supabase rejecting a stale PKCE code. The controller must
        // preserve its waiting state and verifier for the active browser.
        await gate.fail()
        if case .waitingForBrowser = controller.state {
            // Expected: a later callback from the still-open browser can land.
        } else {
            XCTFail("rejected callback ended the active browser attempt")
        }

        XCTAssertTrue(controller.handleCallback(URL(string: "murmur://auth-callback?code=current")!))
        await gate.waitUntilStarted(count: 2)
        let accepted = session()
        await gate.succeed(accepted)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(controller.state, .signedIn(accepted))
    }

    @MainActor
    func testFirstSuccessfulExchangeWinsWhenLaterCallbackFails() async {
        let gate = SessionGate()
        let accepted = session(refreshToken: "accepted")
        let controller = AuthFlowController(
            exchangeCode: { _, _ in try await gate.fetch() },
            openBrowser: { _ in },
            readStoredToken: { nil },
            writeStoredToken: { _ in },
            deleteStoredToken: {}
        )

        controller.beginSignIn(provider: .google)
        XCTAssertTrue(controller.handleCallback(URL(string: "murmur://auth-callback?code=current")!))
        await gate.waitUntilStarted()
        XCTAssertTrue(controller.handleCallback(URL(string: "murmur://auth-callback?code=stale")!))
        await gate.waitUntilStarted(count: 2)

        await gate.succeed(accepted)
        await gate.fail()
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(controller.state, .signedIn(accepted))
    }

    @MainActor
    func testErrorOnlyCallbackKeepsBrowserAttemptAvailableForCurrentCallback() async {
        let gate = SessionGate()
        let controller = AuthFlowController(
            exchangeCode: { _, _ in try await gate.fetch() },
            openBrowser: { _ in },
            readStoredToken: { nil },
            writeStoredToken: { _ in },
            deleteStoredToken: {}
        )

        controller.beginSignIn(provider: .google)
        XCTAssertTrue(controller.handleCallback(URL(string: "murmur://auth-callback?error=access_denied")!))
        if case .waitingForBrowser = controller.state {
            // Expected: error-only callbacks cannot be correlated safely.
        } else {
            XCTFail("error-only callback ended the active browser attempt")
        }
        XCTAssertTrue(controller.handleCallback(URL(string: "murmur://auth-callback?code=current")!))
        await gate.waitUntilStarted()
        let accepted = session()
        await gate.succeed(accepted)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(controller.state, .signedIn(accepted))
    }

    @MainActor
    func testSignOutCannotBeUndoneByLateRestore() async {
        let gate = SessionGate()
        var storedToken: String? = "old-refresh"
        let controller = AuthFlowController(
            refreshToken: { _ in try await gate.fetch() },
            openBrowser: { _ in },
            readStoredToken: { storedToken },
            writeStoredToken: { storedToken = $0 },
            deleteStoredToken: { storedToken = nil }
        )

        let restore = Task { await controller.restoreSessionIfAvailable() }
        await gate.waitUntilStarted()
        controller.signOut()
        await gate.succeed(session())
        await restore.value

        XCTAssertEqual(controller.state, .signedOut)
        XCTAssertNil(storedToken)
    }

    @MainActor
    func testLatestConcurrentRestoreKeepsNewestRotatedToken() async {
        let gate = SessionGate()
        var storedToken: String? = "old-refresh"
        let controller = AuthFlowController(
            refreshToken: { _ in try await gate.fetch() },
            openBrowser: { _ in },
            readStoredToken: { storedToken },
            writeStoredToken: { storedToken = $0 },
            deleteStoredToken: { storedToken = nil }
        )

        let first = Task { await controller.restoreSessionIfAvailable() }
        await gate.waitUntilStarted()
        let second = Task { await controller.restoreSessionIfAvailable() }
        await gate.waitUntilStarted(count: 2)
        let older = session(refreshToken: "older-rotated")
        let newer = session(refreshToken: "newer-rotated")
        await gate.succeed(older)
        await gate.succeed(newer)
        await first.value
        await second.value

        XCTAssertEqual(storedToken, "newer-rotated")
        XCTAssertEqual(controller.state, .signedIn(newer))
    }

}
