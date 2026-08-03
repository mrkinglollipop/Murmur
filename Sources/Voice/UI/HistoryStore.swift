import Foundation
import AppKit
import os.log

/// A single logged dictation.
struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    var text: String
    var engine: String
    /// Whether the text was successfully injected into a focused app.
    /// `false` means it was left on the clipboard for manual paste.
    var injected: Bool
    /// Path to the captured audio file, when retained for retry.
    var audioPath: String?
    /// Transcription never produced usable text — audio may be retried.
    var failed: Bool

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        text: String,
        engine: String,
        injected: Bool,
        audioPath: String? = nil,
        failed: Bool = false
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.engine = engine
        self.injected = injected
        self.audioPath = audioPath
        self.failed = failed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        text = try container.decode(String.self, forKey: .text)
        engine = try container.decode(String.self, forKey: .engine)
        injected = try container.decode(Bool.self, forKey: .injected)
        audioPath = try container.decodeIfPresent(String.self, forKey: .audioPath)
        failed = try container.decodeIfPresent(Bool.self, forKey: .failed) ?? false
    }
}

/// Persists every completed dictation to disk so nothing is ever lost, even
/// if text injection fails. Backed by a flat JSON file in Application Support.
///
/// PRIVACY: transcript text is stored ONLY in this app-owned JSON file. Never
/// pass transcript text to `vlog`, `os_log`, `print`, or any /tmp path.
final class HistoryStore: ObservableObject {

    @Published private(set) var entries: [HistoryEntry] = []

    /// Cap on retained entries — oldest are dropped past this count.
    private let maxEntries = 1000

