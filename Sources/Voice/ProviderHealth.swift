import Foundation

// MARK: - Classification (plan 034)

/// Why a cloud request failed, as far as Murmur can tell. Only `billing` and
/// `auth` mean "retrying will not help until the user acts".
enum CloudFailureKind: String, Equatable {
    case billing
    case auth
    case rateLimited
    case transient

    /// The provider will keep refusing until the user fixes something.
    var isRefusal: Bool { self == .billing || self == .auth }
}

enum CloudFailureClassifier {
    /// Body fragments that mean "money or plan", not "bad key". Lowercased match
    /// on the raw body. ElevenLabs sends `payment_issue` / `payment_required`
    /// (HTTP 401) and `quota_exceeded`.
    private static let billingKeywords = [
        "payment", "subscription", "quota", "billing",
        "insufficient_funds", "insufficient funds", "insufficient credit", "out of credit",
    ]

    /// `status` is the HTTP status when there was one; `body` the raw response
    /// body when available. Pure: no logging, nothing retained.
    static func classify(status: Int?, body: String?) -> CloudFailureKind {
        guard let status else { return .transient }
        if status == 429 { return .rateLimited }
        if status == 402 { return .billing }
        guard status == 401 || status == 403 else { return .transient }
        // A 403 from an edge proxy (xAI sits behind a bot challenge) is an HTML
        // page, not the provider's API refusing the key: retry as normal.
        if status == 403, let lowered = body?.lowercased(),
           ["<html", "<!doctype", "cloudflare", "challenge"].contains(where: { lowered.contains($0) }) {
            return .transient
        }
        if let lowered = body?.lowercased(),
           billingKeywords.contains(where: { lowered.contains($0) }) {
            return .billing
        }
        return .auth
    }

    /// Kind for any thrown error; non-cloud errors (URLError, decoding) are transient.
    static func kind(of error: Error) -> CloudFailureKind {
        (error as? CloudTranscriptionError)?.kind ?? .transient
    }
}

// MARK: - Notice

/// What the user sees while a provider is refusing (HUD, menu bar, Settings).
struct ProviderNotice: Equatable {
    let provider: CloudProvider
    let kind: CloudFailureKind
    let lastRejection: Date

    var reason: String {
        switch kind {
        case .billing:     return "payment needed"
        case .auth:        return "key rejected"
        case .rateLimited: return "rate limited"
        case .transient:   return ""
        }
    }

    /// HUD first line, e.g. "ElevenLabs: payment needed".
    var title: String { "\(provider.shortName): \(reason)" }
    /// HUD second line.
    var subtitle: String { "Using on-device · may be slower" }
    var hudAccessibilityLabel: String { "\(title). \(subtitle)" }

    /// Menu-bar item text; `nil` for rate limiting (a 60 s pause, not an outage).
    var menuTitle: String? {
        switch kind {
        case .billing: return "\(title) — Open billing…"
        case .auth:    return "\(title) — Open key page…"
        default:       return nil
        }
    }

    /// Where the user goes to fix it.
    var remedyURL: URL { kind == .billing ? provider.billingURL : provider.signupURL }

    /// Settings line, e.g. "Rejected 8:43 PM: payment needed. Dictation is using on-device."
    func settingsLine(timeFormatter: (Date) -> String = ProviderNotice.shortTime) -> String {
        "Rejected \(timeFormatter(lastRejection)): \(reason). Dictation is using on-device."
    }

    static func shortTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Health store

extension Notification.Name {
    /// Posted on the main queue whenever a provider's health state changes.
    static let providerHealthDidChange = Notification.Name("ProviderHealthDidChange")
}

/// In-memory per-provider health. Never persisted (a relaunch retries), never
/// holds a key or transcript. Thread-safe: written from the pipeline, the
/// streaming coordinator and Settings; read from main for UI.
final class ProviderHealthStore {
    static let shared = ProviderHealthStore()

    /// A refusing provider is retried on the first hold at least this long after
    /// its last rejection.
    static let retryWindow: TimeInterval = 5 * 60
    /// A 429 pauses that provider for this long.
    static let rateLimitPause: TimeInterval = 60

    enum State: Equatable {
        case ok
        case refusing(kind: CloudFailureKind, since: Date, provisional: Bool)
        case rateLimited(until: Date)
    }

    private struct Record {
        var state: State = .ok
        var lastRejection: Date?
    }

    private let lock = NSLock()
    private var records: [CloudProvider: Record] = [:]
    /// Last 2xx per provider, kept across clears so a handshake verdict that
    /// arrives after the same attempt already succeeded can be ignored.
    private var lastSuccess: [CloudProvider: Date] = [:]
    private let now: () -> Date
    private let postsNotifications: Bool

