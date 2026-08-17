import Combine
import Foundation
import os.log

struct ScratchpadNote: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var body: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "",
        body: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

final class ScratchpadStore: ObservableObject {

    @Published private(set) var notes: [ScratchpadNote] = []

    private let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?
    private let logger = Logger(subsystem: "com.matt.murmur.ios", category: "scratchpad-store")

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? AppGroupStore.sharedFile("scratchpad.json")
        load()
    }

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
            logger.error("Quarantined corrupt scratchpad.json: \(error.localizedDescription)")
        } catch {
            logger.error("Failed to quarantine scratchpad.json: \(error.localizedDescription)")
        }
        notes = []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(notes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

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

    func update(id: UUID, title: String, body: String) {
        let mutate = {
            guard let idx = self.notes.firstIndex(where: { $0.id == id }) else { return }
            guard self.notes[idx].title != title || self.notes[idx].body != body else { return }
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
