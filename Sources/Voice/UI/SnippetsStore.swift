import Foundation
import os.log

/// A single voice-triggered text expansion: speak the trigger phrase, get the
/// expansion in its place.
struct Snippet: Codable, Identifiable, Equatable {
    let id: UUID
    var trigger: String
    var expansion: String

    init(id: UUID = UUID(), trigger: String, expansion: String) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
    }
}

/// Flat list of trigger→expansion snippets, persisted to Application Support
/// alongside the dictionary. Mirrors `DictionaryStore`'s persistence pattern
/// (same directory, same load/save/thread-hop approach) and provides literal,
/// whole-phrase, case-insensitive find/replace expansion.
final class SnippetsStore: ObservableObject {

    @Published private(set) var snippets: [Snippet] = []

    private let fileURL: URL
    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "snippets-store")

    /// Compiled whole-phrase regexes keyed by trigger string. Rebuilt whenever
    /// `snippets` changes so `expand(_:)` doesn't recompile per call.
    private var triggerRegexCache: [String: NSRegularExpression] = [:]
    private var saveWorkItem: DispatchWorkItem?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? SnippetsStore.defaultFileURL()
        load()
        rebuildRegexCache()
    }

    // MARK: - Paths

    private static func defaultFileURL() -> URL {
        VoicePaths.prepareApplicationSupportVoiceDirectory()
        return VoicePaths.applicationSupportVoiceDirectory.appendingPathComponent("snippets.json")
    }

    // MARK: - Load / save

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            snippets = try JSONDecoder().decode([Snippet].self, from: data)
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
            logger.error("Quarantined corrupt snippets.json → \(bak.lastPathComponent): \(error.localizedDescription)")
        } catch {
            logger.error("Failed to quarantine corrupt snippets.json: \(error.localizedDescription)")
        }
        snippets = []
    }

    private func save() {
        rebuildRegexCache()
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func scheduleSave() {
        rebuildRegexCache()
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

    private func rebuildRegexCache() {
        var cache: [String: NSRegularExpression] = [:]
        for snippet in snippets {
            let trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty else { continue }
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: trigger))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                cache[trigger] = regex
            }
        }
        triggerRegexCache = cache
    }

    // MARK: - CRUD

    func add(trigger: String, expansion: String) {
        let cleanTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanExpansion = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTrigger.isEmpty, !cleanExpansion.isEmpty else { return }
        let newSnippet = Snippet(trigger: cleanTrigger, expansion: cleanExpansion)
        let mutate = {
            self.snippets.append(newSnippet)
            self.scheduleSave()
        }
        Thread.isMainThread ? mutate() : DispatchQueue.main.async(execute: mutate)
    }

    func update(_ snippet: Snippet) {
        let mutate = {
            guard let idx = self.snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
            self.snippets[idx] = snippet
            self.scheduleSave()
        }
        Thread.isMainThread ? mutate() : DispatchQueue.main.async(execute: mutate)
    }

    func delete(_ snippet: Snippet) {
        let mutate = {
            self.snippets.removeAll { $0.id == snippet.id }
            self.scheduleSave()
        }
        Thread.isMainThread ? mutate() : DispatchQueue.main.async(execute: mutate)
    }

    // MARK: - Expansion

    /// Replaces every occurrence of each snippet's trigger phrase in `text`
    /// with its expansion — case-insensitive, whole-phrase (word-boundary
    /// matched, same regex shape as `DictionaryStore.correct`). Longest
    /// triggers are applied first so a short trigger (e.g. "see") can't
    /// partially shadow a longer one (e.g. "see you soon") before the more
    /// specific trigger gets a chance to match the full phrase.
    func expand(_ text: String) -> String {
        guard !snippets.isEmpty else { return text }

        var result = text
        let longestFirst = snippets.sorted { $0.trigger.count > $1.trigger.count }

        for snippet in longestFirst {
            let trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty else { continue }
            guard let regex = triggerRegexCache[trigger] else { continue }
            let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: nsRange,
                withTemplate: NSRegularExpression.escapedTemplate(for: snippet.expansion)
            )
        }

        return result
    }
}
