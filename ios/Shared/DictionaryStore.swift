import Combine
import Foundation
import os.log

/// Canonical term plus the misheard variants that should be replaced with it.
struct DictionaryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var term: String
    var variants: [String]
    var fixCount: Int
    var isAutoLearned: Bool

    init(
        id: UUID = UUID(),
        term: String,
        variants: [String],
        fixCount: Int = 0,
        isAutoLearned: Bool = false
    ) {
        self.id = id
        self.term = term
        self.variants = variants
        self.fixCount = fixCount
        self.isAutoLearned = isAutoLearned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        term = try container.decode(String.self, forKey: .term)
        variants = try container.decode([String].self, forKey: .variants)
        fixCount = try container.decode(Int.self, forKey: .fixCount)
        isAutoLearned = try container.decodeIfPresent(Bool.self, forKey: .isAutoLearned) ?? false
    }
}

/// Literal whole-word dictionary corrections. Same JSON shape as Mac Murmur.
/// Phonetic / History-learn live on Mac only — iOS applies typed variants.
final class DictionaryStore: ObservableObject {

    @Published private(set) var entries: [DictionaryEntry] = []

    private let fileURL: URL
    private let logger = Logger(subsystem: "com.matt.murmur.ios", category: "dictionary-store")
    private var variantRegexCache: [String: NSRegularExpression] = [:]
    private var saveWorkItem: DispatchWorkItem?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? AppGroupStore.sharedFile("dictionary.json")
        load()
        rebuildRegexCache()
    }

    func reload() {
        load()
        rebuildRegexCache()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            entries = try JSONDecoder().decode([DictionaryEntry].self, from: data)
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
            logger.error("Quarantined corrupt dictionary.json: \(error.localizedDescription)")
        } catch {
            logger.error("Failed to quarantine dictionary.json: \(error.localizedDescription)")
        }
        entries = []
    }

    private func save() {
        rebuildRegexCache()
        guard let data = try? JSONEncoder().encode(entries) else { return }
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
        for entry in entries {
            for variant in entry.variants where !variant.isEmpty {
                let pattern = PhraseBoundaryPattern.wholePhrase(for: variant)
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    cache[variant] = regex
                }
            }
        }
        variantRegexCache = cache
    }

    func add(term: String, variants: [String], isAutoLearned: Bool = false) {
        let cleanTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTerm.isEmpty else { return }
        let cleanVariants = variants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let newEntry = DictionaryEntry(
            term: cleanTerm,
            variants: cleanVariants,
            isAutoLearned: isAutoLearned
        )
        let mutate = {
            self.entries.append(newEntry)
            self.scheduleSave()
        }
        Thread.isMainThread ? mutate() : DispatchQueue.main.async(execute: mutate)
    }

    func update(_ entry: DictionaryEntry) {
        guard !entry.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let mutate = {
            guard let idx = self.entries.firstIndex(where: { $0.id == entry.id }) else { return }
            self.entries[idx] = entry
            self.scheduleSave()
        }
        Thread.isMainThread ? mutate() : DispatchQueue.main.async(execute: mutate)
    }

    func delete(_ entry: DictionaryEntry) {
        let mutate = {
            self.entries.removeAll { $0.id == entry.id }
            self.scheduleSave()
        }
        Thread.isMainThread ? mutate() : DispatchQueue.main.async(execute: mutate)
    }

    /// Case-insensitive whole-word replacement of each entry's variants with its term.
    func correct(_ text: String) -> String {
        guard !entries.isEmpty else { return text }

        var result = text
        var fixCounts: [UUID: Int] = [:]

        for entry in entries {
            for variant in entry.variants {
                guard !variant.isEmpty else { continue }
                guard let regex = variantRegexCache[variant] else { continue }
                let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
                let matches = regex.numberOfMatches(in: result, options: [], range: nsRange)
                guard matches > 0 else { continue }
                result = regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: nsRange,
                    withTemplate: NSRegularExpression.escapedTemplate(for: entry.term)
                )
                fixCounts[entry.id, default: 0] += matches
            }
        }

        guard !fixCounts.isEmpty else { return result }

        let apply = {
            for (id, count) in fixCounts {
                if let idx = self.entries.firstIndex(where: { $0.id == id }) {
                    self.entries[idx].fixCount += count
                }
            }
            self.scheduleSave()
        }
        Thread.isMainThread ? apply() : DispatchQueue.main.async(execute: apply)

        return result
    }

    /// Canonical terms for Scribe `keyterms`. Never variants. Batch allows 50
    /// characters; drop longer terms rather than fail the request.
    static let maxKeyterms = 50
    static let maxKeytermLength = 50

    static func selectKeyterms(from entries: [DictionaryEntry]) -> [String] {
        var seen = Set<String>()
        var candidates: [(term: String, fixCount: Int, index: Int)] = []
        for (index, entry) in entries.enumerated() {
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count > 1, term.utf8.count <= maxKeytermLength else { continue }
            let key = term.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            candidates.append((term: term, fixCount: entry.fixCount, index: index))
        }
        candidates.sort { a, b in
            if a.fixCount != b.fixCount { return a.fixCount > b.fixCount }
            return a.index > b.index
        }
        return candidates.prefix(maxKeyterms).map(\.term)
    }
}
