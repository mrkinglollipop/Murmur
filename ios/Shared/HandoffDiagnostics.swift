import Foundation

enum HandoffDiagnostics {
    struct Entry: Codable {
        let timestamp: Date
        let process: String
        let event: String
        let detail: String
    }

    static func record(_ event: String, detail: String = "") {
        guard let url = fileURL else { return }
        var entries = read()
        entries.append(.init(
            timestamp: Date(),
            process: Bundle.main.bundleIdentifier ?? "unknown",
            event: event,
            detail: detail
        ))
        if entries.count > 100 {
            entries.removeFirst(entries.count - 100)
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func read() -> [Entry] {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return entries
    }

    private static var fileURL: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupStore.suiteName
        ) else { return nil }
        let directory = container.appendingPathComponent("Library/Caches", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("murmur-handoff-diagnostics.json")
    }
}
