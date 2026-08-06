import Foundation
import os.log

enum CorrectionSource: String, Codable {
    case dictionary
    case phonetic
    case autoLearned
    case learnAccepted
    case learnRejected
}

struct CorrectionRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let heard: String
    let replaced: String
    let source: CorrectionSource
    let date: Date
    /// Present on new `learnAccepted` / `learnRejected` rows; nil for older records.
    let entryID: UUID?
    /// Present on new learn-outcome rows; nil for older records.
    let createdNewEntry: Bool?

    init(
        id: UUID = UUID(),
        heard: String,
        replaced: String,
        source: CorrectionSource,
        date: Date = Date(),
        entryID: UUID? = nil,
        createdNewEntry: Bool? = nil
    ) {
        self.id = id
        self.heard = heard
        self.replaced = replaced
        self.source = source
        self.date = date
        self.entryID = entryID
        self.createdNewEntry = createdNewEntry
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        heard = try container.decode(String.self, forKey: .heard)
        replaced = try container.decode(String.self, forKey: .replaced)
        source = try container.decode(CorrectionSource.self, forKey: .source)
        date = try container.decode(Date.self, forKey: .date)
        entryID = try container.decodeIfPresent(UUID.self, forKey: .entryID)
        createdNewEntry = try container.decodeIfPresent(Bool.self, forKey: .createdNewEntry)
    }
}

/// Persisted log of dictionary/phonetic corrections applied to transcripts
/// and learn-time accept/reject outcomes.
final class CorrectionsLog: ObservableObject {

    /// App-owned instance wired from `AppDelegate`; `DictionaryView` reads this
    /// when constructed without an explicit `correctionsLog` argument.
    static weak var liveInstance: CorrectionsLog?

    @Published private(set) var records: [CorrectionRecord] = []

    private let fileURL: URL
    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "corrections-log")
    private var saveWorkItem: DispatchWorkItem?

    private static let maxRecords = 200

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? CorrectionsLog.defaultFileURL()
        load()
    }

    private static func defaultFileURL() -> URL {
        VoicePaths.prepareApplicationSupportVoiceDirectory()
        return VoicePaths.applicationSupportVoiceDirectory.appendingPathComponent("corrections-log.json")
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            records = try JSONDecoder().decode([CorrectionRecord].self, from: data)
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
            logger.error("Quarantined corrupt corrections-log.json → \(bak.lastPathComponent): \(error.localizedDescription)")
        } catch {
            logger.error("Failed to quarantine corrupt corrections-log.json: \(error.localizedDescription)")
        }
        records = []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.save()
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func append(_ newRecords: [CorrectionRecord]) {
        guard !newRecords.isEmpty else { return }
        let mutate = {
            self.records.append(contentsOf: newRecords)
            if self.records.count > Self.maxRecords {
                self.records.removeFirst(self.records.count - Self.maxRecords)
            }
            self.scheduleSave()
        }
        Thread.isMainThread ? mutate() : DispatchQueue.main.async(execute: mutate)
    }

    func recent(days: Int = 7, now: Date = Date()) -> [CorrectionRecord] {
        let cutoff = now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
        return records.filter { $0.date >= cutoff }.sorted { $0.date > $1.date }
    }

    func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        save()
    }
}
