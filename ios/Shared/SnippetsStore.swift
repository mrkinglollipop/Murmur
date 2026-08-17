import Combine
import Foundation
import os.log

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

/// Trigger → expansion snippets. Same JSON shape as Mac Murmur.
final class SnippetsStore: ObservableObject {

    @Published private(set) var snippets: [Snippet] = []

    private let fileURL: URL
    private let logger = Logger(subsystem: "com.matt.murmur.ios", category: "snippets-store")
    private var triggerRegexCache: [String: NSRegularExpression] = [:]
    private var saveWorkItem: DispatchWorkItem?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? AppGroupStore.sharedFile("snippets.json")
        load()
        rebuildRegexCache()
    }

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
            logger.error("Quarantined corrupt snippets.json: \(error.localizedDescription)")
        } catch {
            logger.error("Failed to quarantine snippets.json: \(error.localizedDescription)")
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
            let pattern = PhraseBoundaryPattern.wholePhrase(for: trigger)
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                cache[trigger] = regex
            }
        }
        triggerRegexCache = cache
    }

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
        guard !snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !snippet.expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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

    /// Longest triggers first so a short trigger cannot shadow a longer phrase.
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
