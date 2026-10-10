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
    private var savedEntries: [DictionaryEntry] = []
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
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            entries = Self.mergingChanges(base: savedEntries, local: entries, current: [])
            savedEntries = []
            return
        }
        var coordinationError: NSError?
        var decoded: [DictionaryEntry]?
        var readError: Error?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { url in
            do {
                decoded = try JSONDecoder().decode([DictionaryEntry].self, from: Data(contentsOf: url))
            } catch {
                readError = error
            }
        }
        guard let decoded else {
            if let readError = readError as? DecodingError {
                quarantineCorruptFile(error: readError)
            }
            return
        }
        entries = Self.mergingDuplicateTerms(
            Self.mergingChanges(base: savedEntries, local: entries, current: decoded)
        )
        savedEntries = decoded
        if entries != decoded, saveWorkItem == nil { save() }
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
        savedEntries = []
    }

    private func save() {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: [], error: &coordinationError) { url in
            do {
                let current: [DictionaryEntry]
                if FileManager.default.fileExists(atPath: url.path) {
                    current = try JSONDecoder().decode([DictionaryEntry].self, from: Data(contentsOf: url))
                } else {
                    current = []
                }
                let merged = Self.mergingDuplicateTerms(
                    Self.mergingChanges(base: savedEntries, local: entries, current: current)
                )
                try JSONEncoder().encode(merged).write(to: url, options: .atomic)
                savedEntries = merged
                entries = merged
            } catch {
                writeError = error
            }
        }
        if coordinationError != nil || writeError != nil {
            logger.error("Failed to save dictionary.json")
        }
        rebuildRegexCache()
    }

    /// Apply only local changes since the last read. A concurrent deletion wins
    /// over a stale edit; unchanged local entries never resurrect deleted IDs.
    static func mergingChanges(
        base: [DictionaryEntry],
        local: [DictionaryEntry],
        current: [DictionaryEntry]
    ) -> [DictionaryEntry] {
        let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localIDs = Set(local.map(\.id))
        let deletedIDs = Set(base.map(\.id)).subtracting(localIDs)
        var result = current.filter { !deletedIDs.contains($0.id) }
        for entry in local {
            guard let original = baseByID[entry.id] else {
                if !result.contains(where: { $0.id == entry.id }) { result.append(entry) }
                continue
            }
            guard entry != original,
                  let index = result.firstIndex(where: { $0.id == entry.id }) else { continue }
            if entry.term != original.term { result[index].term = entry.term }
            if entry.variants != original.variants { result[index].variants = entry.variants }
            if entry.isAutoLearned != original.isAutoLearned {
                result[index].isAutoLearned = entry.isAutoLearned
            }
            result[index].fixCount += entry.fixCount - original.fixCount
        }
        return result
    }

    private func scheduleSave() {
        rebuildRegexCache()
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveWorkItem = nil
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
        let mutate = {
            if let idx = self.entries.firstIndex(where: {
                $0.term.caseInsensitiveCompare(cleanTerm) == .orderedSame
            }) {
                var updated = self.entries[idx]
                var changed = false
                for variant in cleanVariants where !updated.variants.contains(where: {
                    $0.caseInsensitiveCompare(variant) == .orderedSame
                }) {
                    updated.variants.append(variant)
                    changed = true
                }
                if !isAutoLearned && updated.isAutoLearned {
                    updated.isAutoLearned = false
                    changed = true
                }
                if changed {
                    self.entries[idx] = updated
                    self.scheduleSave()
                }
                return
            }
            self.entries.append(
                DictionaryEntry(
                    term: cleanTerm,
                    variants: cleanVariants,
                    isAutoLearned: isAutoLearned
                )
            )
            self.scheduleSave()
        }
        Thread.isMainThread ? mutate() : DispatchQueue.main.async(execute: mutate)
    }

    func update(_ entry: DictionaryEntry) {
        let cleanTerm = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTerm.isEmpty else { return }
        var cleaned = entry
        cleaned.term = cleanTerm
        let mutate = {
            guard let idx = self.entries.firstIndex(where: { $0.id == cleaned.id }) else { return }
            if let otherIdx = self.entries.firstIndex(where: {
                $0.id != cleaned.id
                    && $0.term.caseInsensitiveCompare(cleaned.term) == .orderedSame
            }) {
                self.entries[otherIdx] = Self.absorbing(cleaned, into: self.entries[otherIdx])
                self.entries.removeAll { $0.id == cleaned.id }
            } else {
                self.entries[idx] = cleaned
            }
            self.scheduleSave()
        }
        Thread.isMainThread ? mutate() : DispatchQueue.main.async(execute: mutate)
    }

    static func mergingDuplicateTerms(_ entries: [DictionaryEntry]) -> [DictionaryEntry] {
        var result: [DictionaryEntry] = []
        var indexByTerm: [String: Int] = [:]
        for entry in entries {
            let key = entry.term.lowercased()
            if let idx = indexByTerm[key] {
                result[idx] = absorbing(entry, into: result[idx])
            } else {
                indexByTerm[key] = result.count
                result.append(entry)
            }
        }
        return result
    }

    private static func absorbing(_ donor: DictionaryEntry, into survivor: DictionaryEntry) -> DictionaryEntry {
        var result = survivor
        for variant in donor.variants where !result.variants.contains(where: {
            $0.caseInsensitiveCompare(variant) == .orderedSame
        }) {
            result.variants.append(variant)
        }
        result.fixCount += donor.fixCount
        if !donor.isAutoLearned {
            result.isAutoLearned = false
        }
        return result
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
