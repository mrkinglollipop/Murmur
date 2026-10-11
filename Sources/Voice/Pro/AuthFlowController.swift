import AppKit
import Foundation

/// Owns the browser round trip: opens the authorize URL, waits for the
/// `murmur://auth-callback` deep link, exchanges the code, persists the
/// session's refresh token. One instance lives on the AppDelegate; the deep
/// link handler routes every auth callback here.
///
/// The waiting state times out after the auth code's own lifetime (5 minutes)
/// so the sheet can fall back to its buttons instead of spinning forever —
/// mirror of the approved mock's behaviour.
@MainActor
final class AuthFlowController: ObservableObject {

    private final class RefreshAttempt {
        let generation: Int
        let task: Task<SupabaseAuthClient.Session?, Never>

        init(generation: Int, task: Task<SupabaseAuthClient.Session?, Never>) {
            self.generation = generation
            self.task = task
        }
    }

    enum State: Equatable {
        case signedOut
        case waitingForBrowser(provider: SupabaseAuthClient.Provider, startedAt: Date)
        case exchanging
        case signedIn(SupabaseAuthClient.Session)
        case failed(String)
    }

    @Published private(set) var state: State = .signedOut
    /// A non-terminal error preserves an existing signed-in session, so the
    /// caller can retry rather than being unexpectedly signed out offline.
    @Published private(set) var lastError: String?

    /// Refresh token survives relaunches in the same Keychain service as the
    /// BYO API keys (legacy login keychain — see KeychainStore's warning
    /// about the Data Protection store before "improving" this).
    static let keychainAccount = "supabase-refresh-token"
    private let readStoredToken: () throws -> String?
    private let writeStoredToken: (String) -> Bool
    private let deleteStoredToken: () -> Bool
    private let exchangeCode: (String, String) async throws -> SupabaseAuthClient.Session
    private let refreshToken: (String) async throws -> SupabaseAuthClient.Session
    private let openBrowser: (URL) -> Void
    /// Cancellation does not guarantee a URLSession completion cannot arrive.
    private var sessionGeneration = 0
    private var pendingVerifier: String?
    /// Loopback listener for the browser redirect; nil while not signing in
    /// or when every allow-listed port was taken (deep-link fallback).
    private var loopbackServer: LoopbackRedirectServer?
    private var browserTimeoutTask: Task<Void, Never>?
    private var inFlightRefresh: RefreshAttempt?
    private var nextRefreshGeneration = 0
    private var pendingStoredToken: String?
    private var shouldRetryRestore = false
    private let browserTimeoutInterval: TimeInterval
    private let waitForBrowserTimeout: () async -> Void

    static let browserTimeout: TimeInterval = 300

    init(
        keychain: KeychainStore = KeychainStore(),
        exchangeCode: @escaping (String, String) async throws -> SupabaseAuthClient.Session = SupabaseAuthClient.exchangeCode,
        refreshToken: @escaping (String) async throws -> SupabaseAuthClient.Session = SupabaseAuthClient.refresh,
        openBrowser: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
        readStoredToken: (() throws -> String?)? = nil,
        writeStoredToken: ((String) -> Void)? = nil,
        deleteStoredToken: (() -> Void)? = nil,
        persistStoredToken: ((String) -> Bool)? = nil,
        removeStoredToken: (() -> Bool)? = nil,
        browserTimeout: TimeInterval = AuthFlowController.browserTimeout,
        waitForBrowserTimeout: (() async -> Void)? = nil
    ) {
        self.readStoredToken = readStoredToken ?? { try keychain.readKey(for: Self.keychainAccount) }
        self.writeStoredToken = persistStoredToken ?? { value in
            if let writeStoredToken {
                writeStoredToken(value)
                return true
            }
            return keychain.setKey(value, for: Self.keychainAccount)
        }
        self.deleteStoredToken = removeStoredToken ?? {
            if let deleteStoredToken {
                deleteStoredToken()
                return true
            }
            keychain.deleteKey(for: Self.keychainAccount)
            do {
                return try keychain.readKey(for: Self.keychainAccount) == nil
            } catch {
                return false
            }
        }
        self.exchangeCode = exchangeCode
        self.refreshToken = refreshToken
        self.openBrowser = openBrowser
        self.browserTimeoutInterval = browserTimeout
        if let waitForBrowserTimeout {
            self.waitForBrowserTimeout = waitForBrowserTimeout
        } else {
            let timeoutNanoseconds = UInt64(browserTimeout * 1_000_000_000)
            self.waitForBrowserTimeout = {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            }
        }
    }