    init(now: @escaping () -> Date = Date.init, postsNotifications: Bool = true) {
        self.now = now
        self.postsNotifications = postsNotifications
    }

    // MARK: Reads

    func state(for provider: CloudProvider) -> State {
        lock.lock(); defer { lock.unlock() }
        return records[provider]?.state ?? .ok
    }

    /// May a realtime stream be opened for this provider on this hold?
    func allowsStream(for provider: CloudProvider) -> Bool {
        allows(provider, batch: false)
    }

    /// May a batch request be sent? A provisional refusal (handshake status
    /// only) still lets one batch through so the body can confirm or clear it.
    func allowsBatch(for provider: CloudProvider) -> Bool {
        allows(provider, batch: true)
    }

    private func allows(_ provider: CloudProvider, batch: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let record = records[provider] else { return true }
        let current = now()
        switch record.state {
        case .ok:
            return true
        case .rateLimited(let until):
            return current >= until
        case .refusing(_, _, let provisional):
            if batch && provisional { return true }
            guard let last = record.lastRejection else { return true }
            return current.timeIntervalSince(last) >= Self.retryWindow
        }
    }

    /// The notice to show for `provider` right now, or `nil` when healthy.
    func notice(for provider: CloudProvider) -> ProviderNotice? {
        lock.lock(); defer { lock.unlock() }
        guard let record = records[provider] else { return nil }
        switch record.state {
        case .ok:
            return nil
        case .refusing(let kind, _, _):
            return ProviderNotice(provider: provider, kind: kind, lastRejection: record.lastRejection ?? now())
        case .rateLimited(let until):
            guard now() < until else { return nil }
            return ProviderNotice(provider: provider, kind: .rateLimited, lastRejection: record.lastRejection ?? now())
        }
    }

    // MARK: Writes

    /// The store's clock, for callers that stamp an attempt's start.
    func timestamp() -> Date { now() }

    /// Records a failed cloud request. `.transient` changes nothing. A
    /// provisional (handshake-only) verdict is dropped when the provider has
    /// succeeded since `attemptStartedAt`: the stream's start can fail after
    /// the same hold already went through on batch.
    func recordFailure(_ provider: CloudProvider, kind: CloudFailureKind, provisional: Bool = false,
                       attemptStartedAt: Date? = nil) {
        guard kind != .transient else { return }
        let current = now()
        lock.lock()
        if provisional, let started = attemptStartedAt,
           let success = lastSuccess[provider], success >= started {
            lock.unlock()
            return
        }
        var record = records[provider] ?? Record()
        let before = record.state
        switch kind {
        case .rateLimited:
            record.state = .rateLimited(until: current.addingTimeInterval(Self.rateLimitPause))
            record.lastRejection = current
        case .billing, .auth:
            record.lastRejection = current
            if case .refusing(let oldKind, let since, let oldProvisional) = before {
                if provisional {
                    // A handshake status never overrides or downgrades a verdict.
                    record.state = .refusing(kind: oldKind, since: since, provisional: oldProvisional)
                } else {
                    record.state = .refusing(kind: kind, since: since, provisional: false)
                }
            } else {
                record.state = .refusing(kind: kind, since: current, provisional: provisional)
            }
        case .transient:
            break
        }
        records[provider] = record
        let changed = record.state != before
        lock.unlock()
        if changed { postChange(provider) }
    }

    /// Convenience for catch blocks: classifies `error` for `provider`.
    func recordFailure(_ provider: CloudProvider, error: Error, attemptStartedAt: Date? = nil) {
        let cloud = error as? CloudTranscriptionError
        recordFailure(provider, kind: CloudFailureClassifier.kind(of: error),
                      provisional: cloud?.isProvisional ?? false, attemptStartedAt: attemptStartedAt)
    }

    /// A request succeeded (a response with HTTP 2xx, text or not).
    func recordSuccess(_ provider: CloudProvider) {
        let current = now()
        lock.lock()
        lastSuccess[provider] = current
        lock.unlock()
        clear(provider)
    }

    /// The user saved a key for this provider: forget any refusal and retry.
    func keySaved(for provider: CloudProvider) { clear(provider) }

    private func clear(_ provider: CloudProvider) {
        lock.lock()
        let had = records[provider] != nil
        records[provider] = nil
        lock.unlock()
        if had { postChange(provider) }
    }

    private func postChange(_ provider: CloudProvider) {
        guard postsNotifications else { return }
        let object = self
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .providerHealthDidChange, object: object,
                                            userInfo: ["provider": provider.rawValue])
        }
    }
}