    private let fileURL: URL
    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "history-store")

    private var saveWorkItem: DispatchWorkItem?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? HistoryStore.defaultFileURL()
        load()
    }

    // MARK: - Paths

    private static func defaultFileURL() -> URL {
        VoicePaths.prepareApplicationSupportVoiceDirectory()
        return VoicePaths.applicationSupportVoiceDirectory.appendingPathComponent("history.json")
    }

    // MARK: - Load / save

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            entries = try decoder.decode([HistoryEntry].self, from: data)
            clearMissingAudioPathsSync()
        } catch {
            quarantineCorruptFile(error: error)
        }
    }

    /// Moves a corrupt on-disk file aside so the next save cannot silently
    /// clobber recoverable user data.
    private func quarantineCorruptFile(error: Error) {
        let bak = URL(fileURLWithPath: fileURL.path + ".corrupt.\(Int(Date().timeIntervalSince1970))")
        do {
            if FileManager.default.fileExists(atPath: bak.path) {
                try FileManager.default.removeItem(at: bak)
            }
            try FileManager.default.moveItem(at: fileURL, to: bak)
            logger.error("Quarantined corrupt history.json → \(bak.lastPathComponent): \(error.localizedDescription)")
        } catch {
            logger.error("Failed to quarantine corrupt history.json: \(error.localizedDescription); original decode error: \(error.localizedDescription)")
        }
        entries = []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
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

    /// Cancels a pending debounced save and writes immediately — call on quit.
    func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        save()
    }

    // MARK: - Public API

    /// Appends a new entry (newest-first ordering maintained internally) and
    /// persists immediately. Safe to call from any thread — hops to main.
    /// When `replaceEntryID` is set, updates that row instead of inserting
    /// (retry path — concurrent live dictation always passes nil).
    func append(
        text: String,
        engine: String,
        injected: Bool,
        audioPath: String? = nil,
        failed: Bool = false,
        replaceEntryID: UUID? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || failed else { return }

        func mutate() {
            if let retryID = replaceEntryID {
                self.applyRetryResult(
                    id: retryID,
                    text: trimmed,
                    engine: engine,
                    injected: injected,
                    audioPath: audioPath,
                    failed: failed
                )
                return
            }

            let entry = HistoryEntry(
                text: failed && trimmed.isEmpty ? "Transcription failed" : trimmed,
                engine: engine,
                injected: injected,
                audioPath: audioPath,
                failed: failed
            )
            self.entries.insert(entry, at: 0)
            if self.entries.count > self.maxEntries {
                self.entries.removeLast(self.entries.count - self.maxEntries)
            }
            self.save()
        }

        if Thread.isMainThread {
            mutate()
        } else {
            DispatchQueue.main.async { mutate() }
        }
    }

    /// Re-transcribes a failed entry's retained audio via `asrSelector`.
    /// On success, updates the existing row; on failure, leaves `failed = true`.
    /// Passes `replaceEntryID` through the transcription pipeline so concurrent
    /// live dictation cannot steal the slot via a global pending flag.
    func retryTranscription(id: UUID, asrSelector: ASREngineSelector, completion: (() -> Void)? = nil) {
        func start() {
            guard let entry = self.entries.first(where: { $0.id == id }),
                  entry.failed,
                  let path = entry.audioPath,
                  FileManager.default.fileExists(atPath: path) else {
                completion?()
                return
            }

            let url = URL(fileURLWithPath: path)
            asrSelector.transcribeAndLog(audioURL: url, replaceHistoryEntryID: id) { _ in
                completion?()
            }
        }

        if Thread.isMainThread {
            start()
        } else {
            DispatchQueue.main.async { start() }
        }
    }

    private func applyRetryResult(
        id: UUID,
        text: String,
        engine: String,
        injected: Bool,
        audioPath: String?,
        failed: Bool
    ) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        if failed || text.isEmpty {
            entries[idx].failed = true
            entries[idx].engine = engine
            if let audioPath { entries[idx].audioPath = audioPath }
        } else {
            entries[idx].text = text
            entries[idx].engine = engine
            entries[idx].injected = injected
            entries[idx].failed = false
            entries[idx].audioPath = audioPath ?? entries[idx].audioPath
        }
        save()
    }

    /// Paths of retained audio still needed for failed-entry retry — prune
    /// must not delete these. Strips missing paths first so prune protect list
    /// and history stay aligned with on-disk files.
    /// Prefer main-thread callers (Settings budget apply). Audio IO should use
    /// `protectedAudioPathsSnapshot()` so it never mutates `@Published` off-main.
    func protectedAudioPaths() -> [String] {
        clearMissingAudioPathsSync()
        return protectedAudioPathsSnapshot()
    }

    /// Read-only protect list for the audio IO queue — no mutation, no disk
    /// clear. Safe from any thread; may include paths that no longer exist
    /// (harmless: prune simply never sees those files).
    func protectedAudioPathsSnapshot() -> [String] {
        entries.compactMap { entry in
            guard entry.failed, let path = entry.audioPath, !path.isEmpty else { return nil }
            return path
        }
    }

    /// Downgrades the most recent entry matching `text` to `injected = false`.
    /// Used when injection is discovered to have failed AFTER the entry was
    /// already optimistically logged as injected — history is always written
    /// before injection is attempted, so this only ever corrects the flag,
    /// never loses the transcript itself.
    func markLastEntryNotInjected(text: String) {
        func mutate() {
            guard let idx = self.entries.firstIndex(where: { $0.text == text }) else { return }
            self.entries[idx].injected = false
            self.scheduleSave()
        }

        if Thread.isMainThread {
            mutate()
        } else {
            DispatchQueue.main.async { mutate() }
        }
    }

    /// Clears `audioPath` on entries whose files no longer exist (after prune
    /// or external deletion). Safe to call from any thread.
    func clearMissingAudioPaths() {
        if Thread.isMainThread {
            clearMissingAudioPathsSync()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.clearMissingAudioPathsSync()
            }
        }
    }

    /// Synchronous clear used after load and when building the protect list.
    private func clearMissingAudioPathsSync() {
        var changed = false
        for i in entries.indices {
            guard let path = entries[i].audioPath else { continue }
            if !FileManager.default.fileExists(atPath: path) {
                entries[i].audioPath = nil
                changed = true
            }
        }
        if changed { save() }
    }

    /// Persists a user-edited transcript for the entry with the given `id`.
    /// A blank/whitespace-only edit is ignored (never blanks out an entry).
    func updateText(id: UUID, newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        func mutate() {
            guard let idx = self.entries.firstIndex(where: { $0.id == id }) else { return }
            self.entries[idx].text = trimmed
            self.scheduleSave()
        }

        if Thread.isMainThread {
            mutate()
        } else {
            DispatchQueue.main.async { mutate() }
        }
    }

    /// Removes the entry with the given `id`. One-click delete, no undo — a
    /// single transcript line isn't worth a confirmation dialog.
    func delete(id: UUID) {
        func mutate() {
            self.entries.removeAll { $0.id == id }
            self.scheduleSave()
        }
        if Thread.isMainThread {
            mutate()
        } else {
            DispatchQueue.main.async { mutate() }
        }
    }

    func copyToPasteboard(_ entry: HistoryEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
    }

    /// Exports all entries as JSON (ISO8601 dates).
    func exportJSON() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(entries)
    }

    /// Exports all entries as a Markdown document.
    func exportMarkdown() -> String {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = ["# Murmur History", ""]
        for entry in entries {
            lines.append("## \(formatter.string(from: entry.date))")
            lines.append("")
            lines.append("- Engine: `\(entry.engine)`")
            lines.append("- Injected: \(entry.injected ? "yes" : "no")")
            if entry.failed { lines.append("- Status: transcription failed") }
            lines.append("")
            lines.append(entry.text)
            lines.append("")
            lines.append("---")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