    // MARK: - Pure seams

    /// A callback is only actionable while we are waiting for one; stray or
    /// replayed deep links in any other state are dropped.
    nonisolated static func shouldHandleCallback(state: State) -> Bool {
        if case .waitingForBrowser = state { return true }
        return false
    }

    /// Waiting-state expiry check, owned and scheduled by the controller.
    nonisolated static func waitingHasExpired(
        state: State,
        now: Date,
        timeout: TimeInterval = browserTimeout
    ) -> Bool {
        guard case .waitingForBrowser(_, let startedAt) = state else { return false }
        return now.timeIntervalSince(startedAt) > timeout
    }

    /// A loopback listener belongs to one browser attempt. A stopped listener
    /// can still deliver a buffered callback after a newer attempt starts.
    nonisolated static func shouldHandleLoopbackCallback(
        generation: Int,
        currentGeneration: Int,
        state: State
    ) -> Bool {
        generation == currentGeneration && shouldHandleCallback(state: state)
    }

    // MARK: - Flow

    func beginSignIn(provider: SupabaseAuthClient.Provider) {
        shouldRetryRestore = false
        pendingStoredToken = nil
        sessionGeneration &+= 1
        let generation = sessionGeneration
        let verifier = SupabaseAuthClient.makeCodeVerifier()
        pendingVerifier = verifier
        state = .waitingForBrowser(provider: provider, startedAt: Date())
        lastError = nil

        // Prefer a loopback redirect so the browser tab gets a real
        // "you can close this tab" page instead of spinning on murmur://.
        stopLoopbackServer()
        startLoopbackServer(generation: generation)
        scheduleBrowserTimeout(generation: generation)
        let redirect = loopbackServer?.redirectURI ?? SupabaseAuthClient.redirectURI

        let url = SupabaseAuthClient.authorizeURL(provider: provider, verifier: verifier, redirectTo: redirect)
        vlog("auth: opening browser for \(provider.rawValue) sign-in (redirect: \(loopbackServer == nil ? "deep link" : "loopback"))")
        openBrowser(url)
    }

    func cancelSignIn() {
        shouldRetryRestore = false
        sessionGeneration &+= 1
        endBrowserAttempt()
        state = .signedOut
        lastError = nil
    }

    func expireIfTimedOut(now: Date = Date()) {
        if Self.waitingHasExpired(state: state, now: now, timeout: browserTimeoutInterval) {
            sessionGeneration &+= 1
            endBrowserAttempt()
            state = .failed("That took too long — try again.")
        }
    }

    private func scheduleBrowserTimeout(generation: Int) {
        browserTimeoutTask?.cancel()
        browserTimeoutTask = Task { [weak self] in
            await self?.waitForBrowserTimeout()
            guard !Task.isCancelled, let self, generation == self.sessionGeneration else { return }
            self.expireIfTimedOut()
        }
    }

    private func endBrowserAttempt() {
        browserTimeoutTask?.cancel()
        browserTimeoutTask = nil
        stopLoopbackServer()
        pendingVerifier = nil
    }

    private func stopLoopbackServer() {
        loopbackServer?.stop()
        loopbackServer = nil
    }

    private func startLoopbackServer(generation: Int) {
        stopLoopbackServer()
        loopbackServer = LoopbackRedirectServer.start { [weak self] result in
            Task { @MainActor in self?.handleLoopbackResult(result, generation: generation) }
        }
    }

