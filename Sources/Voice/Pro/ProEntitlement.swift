// PRO ONLY — this file is part of the paid feature set and must never merge
// into `main`. See the "Clipboard manager" section of CLAUDE.md.

import Foundation
import os.log

/// Reads the signed-in user's Pro entitlement from the `entitlements` table.
///
/// The table is server-authoritative: row-level security lets a user SELECT
/// only their own row, and no client key can INSERT or UPDATE — entitlements
/// are written exclusively by the service role when a purchase (or Matt)
/// grants them. The app only ever asks "is my row active?".
enum ProEntitlementClient {

    /// GET /rest/v1/entitlements?select=active&product=eq.pro
    ///
    /// Both headers are required: `apikey` identifies the app, and the Bearer
    /// token scopes RLS to the signed-in user. With only the apikey the query
    /// would run as `anon` and always return zero rows.
    static func entitlementRequest(accessToken: String) -> URLRequest {
        var components = URLComponents(
            url: SupabaseAuthClient.projectURL.appendingPathComponent("rest/v1/entitlements"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "select", value: "active"),
            URLQueryItem(name: "product", value: "eq.pro")
        ]
        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        req.setValue(SupabaseAuthClient.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return req
    }

    enum EntitlementError: Error, Equatable {
        case badResponse(Int)
        case malformedBody
    }

    /// `[]` (no row) is a valid answer meaning "not entitled" — most users
    /// never have a row at all. Only a shape that isn't a JSON array of
    /// objects is an error.
    static func parseIsPro(_ data: Data) throws -> Bool {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw EntitlementError.malformedBody
        }
        return rows.contains { ($0["active"] as? Bool) == true }
    }

    static func fetchIsPro(session: SupabaseAuthClient.Session) async throws -> Bool {
        let (data, response) = try await URLSession.shared.data(
            for: entitlementRequest(accessToken: session.accessToken)
        )
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EntitlementError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try parseIsPro(data)
    }
}

/// Main-thread owner of the "is this user Pro" answer, with an offline cache.
///
/// Policy, in order:
/// - Signed out → `false`, always.
/// - Signed in, server reachable → the server's answer, which is also cached
///   per user.
/// - Signed in, server unreachable → the cached answer for THAT user. A paid
///   user on a plane keeps their features; a free user can't gain them
///   offline because their cache never held `true`.
@MainActor
final class EntitlementStore: ObservableObject {

    @Published private(set) var isPro = false

    /// True while a refresh is running — lets the Settings UI show a spinner
    /// instead of flashing "Free" before the first answer lands.
    @Published private(set) var isRefreshing = false

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "entitlement")
    /// A sign-out or newer user refresh invalidates late server replies.
    private var refreshGeneration = 0

    /// Injectable for tests; production default hits Supabase.
    var fetcher: (SupabaseAuthClient.Session) async throws -> Bool

    init(
        defaults: UserDefaults = .standard,
        fetcher: @escaping (SupabaseAuthClient.Session) async throws -> Bool = ProEntitlementClient.fetchIsPro
    ) {
        self.defaults = defaults
        self.fetcher = fetcher
    }

    private static func cacheKey(userID: String) -> String {
        "murmur.pro.entitlement.\(userID)"
    }

    /// The last server-confirmed answer for `userID`, or nil if never fetched.
    func cachedAnswer(userID: String) -> Bool? {
        defaults.object(forKey: Self.cacheKey(userID: userID)) as? Bool
    }

    /// Pure decision seam: server answer wins; otherwise the user's cache;
    /// otherwise not entitled.
    nonisolated static func resolve(fetched: Bool?, cached: Bool?) -> Bool {
        fetched ?? cached ?? false
    }

    func refresh(session: SupabaseAuthClient.Session) async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isRefreshing = true

        var fetched: Bool?
        do {
            fetched = try await fetcher(session)
        } catch {
            logger.error("entitlement fetch failed, using cache: \(error.localizedDescription)")
        }
        guard generation == refreshGeneration else { return }
        if let fetched {
            defaults.set(fetched, forKey: Self.cacheKey(userID: session.userID))
        }
        isPro = Self.resolve(fetched: fetched, cached: cachedAnswer(userID: session.userID))
        isRefreshing = false
    }

    /// Sign-out. The per-user cache is kept — it only ever answers for the
    /// same userID after a fresh sign-in, and dropping it would strand a paid
    /// user who signs back in while offline.
    func clear() {
        refreshGeneration &+= 1
        isPro = false
        isRefreshing = false
    }
}

extension RootTab {
    /// Pro-only tabs carry a "Pro" chip in the sidebar and, for free users,
    /// show a locked teaser instead of the feature (Matt, 2026-08-24: locked
    /// features stay visible "so people can see what they're missing").
    /// The hard gates are at the content layer (RootView swaps in the teaser)
    /// and the capture layer (AppDelegate never starts the watcher un-Pro).
    var isProFeature: Bool { self == .clipboard }

    /// The sidebar's main section — identical for free and Pro on purpose.
    static let mainTabs: [RootTab] = [
        .history, .insights, .dictionary, .snippets, .style, .transforms, .scratchpad, .clipboard
    ]
}
