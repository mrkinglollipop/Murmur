import XCTest
@testable import Voice

/// Entitlement gate: request shape, response parsing, the offline-cache
/// policy, and the sidebar gating that hangs off it. All network-free — the
/// store takes an injected fetcher.
final class ProEntitlementTests: XCTestCase {

    private actor BoolGate {
        private var continuation: CheckedContinuation<Bool, Error>?
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var started = false

        func fetch() async throws -> Bool {
            started = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func succeed(_ value: Bool) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "murmur-entitlement-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func session(userID: String = "user-1") -> SupabaseAuthClient.Session {
        SupabaseAuthClient.Session(
            accessToken: "token-abc",
            refreshToken: "refresh-abc",
            expiresAt: Date().addingTimeInterval(3600),
            userID: userID,
            email: "test@example.com"
        )
    }

    // MARK: - Request

    func testRequestTargetsEntitlementsWithBothHeaders() {
        let req = ProEntitlementClient.entitlementRequest(accessToken: "tok-123")
        let url = req.url!.absoluteString
        XCTAssertTrue(url.contains("/rest/v1/entitlements"), "wrong table: \(url)")
        XCTAssertTrue(url.contains("product=eq.pro"), "missing product filter: \(url)")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        // Without the apikey header the query runs as anon and returns
        // nothing; without Bearer it 401s. Both must be present.
        XCTAssertEqual(req.value(forHTTPHeaderField: "apikey"), SupabaseAuthClient.anonKey)
        XCTAssertFalse(
            SupabaseAuthClient.anonKey.contains("placeholder"),
            "the real publishable key must be wired for sign-in to work at all"
        )
    }

    // MARK: - Parsing

    func testNoRowMeansNotEntitled() throws {
        XCTAssertFalse(try ProEntitlementClient.parseIsPro(Data("[]".utf8)))
    }

    func testActiveRowMeansEntitled() throws {
        XCTAssertTrue(try ProEntitlementClient.parseIsPro(Data(#"[{"active":true}]"#.utf8)))
    }

    /// A revoked entitlement keeps its row with active=false — that must not
    /// read as entitled.
    func testInactiveRowMeansNotEntitled() throws {
        XCTAssertFalse(try ProEntitlementClient.parseIsPro(Data(#"[{"active":false}]"#.utf8)))
    }

    func testMalformedBodyThrows() {
        XCTAssertThrowsError(try ProEntitlementClient.parseIsPro(Data("not json".utf8)))
        XCTAssertThrowsError(try ProEntitlementClient.parseIsPro(Data(#"{"active":true}"#.utf8)))
    }

    // MARK: - Resolve policy

    func testResolveMatrix() {
        // Server answer always wins.
        XCTAssertTrue(EntitlementStore.resolve(fetched: true, cached: false))
        XCTAssertFalse(EntitlementStore.resolve(fetched: false, cached: true))
        // No server answer → cache.
        XCTAssertTrue(EntitlementStore.resolve(fetched: nil, cached: true))
        XCTAssertFalse(EntitlementStore.resolve(fetched: nil, cached: false))
        // Nothing known → not entitled.
        XCTAssertFalse(EntitlementStore.resolve(fetched: nil, cached: nil))
    }

    // MARK: - Store

    @MainActor
    func testSuccessfulRefreshSetsAndCaches() async {
        let store = EntitlementStore(defaults: defaults, fetcher: { _ in true })
        await store.refresh(session: session())
        XCTAssertTrue(store.isPro)
        XCTAssertEqual(store.cachedAnswer(userID: "user-1"), true)
    }

    @MainActor
    func testRefreshUsesInjectedAuthenticatedSessionBeforeBearerFetch() async {
        let fresh = session()
        var fetchedAccessToken: String?
        let store = EntitlementStore(defaults: defaults, fetcher: { session in
            fetchedAccessToken = session.accessToken
            return true
        })
        let stale = SupabaseAuthClient.Session(
            accessToken: "expired", refreshToken: "refresh-abc",
            expiresAt: Date().addingTimeInterval(-1), userID: "user-1", email: nil
        )

        await store.refresh(session: stale, authenticatedSession: { fresh })
        XCTAssertEqual(fetchedAccessToken, fresh.accessToken)
    }

    @MainActor
    func testUnavailablePreflightKeepsExistingCacheResolution() async {
        defaults.set(true, forKey: "murmur.pro.entitlement.user-1")
        let store = EntitlementStore(defaults: defaults, fetcher: { _ in
            XCTFail("expired token must not reach the bearer fetch")
            return false
        })
        await store.refresh(session: session(), authenticatedSession: { nil })
        XCTAssertTrue(store.isPro)

        defaults.removeObject(forKey: "murmur.pro.entitlement.user-1")
        await store.refresh(session: session(), authenticatedSession: { nil })
        XCTAssertFalse(store.isPro)
    }

    /// The offline path: paid user, server unreachable → cache keeps Pro on.
    @MainActor
    func testFetchFailureFallsBackToCache() async {
        let store = EntitlementStore(defaults: defaults, fetcher: { _ in true })
        await store.refresh(session: session())
        XCTAssertTrue(store.isPro)

        store.fetcher = { _ in throw ProEntitlementClient.EntitlementError.badResponse(-1) }
        await store.refresh(session: session())
        XCTAssertTrue(store.isPro, "offline must not revoke a cached entitlement")
    }

    /// A free user offline has no true in their cache and cannot gain one.
    @MainActor
    func testFetchFailureWithoutCacheMeansNotEntitled() async {
        let store = EntitlementStore(
            defaults: defaults,
            fetcher: { _ in throw ProEntitlementClient.EntitlementError.badResponse(-1) }
        )
        await store.refresh(session: session())
        XCTAssertFalse(store.isPro)
    }

    /// Server revocation beats a stale true in the cache, and updates it.
    @MainActor
    func testServerRevocationOverridesCache() async {
        let store = EntitlementStore(defaults: defaults, fetcher: { _ in true })
        await store.refresh(session: session())

        store.fetcher = { _ in false }
        await store.refresh(session: session())
        XCTAssertFalse(store.isPro)
        XCTAssertEqual(store.cachedAnswer(userID: "user-1"), false)
    }

    /// One user's cached entitlement must never leak to another account.
    @MainActor
    func testCacheIsPerUser() async {
        let store = EntitlementStore(defaults: defaults, fetcher: { _ in true })
        await store.refresh(session: session(userID: "payer"))
        XCTAssertTrue(store.isPro)

        store.fetcher = { _ in throw ProEntitlementClient.EntitlementError.badResponse(-1) }
        await store.refresh(session: session(userID: "someone-else"))
        XCTAssertFalse(store.isPro, "payer's cache must not entitle a different user")
    }

    @MainActor
    func testClearDropsEntitlementButKeepsCache() async {
        let store = EntitlementStore(defaults: defaults, fetcher: { _ in true })
        await store.refresh(session: session())
        store.clear()
        XCTAssertFalse(store.isPro)
        XCTAssertEqual(
            store.cachedAnswer(userID: "user-1"), true,
            "cache survives sign-out so an offline re-sign-in still works"
        )
    }

    @MainActor
    func testLateRefreshAfterClearCannotRestoreEntitlementOrCache() async {
        let gate = BoolGate()
        let store = EntitlementStore(defaults: defaults, fetcher: { _ in try await gate.fetch() })

        let refresh = Task { await store.refresh(session: self.session(userID: "payer")) }
        await gate.waitUntilStarted()
        store.clear()
        await gate.succeed(true)
        await refresh.value

        XCTAssertFalse(store.isPro)
        XCTAssertFalse(store.isRefreshing)
        XCTAssertNil(store.cachedAnswer(userID: "payer"))
    }

    @MainActor
    func testLateRefreshCannotWritePreviousUsersCache() async {
        let gate = BoolGate()
        let store = EntitlementStore(defaults: defaults, fetcher: { session in
            if session.userID == "payer" { return try await gate.fetch() }
            return false
        })

        let oldRefresh = Task { await store.refresh(session: self.session(userID: "payer")) }
        await gate.waitUntilStarted()
        await store.refresh(session: session(userID: "new-user"))
        await gate.succeed(true)
        await oldRefresh.value

        XCTAssertFalse(store.isPro)
        XCTAssertNil(store.cachedAnswer(userID: "payer"))
        XCTAssertEqual(store.cachedAnswer(userID: "new-user"), false)
    }

    // MARK: - Sidebar and pro marking

    /// The locked tab is deliberately visible to free users — the teaser IS
    /// the ad. If this regresses to a hidden tab, free users stop seeing what
    /// Pro offers; if the pro flag regresses, the content gate in RootView
    /// stops swapping in the teaser.
    func testClipboardIsAlwaysListedAndMarkedPro() {
        XCTAssertEqual(RootTab.mainTabs.last, .clipboard)
        XCTAssertEqual(RootTab.mainTabs.count, 8)
        XCTAssertTrue(RootTab.clipboard.isProFeature)
    }

    func testOnlyClipboardIsMarkedPro() {
        let pro = RootTab.allCases.filter(\.isProFeature)
        XCTAssertEqual(pro, [.clipboard])
    }

    /// Settings lives outside mainTabs (pinned row).
    func testSettingsIsNeverInMainTabs() {
        XCTAssertFalse(RootTab.mainTabs.contains(.settings))
    }
}
