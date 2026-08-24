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
    private let keychain: KeychainStore
    private var pendingVerifier: String?
    /// Loopback listener for the browser redirect; nil while not signing in
    /// or when every allow-listed port was taken (deep-link fallback).
    private var loopbackServer: LoopbackRedirectServer?

    static let browserTimeout: TimeInterval = 300

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
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

    // MARK: - Flow

    func beginSignIn(provider: SupabaseAuthClient.Provider) {
        let verifier = SupabaseAuthClient.makeCodeVerifier()
        pendingVerifier = verifier
        state = .waitingForBrowser(provider: provider, startedAt: Date())

        // Prefer a loopback redirect so the browser tab gets a real
        // "you can close this tab" page instead of spinning on murmur://.
        stopLoopbackServer()
        loopbackServer = LoopbackRedirectServer.start { [weak self] result in
            Task { @MainActor in self?.handleLoopbackResult(result) }
        }
        let redirect = loopbackServer?.redirectURI ?? SupabaseAuthClient.redirectURI

        let url = SupabaseAuthClient.authorizeURL(provider: provider, verifier: verifier, redirectTo: redirect)
        vlog("auth: opening browser for \(provider.rawValue) sign-in (redirect: \(loopbackServer == nil ? "deep link" : "loopback"))")
        NSWorkspace.shared.open(url)
    }

    func cancelSignIn() {
        stopLoopbackServer()
        pendingVerifier = nil
        state = .signedOut
    }

    func expireIfTimedOut(now: Date = Date()) {
        if Self.waitingHasExpired(state: state, now: now) {
            stopLoopbackServer()
            pendingVerifier = nil
            state = .failed("That took too long — try again.")
        }
    }

    private func stopLoopbackServer() {
        loopbackServer?.stop()
        loopbackServer = nil
    }

    /// Loopback twin of `handleCallback` — the code arrived over the local
    /// HTTP listener instead of the deep link.
    private func handleLoopbackResult(_ result: Result<String, SupabaseAuthClient.AuthError>) {
        stopLoopbackServer()
        guard Self.shouldHandleCallback(state: state), let verifier = pendingVerifier else {
            vlog("auth: dropping stray loopback callback (state not waiting)")
            return
        }
        pendingVerifier = nil
        switch result {
        case .failure(let err):
            vlog("auth: loopback callback carried error")
            state = .failed(Self.userMessage(for: err))
        case .success(let code):
            state = .exchanging
            Task { [weak self] in
                await self?.exchange(code: code, verifier: verifier)
            }
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
        pendingVerifier = nil
        switch SupabaseAuthClient.parseCallback(url) {
        case .failure(let err):
            vlog("auth: callback carried error")
            state = .failed(Self.userMessage(for: err))
        case .success(let code):
            state = .exchanging
            Task { [weak self] in
                await self?.exchange(code: code, verifier: verifier)
            }
        }
        return true
    }

    private func exchange(code: String, verifier: String) async {
        do {
            let session = try await SupabaseAuthClient.exchangeCode(code, verifier: verifier)
            keychain.setKey(session.refreshToken, for: Self.keychainAccount)
            state = .signedIn(session)
        } catch {
            state = .failed("Sign-in didn't complete — try again.")
        }
    }

    /// Relaunch path: a stored refresh token becomes a live session silently.
    func restoreSessionIfAvailable() async {
        guard let token = keychain.key(for: Self.keychainAccount) else { return }
        do {
            let session = try await SupabaseAuthClient.refresh(refreshToken: token)
            keychain.setKey(session.refreshToken, for: Self.keychainAccount)
            state = .signedIn(session)
            vlog("auth: session restored from stored refresh token")
        } catch {
            // Expired/revoked token: stay signed out quietly; the user
            // re-authenticates the next time they touch a Pro feature.
            vlog("auth: stored refresh token no longer valid")
        }
    }

    func signOut() {
        keychain.deleteKey(for: Self.keychainAccount)
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
