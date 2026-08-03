import Foundation
import os.log

/// A single scratchpad note — a free-form dictation surface, not tied to a
/// specific transcript.
struct ScratchpadNote: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var body: String
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), title: String = "", body: String = "", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Flat list of scratchpad notes, persisted to Application Support. Mirrors
/// `DictionaryStore`/`SnippetsStore`'s persistence pattern (same directory,
/// same load/save/thread-hop approach).
final class ScratchpadStore: ObservableObject {

    @Published private(set) var notes: [ScratchpadNote] = []

    private let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?
    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "scratchpad-store")

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? ScratchpadStore.defaultFileURL()
        load()
    }

    // MARK: - Paths

    private static func defaultFileURL() -> URL {
        VoicePaths.prepareApplicationSupportVoiceDirectory()
        return VoicePaths.applicationSupportVoiceDirectory.appendingPathComponent("scratchpad.json")
    }

    // MARK: - Load / save

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            notes = try decoder.decode([ScratchpadNote].self, from: data)
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
            logger.error("Quarantined corrupt scratchpad.json → \(bak.lastPathComponent): \(error.localizedDescription)")
        } catch {
            logger.error("Failed to quarantine corrupt scratchpad.json: \(error.localizedDescription)")
        }
        notes = []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(notes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - CRUD

    /// Creates a new blank note and returns it so the caller can select it
    /// immediately (newest-first ordering maintained internally).
    @discardableResult
    func newNote() -> ScratchpadNote {
        let note = ScratchpadNote()
        let mutate = {
            self.notes.insert(note, at: 0)
            self.save()
        }
        Thread.isMainThread ? mutate() : DispatchQueue.main.async(execute: mutate)
        return note
    }

    /// Updates title/body for the note with the given `id` and bumps
    /// `updatedAt`. Called on every edit (title field + `TextEditor` body),
    /// so this is the save path — no separate explicit "Save" action.
    /// Persists are debounced ~1s to avoid rewriting JSON on every keystroke.
    func update(id: UUID, title: String, body: String) {
        let mutate = {
            guard let idx = self.notes.firstIndex(where: { $0.id == id }) else { return }
            self.notes[idx].title = title
            self.notes[idx].body = body
            self.notes[idx].updatedAt = Date()
            self.scheduleSave()
        }
        Thread.isMainThread ? mutate() : DispatchQueue.main.async(execute: mutate)
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.save()
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        save()
    }

    func delete(id: UUID) {
        let mutate = {
            self.notes.removeAll { $0.id == id }
            self.save()
        }
        Thread.isMainThread ? mutate() : DispatchQueue.main.async(execute: mutate)
    }
}
