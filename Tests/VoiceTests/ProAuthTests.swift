import XCTest
import Security
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

    @MainActor
    func testRestorePersistenceFailurePreservesSessionAndRetriesRotatedToken() async {
        let restored = session(refreshToken: "renewed")
        var writes: [String] = []
        var canPersist = false
        var refreshes = 0
        let controller = AuthFlowController(
            refreshToken: { _ in refreshes += 1; return restored },
            openBrowser: { _ in }, readStoredToken: { "saved" },
            persistStoredToken: { writes.append($0); return canPersist },
            removeStoredToken: { true }
        )
        await controller.restoreSessionIfAvailable()
        XCTAssertEqual(controller.state, .signedIn(restored))
        XCTAssertNotNil(controller.lastError)
        canPersist = true
        let available = await controller.authenticatedSession()
        XCTAssertEqual(available, restored)
        XCTAssertEqual(writes, ["renewed", "renewed"])
        XCTAssertEqual(refreshes, 1)
        XCTAssertNil(controller.lastError)
    }

    @MainActor
    func testForegroundRetriesTransientRestoreFailure() async {
        let restored = session()
        var attempts = 0
        let controller = AuthFlowController(
            refreshToken: { _ in
                attempts += 1
                if attempts == 1 { throw SupabaseAuthClient.AuthError.badResponse(503) }
                return restored
            },
            openBrowser: { _ in }, readStoredToken: { "saved" },
            persistStoredToken: { _ in true }, removeStoredToken: { true }
        )
        await controller.restoreSessionIfAvailable()
        XCTAssertEqual(controller.state, .signedOut)
        let available = await controller.sessionForForegroundActivation()
        XCTAssertEqual(available, restored)
        XCTAssertEqual(controller.state, .signedIn(restored))
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testExplicitSignOutSuppressesPendingRestoreRetryEvenIfDeletionFails() async {
        var attempts = 0
        let controller = AuthFlowController(
            refreshToken: { _ in attempts += 1; throw URLError(.notConnectedToInternet) },
            openBrowser: { _ in }, readStoredToken: { "saved" },
            persistStoredToken: { _ in true }, removeStoredToken: { false }
        )
        await controller.restoreSessionIfAvailable()
        controller.signOut()
        let available = await controller.sessionForForegroundActivation()
        XCTAssertNil(available)
        XCTAssertEqual(attempts, 1)
    }

    @MainActor
    func testForegroundRecoveryUnlocksCachedPaidAccount() async throws {
        let suiteName = "murmur-pro-restore-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let restored = session()
        let entitlement = EntitlementStore(defaults: defaults, fetcher: { _ in true })
        await entitlement.refresh(session: restored)
        entitlement.clear()
        entitlement.fetcher = { _ in throw URLError(.notConnectedToInternet) }
        var attempts = 0
        let controller = AuthFlowController(
            refreshToken: { _ in
                attempts += 1
                if attempts == 1 { throw URLError(.notConnectedToInternet) }
                return restored
            },
            readStoredToken: { "saved" }, persistStoredToken: { _ in true }, removeStoredToken: { true }
        )
        await controller.restoreSessionIfAvailable()
        XCTAssertFalse(entitlement.isPro)
        if let available = await controller.sessionForForegroundActivation() {
            await entitlement.refresh(session: available) { await controller.authenticatedSession() }
        }
        XCTAssertTrue(entitlement.isPro)
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testInvalidRestoreNeverRetriesOnForeground() async {
        var attempts = 0
        let controller = AuthFlowController(
            refreshToken: { _ in attempts += 1; throw SupabaseAuthClient.AuthError.invalidRefreshToken },
            readStoredToken: { "revoked" }, persistStoredToken: { _ in true }, removeStoredToken: { false }
        )
        await controller.restoreSessionIfAvailable()
        let available = await controller.sessionForForegroundActivation()
        XCTAssertNil(available)
        XCTAssertEqual(attempts, 1)
    }

    @MainActor
    func testLateRestoreFailureCannotRetryAfterSignOut() async {
        let gate = SessionGate()
        var attempts = 0
        let controller = AuthFlowController(
            refreshToken: { _ in
                attempts += 1
                if attempts == 1 { return try await gate.fetch() }
                throw URLError(.notConnectedToInternet)
            },
            readStoredToken: { "saved" }, persistStoredToken: { _ in true }, removeStoredToken: { true }
        )
        let restore = Task { await controller.restoreSessionIfAvailable() }
        await gate.waitUntilStarted()
        controller.signOut()
        await gate.fail()
        await restore.value
        let available = await controller.sessionForForegroundActivation()
        XCTAssertNil(available)
        XCTAssertEqual(attempts, 1)
        XCTAssertNil(controller.lastError)
    }

    @MainActor
    func testConcurrentForegroundNotificationsShareRestoreRetry() async {
        let gate = SessionGate()
        let restored = session()
        var attempts = 0
        let controller = AuthFlowController(
            refreshToken: { _ in
                attempts += 1
                if attempts == 1 { throw URLError(.notConnectedToInternet) }
                if attempts == 2 { return try await gate.fetch() }
                return restored
            },
            readStoredToken: { "saved" }, persistStoredToken: { _ in true }, removeStoredToken: { true }
        )
        await controller.restoreSessionIfAvailable()
        let first = Task { await controller.sessionForForegroundActivation() }
        await gate.waitUntilStarted()
        let second = await controller.sessionForForegroundActivation()
        XCTAssertNil(second)
        XCTAssertEqual(attempts, 2)
        await gate.succeed(restored)
        let available = await first.value
        XCTAssertEqual(available, restored)
    }

    @MainActor
    func testCorruptStoredTokenNeverRetriesOnForeground() async {
        var reads = 0
        let keychain = KeychainStore(
            service: "murmur-auth-memory-test",
            operations: KeychainOperations(
                read: { query in
                    XCTAssertEqual(query[kSecAttrAccount as String] as? String, AuthFlowController.keychainAccount)
                    reads += 1
                    return (errSecSuccess, Data([0xff]))
                },
                add: { _ in XCTFail("Unexpected Keychain write"); return errSecSuccess },
                update: { _, _ in XCTFail("Unexpected Keychain update"); return errSecSuccess },
                delete: { _ in XCTFail("Corrupt credential must be preserved"); return errSecSuccess }
            )
        )
        let controller = AuthFlowController(
            keychain: keychain,
            exchangeCode: { _, _ in
                XCTFail("Unexpected code exchange")
                throw SupabaseAuthClient.AuthError.invalidRefreshToken
            },
            refreshToken: { _ in
                XCTFail("Corrupt credential must not reach refresh")
                throw SupabaseAuthClient.AuthError.invalidRefreshToken
            },
            openBrowser: { _ in XCTFail("Unexpected browser launch") }
        )

        await controller.restoreSessionIfAvailable()
        XCTAssertEqual(reads, 1)
        let first = await controller.sessionForForegroundActivation()
        let second = await controller.sessionForForegroundActivation()

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(reads, 1, "Permanent credential corruption must not retry on activation")
        XCTAssertEqual(controller.state, .signedOut)
        XCTAssertTrue(controller.lastError?.contains("Please sign in again") == true)
    }

    @MainActor
    func testKeychainReadDenialRetriesLaunchAndPendingForegroundRestore() async {
        for failNetworkFirst in [false, true] {
            let restored = session(refreshToken: "rotated")
            var denyRead = !failNetworkFirst
            var reads = 0
            var refreshes = 0
            let keychain = KeychainStore(
                service: "murmur-auth-memory-test",
                operations: KeychainOperations(
                    read: { query in
                        XCTAssertEqual(query[kSecAttrAccount as String] as? String, AuthFlowController.keychainAccount)
                        reads += 1
                        return denyRead ? (errSecInteractionNotAllowed, nil) : (errSecSuccess, Data("saved".utf8))
                    },
                    add: { _ in XCTFail("Unexpected Keychain write"); return errSecSuccess },
                    update: { _, _ in XCTFail("Unexpected Keychain update"); return errSecSuccess },
                    delete: { _ in XCTFail("Unexpected Keychain delete"); return errSecSuccess }
                )
            )
            let controller = AuthFlowController(
                keychain: keychain,
                refreshToken: { token in
                    XCTAssertEqual(token, "saved")
                    refreshes += 1
                    if failNetworkFirst && refreshes == 1 { throw URLError(.notConnectedToInternet) }
                    return restored
                },
                openBrowser: { _ in XCTFail("Unexpected browser launch") },
                persistStoredToken: { _ in true }, removeStoredToken: { XCTFail("Unexpected deletion"); return true }
            )
            await controller.restoreSessionIfAvailable()
            if failNetworkFirst {
                denyRead = true
                let unavailable = await controller.sessionForForegroundActivation()
                XCTAssertNil(unavailable)
            }
            XCTAssertEqual(controller.state, .signedOut)
            denyRead = false
            let available = await controller.sessionForForegroundActivation()
            XCTAssertEqual(available, restored)
            XCTAssertEqual(controller.state, .signedIn(restored))
            XCTAssertEqual(reads, failNetworkFirst ? 3 : 2)
            XCTAssertEqual(refreshes, failNetworkFirst ? 2 : 1)
        }
    }

    private final class ExpiredSessionProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            XCTAssertEqual(request.url?.path, "/auth/v1/token")
            XCTAssertEqual(request.url?.query, "grant_type=refresh_token")
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"code":"session_expired"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    @MainActor
    func testExpiredSessionResponseInvalidatesCredentialsWithoutForegroundRetries() async {
        XCTAssertTrue(URLProtocol.registerClass(ExpiredSessionProtocol.self))
        defer { URLProtocol.unregisterClass(ExpiredSessionProtocol.self) }
        var savedToken: String? = "expired"
        var refreshes = 0
        var deletions = 0
        let controller = AuthFlowController(
            refreshToken: { token in
                refreshes += 1
                return try await SupabaseAuthClient.refresh(refreshToken: token)
            },
            openBrowser: { _ in XCTFail("Unexpected browser launch") },
            readStoredToken: { savedToken },
            persistStoredToken: { _ in XCTFail("Expired session must not persist"); return true },
            removeStoredToken: { deletions += 1; savedToken = nil; return true }
        )
        await controller.restoreSessionIfAvailable()
        let first = await controller.sessionForForegroundActivation()
        let second = await controller.sessionForForegroundActivation()
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(controller.state, .signedOut)
        XCTAssertNil(savedToken)
        XCTAssertEqual(deletions, 1)
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(controller.lastError, "Your sign-in expired. Please sign in again.")
    }

    @MainActor
    func testFailedSignOutPreservesRotatedTokenPersistenceRetry() async {
        let restored = session(refreshToken: "rotated")
        var savedToken = "old"
        var writes: [String] = []
        var keychainAvailable = false
        var refreshes = 0
        let controller = AuthFlowController(
            refreshToken: { _ in refreshes += 1; return restored },
            openBrowser: { _ in XCTFail("Unexpected browser launch") },
            readStoredToken: { savedToken },
            persistStoredToken: { token in
                writes.append(token)
                guard keychainAvailable else { return false }
                savedToken = token
                return true
            },
            removeStoredToken: { keychainAvailable }
        )
        await controller.restoreSessionIfAvailable()
        controller.signOut()
        XCTAssertEqual(controller.state, .signedIn(restored))
        XCTAssertEqual(savedToken, "old")
        keychainAvailable = true
        let available = await controller.authenticatedSession()
        XCTAssertEqual(available, restored)
        XCTAssertEqual(writes, ["rotated", "rotated"])
        XCTAssertEqual(savedToken, "rotated")
        XCTAssertEqual(refreshes, 1)
        XCTAssertNil(controller.lastError)
    }

}