    /// Loopback twin of `handleCallback` — the code arrived over the local
    /// HTTP listener instead of the deep link.
    private func handleLoopbackResult(
        _ result: Result<String, SupabaseAuthClient.AuthError>,
        generation: Int
    ) {
        guard Self.shouldHandleLoopbackCallback(
            generation: generation,
            currentGeneration: sessionGeneration,
            state: state
        ), let verifier = pendingVerifier else {
            vlog("auth: dropping stray loopback callback (state not waiting)")
            return
        }
        switch result {
        case .failure:
            // Error-only callbacks have no app nonce to associate them with
            // this browser attempt. Keep the listener and timeout alive so a
            // still-open provider page can send the current code.
            vlog("auth: ignoring unbound loopback callback error")
        case .success(let code):
            submitExchange(code: code, verifier: verifier, generation: generation)
        }
    }

    /// Deep-link entry point (AppDelegate). Returns true when the URL was an
    /// auth callback this controller consumed.
    @discardableResult
    func handleCallback(_ url: URL) -> Bool {
        guard SupabaseAuthClient.isAuthCallback(url) else { return false }
        guard Self.shouldHandleCallback(state: state), let verifier = pendingVerifier else {
            vlog("auth: dropping stray callback (state not waiting)")
            return true
        }
        switch SupabaseAuthClient.parseCallback(url) {
        case .failure:
            // As above, a provider error cannot be safely correlated to this
            // attempt with the fixed redirect configuration.
            vlog("auth: ignoring unbound callback error")
        case .success(let code):
            submitExchange(code: code, verifier: verifier, generation: sessionGeneration)
        }
        return true
    }

    private func submitExchange(
        code: String,
        verifier: String,
        generation: Int
    ) {
        Task { [weak self] in
            await self?.exchange(
                code: code,
                verifier: verifier,
                generation: generation
            )
        }
    }

    private func exchange(
        code: String,
        verifier: String,
        generation: Int
    ) async {
        do {
            let session = try await exchangeCode(code, verifier)
            // First valid exchange wins. Subsequent successes/failures arrive
            // after state has left waiting and cannot change this session.
            guard generation == sessionGeneration,
                  Self.shouldHandleCallback(state: state),
                  pendingVerifier != nil else { return }
            endBrowserAttempt()
            guard writeStoredToken(session.refreshToken) else {
                state = .failed("Murmur couldn't save your sign-in. Try again.")
                return
            }
            state = .signedIn(session)
        } catch {
            guard generation == sessionGeneration,
                  Self.shouldHandleCallback(state: state),
                  pendingVerifier != nil else { return }
            // Supabase's current client reports both invalid PKCE codes and
            // transport/server errors as `badResponse`. Keep this browser
            // attempt and its original loopback port alive until timeout
            // instead of letting an old rejected code consume the verifier.
        }
    }

    /// Returns a token that is safe for an authenticated request. Calls within
    /// the refresh margin share one refresh task, so a foreground event and an
    /// auth-state observer cannot rotate the refresh token independently.
    func authenticatedSession() async -> SupabaseAuthClient.Session? {
        guard case .signedIn(let session) = state else { return nil }
        if pendingStoredToken == session.refreshToken {
            persistRenewedToken(session.refreshToken)
        }
        guard session.expiresAt.timeIntervalSinceNow <= Self.refreshMargin else { return session }

        let attempt: RefreshAttempt
        if let inFlightRefresh {
            attempt = inFlightRefresh
        } else {
            nextRefreshGeneration &+= 1
            let generation = nextRefreshGeneration
            let sourceGeneration = sessionGeneration
            let token = session.refreshToken
            let task = Task { [weak self, refreshToken] in
                do {
                    let refreshed = try await refreshToken(token)
                    return self?.finishRefresh(
                        .success(refreshed),
                        generation: generation,
                        sourceGeneration: sourceGeneration,
                        sourceToken: token
                    )
                } catch {
                    return self?.finishRefresh(
                        .failure(error),
                        generation: generation,
                        sourceGeneration: sourceGeneration,
                        sourceToken: token
                    )
                }
            }
            attempt = RefreshAttempt(generation: generation, task: task)
            inFlightRefresh = attempt
        }
        return await attempt.task.value
    }

