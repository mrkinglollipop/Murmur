import Foundation

/// App Group IPC between keyboard and containing app. The keyboard cannot record.
enum DictationHandoff {
    static let scheme = "murmur"
    static let leaseDuration: TimeInterval = 300

    struct Payload: Codable, Equatable {
        enum Status: String, Codable {
            case pending
            case recording
            case paused
            case transcribing
            case done
            case failed
            case cancelled
        }

        var id: String
        var status: Status
        var text: String
        var error: String
        var hostBundleID: String
        var hostPID: Int? = nil
    }

    struct Lease: Codable, Equatable {
        var sessionID: String
        var hostBundleID: String
        var expiresAt: Date
        var heartbeatAt: Date

        var isValid: Bool {
            expiresAt > .now && Date().timeIntervalSince(heartbeatAt) < 3
        }
    }

    static func dictateURL(id: String, hostBundleID: String?, hostPID: Int? = nil, keyboardStack: Bool) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "dictate"
        var items = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "stack", value: keyboardStack ? "ext" : "app")
        ]
        if let hostBundleID, !hostBundleID.isEmpty {
            items.append(URLQueryItem(name: "host", value: hostBundleID))
        }
        if let hostPID, hostPID > 1 {
            items.append(URLQueryItem(name: "hostpid", value: String(hostPID)))
        }
        parts.queryItems = items
        return parts.url!
    }

    static func request(from url: URL) -> (id: String, hostBundleID: String, hostPID: Int, keyboardStack: Bool)? {
        guard url.scheme == scheme, url.host == "dictate" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let id = items.first(where: { $0.name == "id" })?.value, !id.isEmpty else { return nil }
        let host = items.first(where: { $0.name == "host" })?.value ?? ""
        let hostPID = Int(items.first(where: { $0.name == "hostpid" })?.value ?? "") ?? 0
        let stack = items.first(where: { $0.name == "stack" })?.value == "ext"
        return (id, host, hostPID, stack)
    }

    static func write(_ payload: Payload) {
        guard let url = fileURL else { return }
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
    }

    static func read() -> Payload? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func writeLease(_ lease: Lease) {
        guard let url = leaseFileURL, let data = try? JSONEncoder().encode(lease) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func readLease() -> Lease? {
        guard let url = leaseFileURL,
              let data = try? Data(contentsOf: url),
              let lease = try? JSONDecoder().decode(Lease.self, from: data) else { return nil }
        guard lease.isValid else {
            clearLease()
            return nil
        }
        return lease
    }

    static func clearLease() {
        guard let url = leaseFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func pendingAge() -> TimeInterval? {
        guard let url = fileURL,
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modified = values.contentModificationDate else { return nil }
        return Date().timeIntervalSince(modified)
    }

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroupStore.suiteName)?
            .appendingPathComponent("handoff.json")
    }

    private static var leaseFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroupStore.suiteName)?
            .appendingPathComponent("handoff-lease.json")
    }
}
