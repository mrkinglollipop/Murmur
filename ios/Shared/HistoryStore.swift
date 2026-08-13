import Combine
import Foundation
import os.log

struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    var text: String
    var failed: Bool

    init(id: UUID = UUID(), date: Date = Date(), text: String, failed: Bool = false) {
        self.id = id
        self.date = date
        self.text = text
        self.failed = failed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        text = try container.decode(String.self, forKey: .text)
        failed = try container.decodeIfPresent(Bool.self, forKey: .failed) ?? false
    }
}

/// Recent iOS takes for Home. Transcript text stays in this App Group file only.
final class HistoryStore: ObservableObject {

    @Published private(set) var entries: [HistoryEntry] = []

    private let maxEntries = 200
    private let fileURL: URL
    private let logger = Logger(subsystem: "com.matt.murmur.ios", category: "history-store")
    private var saveWorkItem: DispatchWorkItem?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? AppGroupStore.sharedFile("history.json")
        load()
    }

    var wordCount: Int {
        entries.filter { !$0.failed }.reduce(0) { count, entry in
            count + entry.text.split { $0.isWhitespace || $0.isNewline }.count
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            entries = try decoder.decode([HistoryEntry].self, from: data)
        } catch {
            quarantineCorruptFile(error: error)
        }
    }

    private func quarantineCorruptFile(error: Error) {
        let bak = URL(fileURLWithPath: fileURL.path + ".corrupt.\(Int(Date().timeIntervalSince1970))")
        do {
            if FileManager.default.fileExists(atPath: bak.path) {
                try FileManager.default.removeItem(at: bak)
            }
            try FileManager.default.moveItem(at: fileURL, to: bak)
            logger.error("Quarantined corrupt history.json: \(error.localizedDescription)")
        } catch {
            logger.error("Failed to quarantine history.json: \(error.localizedDescription)")
        }
        entries = []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func append(text: String, failed: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = HistoryEntry(text: trimmed, failed: failed)
        let mutate = {
            self.entries.insert(entry, at: 0)
            if self.entries.count > self.maxEntries {
                self.entries = Array(self.entries.prefix(self.maxEntries))
            }
            self.save()
        }
        Thread.isMainThread ? mutate() : DispatchQueue.main.async(execute: mutate)
    }

    func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        save()
    }
}