    /// Foreground preflight shared with AppDelegate's entitlement refresh.
    func sessionForForegroundActivation() async -> SupabaseAuthClient.Session? {
        if shouldRetryRestore { await restoreSessionIfAvailable() }
        guard case .signedIn(let session) = state else { return nil }
        return session
    }

    static let refreshMargin: TimeInterval = 60

    private func finishRefresh(
        _ result: Result<SupabaseAuthClient.Session, Error>,
        generation: Int,
        sourceGeneration: Int,
        sourceToken: String
    ) -> SupabaseAuthClient.Session? {
        defer {
            if inFlightRefresh?.generation == generation { inFlightRefresh = nil }
        }
        guard inFlightRefresh?.generation == generation,
              sessionGeneration == sourceGeneration,
              case .signedIn(let current) = state,
              current.refreshToken == sourceToken else { return nil }
        switch result {
        case .success(let refreshed):
            state = .signedIn(refreshed)
            persistRenewedToken(refreshed.refreshToken)
            return refreshed
        case .failure(let error as SupabaseAuthClient.AuthError) where error == .invalidRefreshToken:
            endSessionAfterInvalidRefresh()
            return nil
        case .failure:
            lastError = "Murmur can't reach the server. Your sign-in is still available; try again shortly."
            return nil
        }
    }

    private func persistRenewedToken(_ token: String) {
        if writeStoredToken(token) {
            pendingStoredToken = nil
            lastError = nil
        } else {
            pendingStoredToken = token
            lastError = "Murmur couldn't save the renewed sign-in."
        }
    }

    private func endSessionAfterInvalidRefresh() {
        shouldRetryRestore = false
        pendingStoredToken = nil
        sessionGeneration &+= 1
        endBrowserAttempt()
        inFlightRefresh?.task.cancel()
        inFlightRefresh = nil
        let deleted = deleteStoredToken()
        state = .signedOut
        lastError = deleted
            ? "Your sign-in expired. Please sign in again."
            : "Your sign-in expired, but Murmur couldn't remove its saved sign-in."
    }

    /// Relaunch path: a stored refresh token becomes a live session silently.
    func restoreSessionIfAvailable() async {
        // A browser flow owns the state once it has started. Do not let a
        // launch-time restore race it, but let repeated restores supersede
        // one another so an older rotated token cannot win.
        guard case .signedOut = state else { return }
        shouldRetryRestore = false
        sessionGeneration &+= 1
        let generation = sessionGeneration
        do {
            guard let token = try readStoredToken() else { return }
            let session = try await refreshToken(token)
            guard generation == sessionGeneration else { return }
            state = .signedIn(session)
            persistRenewedToken(session.refreshToken)
            vlog("auth: session restored from stored refresh token")
        } catch let error as SupabaseAuthClient.AuthError where error == .invalidRefreshToken {
            guard generation == sessionGeneration else { return }
            endSessionAfterInvalidRefresh()
        } catch {
            guard generation == sessionGeneration else { return }
            shouldRetryRestore = true
            lastError = error is KeychainReadError
                ? "Murmur couldn't read your saved sign-in. It will be retried when the app becomes active."
                : "Murmur can't reach the server. Your saved sign-in will be retried when the app becomes active."
            vlog("auth: session restore temporarily unavailable")
        }
    }

    func signOut() {
        shouldRetryRestore = false
        sessionGeneration &+= 1
        endBrowserAttempt()
        inFlightRefresh?.task.cancel()
        inFlightRefresh = nil
        guard deleteStoredToken() else {
            lastError = "Murmur couldn't remove your saved sign-in."
            return
        }
        pendingStoredToken = nil
        state = .signedOut
        lastError = nil
    }

    nonisolated static func userMessage(for error: SupabaseAuthClient.AuthError) -> String {
        switch error {
        case .callbackCarriedError(let message): return message
        case .callbackMissingCode: return "The browser didn't finish sign-in — try again."
        case .invalidRefreshToken: return "Your sign-in expired. Please sign in again."
        case .badResponse, .malformedSession: return "Sign-in didn't complete — try again."
        }
    }
}
