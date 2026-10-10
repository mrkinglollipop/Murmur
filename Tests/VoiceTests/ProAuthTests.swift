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

        func numberOfStarts() -> Int { startCount }

        func succeed(_ session: SupabaseAuthClient.Session) {
            guard !continuations.isEmpty else { return }
            continuations.removeFirst().resume(returning: session)
        }

        func fail() {
            guard !continuations.isEmpty else { return }
            continuations.removeFirst().resume(throwing: SupabaseAuthClient.AuthError.badResponse(400))
        }
    }

    private func session(
        refreshToken: String = "refreshed",
        expiresIn: TimeInterval = 3600
    ) -> SupabaseAuthClient.Session {
        SupabaseAuthClient.Session(
            accessToken: "access",
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn),
            userID: "user-1",
            email: nil
        )
    }

    @MainActor
    private func waitForState(
        _ controller: AuthFlowController,
        _ expected: AuthFlowController.State,
        timeout: TimeInterval = 10
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if controller.state == expected { return }
            await Task.yield()
        }
        XCTAssertEqual(controller.state, expected, "controller did not reach expected state before deadline")
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

    @MainActor
    func testControllerOwnsAutomaticBrowserExpiry() async {
        let controller = AuthFlowController(
            openBrowser: { _ in },
            readStoredToken: { nil },
            writeStoredToken: { _ in },
            deleteStoredToken: {},
            browserTimeout: -1,
            waitForBrowserTimeout: {}
        )
        controller.beginSignIn(provider: .apple)
        await waitForState(controller, .failed("That took too long — try again."))
        XCTAssertTrue(controller.handleCallback(URL(string: "murmur://auth-callback?code=late")!))
        XCTAssertEqual(controller.state, .failed("That took too long — try again."))
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
        await waitForState(controller, .signedIn(accepted))
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
        await waitForState(controller, .signedIn(accepted))
        XCTAssertEqual(controller.state, .signedIn(accepted))
    }

    @MainActor
    func testAuthenticatedSessionRefreshesWithinMarginAndPersistsRotation() async {
        let initial = session(refreshToken: "initial", expiresIn: 30)
        let refreshed = session(refreshToken: "rotated")
        var storedTokens: [String] = []
        let controller = AuthFlowController(
            exchangeCode: { _, _ in initial },
            refreshToken: { _ in refreshed },
            openBrowser: { _ in },
            readStoredToken: { nil },
            writeStoredToken: { storedTokens.append($0) },
            deleteStoredToken: {}
        )

        controller.beginSignIn(provider: .google)
        XCTAssertTrue(controller.handleCallback(URL(string: "murmur://auth-callback?code=current")!))
        await waitForState(controller, .signedIn(initial))

        let safe = await controller.authenticatedSession()
        XCTAssertEqual(safe, refreshed)
        XCTAssertEqual(controller.state, .signedIn(refreshed))
        XCTAssertEqual(storedTokens, ["initial", "rotated"])
    }

    @MainActor
    func testFreshAuthenticatedSessionDoesNotRefresh() async {
        let initial = session(refreshToken: "initial", expiresIn: 3600)
        let controller = AuthFlowController(
            exchangeCode: { _, _ in initial },
            refreshToken: { _ in
                XCTFail("fresh session must not refresh")
                return initial
            },
            openBrowser: { _ in },
            readStoredToken: { nil },
            writeStoredToken: { _ in },
            deleteStoredToken: {}
        )

        controller.beginSignIn(provider: .google)
        XCTAssertTrue(controller.handleCallback(URL(string: "murmur://auth-callback?code=current")!))
        await waitForState(controller, .signedIn(initial))
        let safe = await controller.authenticatedSession()
        XCTAssertEqual(safe, initial)
    }

    @MainActor
    func testInitialTokenPersistenceFailureSurfacesControllerError() async {
        let controller = AuthFlowController(
            exchangeCode: { _, _ in self.session() },
            openBrowser: { _ in },
            readStoredToken: { nil },
            persistStoredToken: { _ in false },
            removeStoredToken: { true }
        )
        controller.beginSignIn(provider: .google)
        XCTAssertTrue(controller.handleCallback(URL(string: "murmur://auth-callback?code=current")!))
        await waitForState(controller, .failed("Murmur couldn't save your sign-in. Try again."))
    }

    @MainActor
    func testRefreshTokenPersistenceFailurePreservesLiveSessionAndReportsError() async {
        let initial = session(refreshToken: "initial", expiresIn: 30)
        let refreshed = session(refreshToken: "rotated")
        var writeCount = 0
        let controller = AuthFlowController(
            exchangeCode: { _, _ in initial },
            refreshToken: { _ in refreshed },
            openBrowser: { _ in },
            readStoredToken: { nil },
            persistStoredToken: { _ in
                writeCount += 1
                return writeCount == 1
            },
            removeStoredToken: { true }
        )
        controller.beginSignIn(provider: .google)
        XCTAssertTrue(controller.handleCallback(URL(string: "murmur://auth-callback?code=current")!))
        await waitForState(controller, .signedIn(initial))
        let safe = await controller.authenticatedSession()
        XCTAssertEqual(safe, refreshed)
        XCTAssertEqual(controller.state, .signedIn(refreshed))
        XCTAssertEqual(controller.lastError, "Murmur couldn't save the renewed sign-in.")
    }

    @MainActor
    func testTokenDeletionFailureKeepsAccountSheetOpenWithError() async {
        let signedIn = session()
        let controller = AuthFlowController(
            exchangeCode: { _, _ in signedIn },
            openBrowser: { _ in },
            readStoredToken: { nil },
            persistStoredToken: { _ in true },
            removeStoredToken: { false }
        )
        controller.beginSignIn(provider: .google)
        XCTAssertTrue(controller.handleCallback(URL(string: "murmur://auth-callback?code=current")!))
        await waitForState(controller, .signedIn(signedIn))
        controller.signOut()
        XCTAssertEqual(controller.state, .signedIn(signedIn))
        XCTAssertEqual(controller.lastError, "Murmur couldn't remove your saved sign-in.")
    }

    @MainActor
    func testConcurrentAuthenticatedRequestsShareOneRefresh() async {
        let gate = SessionGate()
        let initial = session(refreshToken: "initial", expiresIn: 30)
        let refreshed = session(refreshToken: "initial")
        var storedTokens: [String] = []
        let controller = AuthFlowController(
            exchangeCode: { _, _ in initial },
            refreshToken: { _ in try await gate.fetch() },
            openBrowser: { _ in },
            readStoredToken: { nil },
            writeStoredToken: { storedTokens.append($0) },
            deleteStoredToken: {}
        )

        controller.beginSignIn(provider: .google)
        XCTAssertTrue(controller.handleCallback(URL(string: "murmur://auth-callback?code=current")!))
        await waitForState(controller, .signedIn(initial))

        let first = Task { await controller.authenticatedSession() }
        await gate.waitUntilStarted()
        let second = Task { await controller.authenticatedSession() }
        await gate.succeed(refreshed)
        let firstValue = await first.value
        let secondValue = await second.value
        let starts = await gate.numberOfStarts()
        XCTAssertEqual(firstValue, refreshed)
        XCTAssertEqual(secondValue, refreshed)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(storedTokens, ["initial", "initial"], "shared refresh persists once even when rotation keeps the same token")
    }

    @MainActor
    func testLateRefreshCannotReplaceNewSignInSession() async {
        let gate = SessionGate()
        let old = session(refreshToken: "shared", expiresIn: 30)
        let new = session(refreshToken: "shared", expiresIn: 3600)
        let controller = AuthFlowController(
            exchangeCode: { code, _ in code == "new" ? new : old },
            refreshToken: { _ in try await gate.fetch() },
            openBrowser: { _ in },
            readStoredToken: { nil },
            writeStoredToken: { _ in },
            deleteStoredToken: {}
        )

        controller.beginSignIn(provider: .google)
        XCTAssertTrue(controller.handleCallback(URL(string: "murmur://auth-callback?code=old")!))
        await waitForState(controller, .signedIn(old))
        let refresh = Task { await controller.authenticatedSession() }
        await gate.waitUntilStarted()

        controller.signOut()
        controller.beginSignIn(provider: .google)
        XCTAssertTrue(controller.handleCallback(URL(string: "murmur://auth-callback?code=new")!))
        await waitForState(controller, .signedIn(new))
        await gate.succeed(session(refreshToken: "old-rotated"))

        let oldRefreshResult = await refresh.value
        XCTAssertNil(oldRefreshResult)
        XCTAssertEqual(controller.state, .signedIn(new))
    }

    @MainActor
    func testUnreachableRefreshPreservesSessionAndReportsError() async {
        let initial = session(refreshToken: "initial", expiresIn: 30)
        let controller = AuthFlowController(
            exchangeCode: { _, _ in initial },
            refreshToken: { _ in throw SupabaseAuthClient.AuthError.badResponse(503) },
            openBrowser: { _ in },
            readStoredToken: { nil },
            writeStoredToken: { _ in },
            deleteStoredToken: {}
        )

        controller.beginSignIn(provider: .google)
        XCTAssertTrue(controller.handleCallback(URL(string: "murmur://auth-callback?code=current")!))
        await waitForState(controller, .signedIn(initial))

        let safe = await controller.authenticatedSession()
        XCTAssertNil(safe)
        XCTAssertEqual(controller.state, .signedIn(initial))
        XCTAssertTrue(controller.lastError?.contains("can't reach the server") == true)
    }

    @MainActor
    func testOnlyExplicitInvalidRefreshSignsOut() async {
        let initial = session(refreshToken: "initial", expiresIn: 30)
        var removed = false
        let controller = AuthFlowController(
            exchangeCode: { _, _ in initial },
            refreshToken: { _ in throw SupabaseAuthClient.AuthError.invalidRefreshToken },
            openBrowser: { _ in },
            readStoredToken: { nil },
            writeStoredToken: { _ in },
            deleteStoredToken: { removed = true }
        )

        controller.beginSignIn(provider: .google)
        XCTAssertTrue(controller.handleCallback(URL(string: "murmur://auth-callback?code=current")!))
        await waitForState(controller, .signedIn(initial))

        let safe = await controller.authenticatedSession()
        XCTAssertNil(safe)
        XCTAssertEqual(controller.state, .signedOut)
        XCTAssertTrue(removed)
    }

    func testOnlyDocumentedRefreshCodesInvalidateSession() {
        XCTAssertTrue(SupabaseAuthClient.isExplicitlyInvalidRefreshResponse(
            Data(#"{"error_code":"refresh_token_not_found"}"#.utf8)
        ))
        XCTAssertTrue(SupabaseAuthClient.isExplicitlyInvalidRefreshResponse(
            Data(#"{"code":"refresh_token_already_used"}"#.utf8)
        ))
        XCTAssertFalse(SupabaseAuthClient.isExplicitlyInvalidRefreshResponse(
            Data(#"{"code":"unexpected_error"}"#.utf8)
        ))
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
        await waitForState(controller, .signedIn(accepted))
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
