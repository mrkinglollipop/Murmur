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

    enum State: Equatable {
        case signedOut
        case waitingForBrowser(provider: SupabaseAuthClient.Provider, startedAt: Date)
        case exchanging
        case signedIn(SupabaseAuthClient.Session)
        case failed(String)
    }

    @Published private(set) var state: State = .signedOut

    /// Refresh token survives relaunches in the same Keychain service as the
    /// BYO API keys (legacy login keychain — see KeychainStore's warning
    /// about the Data Protection store before "improving" this).
    static let keychainAccount = "supabase-refresh-token"
    private let readStoredToken: () -> String?
    private let writeStoredToken: (String) -> Void
    private let deleteStoredToken: () -> Void
    private let exchangeCode: (String, String) async throws -> SupabaseAuthClient.Session
    private let refreshToken: (String) async throws -> SupabaseAuthClient.Session
    private let openBrowser: (URL) -> Void
    /// Cancellation does not guarantee a URLSession completion cannot arrive.
    private var sessionGeneration = 0
    private var pendingVerifier: String?
    /// Loopback listener for the browser redirect; nil while not signing in
    /// or when every allow-listed port was taken (deep-link fallback).
    private var loopbackServer: LoopbackRedirectServer?

    static let browserTimeout: TimeInterval = 300

    init(
        keychain: KeychainStore = KeychainStore(),
        exchangeCode: @escaping (String, String) async throws -> SupabaseAuthClient.Session = SupabaseAuthClient.exchangeCode,
        refreshToken: @escaping (String) async throws -> SupabaseAuthClient.Session = SupabaseAuthClient.refresh,
        openBrowser: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
        readStoredToken: (() -> String?)? = nil,
        writeStoredToken: ((String) -> Void)? = nil,
        deleteStoredToken: (() -> Void)? = nil
    ) {
        self.readStoredToken = readStoredToken ?? { keychain.key(for: Self.keychainAccount) }
        self.writeStoredToken = writeStoredToken ?? { value in
            _ = keychain.setKey(value, for: Self.keychainAccount)
        }
        self.deleteStoredToken = deleteStoredToken ?? { keychain.deleteKey(for: Self.keychainAccount) }
        self.exchangeCode = exchangeCode
        self.refreshToken = refreshToken
        self.openBrowser = openBrowser
    }

    // MARK: - Pure seams

    /// A callback is only actionable while we are waiting for one; stray or
    /// replayed deep links in any other state are dropped.
    nonisolated static func shouldHandleCallback(state: State) -> Bool {
        if case .waitingForBrowser = state { return true }
        return false
    }

    /// Waiting-state expiry check — the sheet polls this on a timer.
    nonisolated static func waitingHasExpired(state: State, now: Date) -> Bool {
        guard case .waitingForBrowser(_, let startedAt) = state else { return false }
        return now.timeIntervalSince(startedAt) > browserTimeout
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
        sessionGeneration &+= 1
        let generation = sessionGeneration
        let verifier = SupabaseAuthClient.makeCodeVerifier()
        pendingVerifier = verifier
        state = .waitingForBrowser(provider: provider, startedAt: Date())

        // Prefer a loopback redirect so the browser tab gets a real
        // "you can close this tab" page instead of spinning on murmur://.
        stopLoopbackServer()
        startLoopbackServer(generation: generation)
        let redirect = loopbackServer?.redirectURI ?? SupabaseAuthClient.redirectURI

        let url = SupabaseAuthClient.authorizeURL(provider: provider, verifier: verifier, redirectTo: redirect)
        vlog("auth: opening browser for \(provider.rawValue) sign-in (redirect: \(loopbackServer == nil ? "deep link" : "loopback"))")
        openBrowser(url)
    }

    func cancelSignIn() {
        sessionGeneration &+= 1
        stopLoopbackServer()
        pendingVerifier = nil
        state = .signedOut
    }

    func expireIfTimedOut(now: Date = Date()) {
        if Self.waitingHasExpired(state: state, now: now) {
            sessionGeneration &+= 1
            stopLoopbackServer()
            pendingVerifier = nil
            state = .failed("That took too long — try again.")
        }
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
            // A provider error on an unbound redirect cannot be attributed to
            // this browser attempt. Preserve the listener and bounded wait.
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
            // With fixed Supabase redirect URLs there is no supported app
            // nonce to correlate an error-only callback. Treat it as stray
            // while the active browser still has time to finish.
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
            stopLoopbackServer()
            pendingVerifier = nil
            writeStoredToken(session.refreshToken)
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

    /// Relaunch path: a stored refresh token becomes a live session silently.
    func restoreSessionIfAvailable() async {
        // A browser flow owns the state once it has started. Do not let a
        // launch-time restore race it, but let repeated restores supersede
        // one another so an older rotated token cannot win.
        guard case .signedOut = state else { return }
        guard let token = readStoredToken() else { return }
        sessionGeneration &+= 1
        let generation = sessionGeneration
        do {
            let session = try await refreshToken(token)
            guard generation == sessionGeneration else { return }
            writeStoredToken(session.refreshToken)
            state = .signedIn(session)
            vlog("auth: session restored from stored refresh token")
        } catch {
            // Expired/revoked token: stay signed out quietly; the user
            // re-authenticates the next time they touch a Pro feature.
            vlog("auth: stored refresh token no longer valid")
        }
    }

    func signOut() {
        sessionGeneration &+= 1
        deleteStoredToken()
        stopLoopbackServer()
        pendingVerifier = nil
        state = .signedOut
    }

    nonisolated static func userMessage(for error: SupabaseAuthClient.AuthError) -> String {
        switch error {
        case .callbackCarriedError(let message): return message
        case .callbackMissingCode: return "The browser didn't finish sign-in — try again."
        case .badResponse, .malformedSession: return "Sign-in didn't complete — try again."
        }
    }
}
