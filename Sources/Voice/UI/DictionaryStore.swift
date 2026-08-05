import Foundation
import os.log

/// A single dictionary correction entry: a canonical term plus the
/// misheard/mistranscribed variants that should be replaced with it.
struct DictionaryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var term: String
    var variants: [String]
    var fixCount: Int
    /// True when this entry was created by `learn(from:to:)` (a History-edit
    /// correction folded in automatically) rather than typed into the
    /// composer by hand. Decodes to `false` for pre-existing persisted
    /// entries that predate this field.
    var isAutoLearned: Bool

    init(id: UUID = UUID(), term: String, variants: [String], fixCount: Int = 0, isAutoLearned: Bool = false) {
        self.id = id
        self.term = term
        self.variants = variants
        self.fixCount = fixCount
        self.isAutoLearned = isAutoLearned
    }

    // Custom decoding so pre-existing persisted entries (written before this
    // field existed) default `isAutoLearned` to `false` instead of failing to
    // decode outright.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        term = try container.decode(String.self, forKey: .term)
        variants = try container.decode([String].self, forKey: .variants)
        fixCount = try container.decode(Int.self, forKey: .fixCount)
        isAutoLearned = try container.decodeIfPresent(Bool.self, forKey: .isAutoLearned) ?? false
    }
}

/// A single variant→term mapping recorded by `learn(from:to:)`, surfaced to
/// the UI so it can show a "Learned" pill with an undo affordance.
struct LearnedCorrection: Identifiable, Equatable {
    let id: UUID
    let variant: String
    let term: String
    let createdNewEntry: Bool
    let entryID: UUID

    init(variant: String, term: String, createdNewEntry: Bool, entryID: UUID) {
        self.id = UUID()
        self.variant = variant
        self.term = term
        self.createdNewEntry = createdNewEntry
        self.entryID = entryID
    }
}

/// One or more corrections learned from a single History Save action,
/// grouped so the pill can show/undo them together.
struct LearnBatch: Identifiable, Equatable {
    let id: UUID
    let corrections: [LearnedCorrection]

    init(corrections: [LearnedCorrection]) {
        self.id = UUID()
        self.corrections = corrections
    }
}

struct BlockedPair: Codable, Hashable {
    let heard: String
    let replaced: String
}

/// Flat (no categories) list of dictionary corrections, persisted to
/// Application Support. Provides literal, whole-word, case-insensitive
/// find/replace correction — no LLM cleanup layer, per scope.
final class DictionaryStore: ObservableObject {

    @Published private(set) var entries: [DictionaryEntry] = []
    @Published private(set) var blocklist: Set<BlockedPair> = []

    /// Most recent batch of corrections learned from a History edit, for the
    /// transient "Learned" pill + undo. Not persisted — purely a UI signal.
    @Published var recentlyLearned: LearnBatch?

    /// Minimum normalized similarity (1 - editDistance/maxLen) a candidate
    /// variant→term pair must clear to be learned. See `learn(from:to:)`.
    private static let minLearnSimilarity = 0.5

    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "dictionary-store")

    /// Compiled whole-word regexes keyed by variant string. Rebuilt whenever
    /// `entries` changes so `correct(_:)` doesn't recompile per call.
    private var variantRegexCache: [String: NSRegularExpression] = [:]
    /// Metaphone code → entry IDs for phonetic matching over canonical terms.
    private var phoneticIndex: [String: [UUID]] = [:]
    private let wordTokenRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\b[\\p{L}\\p{N}'-]+\\b",
        options: []
    )
    private var saveWorkItem: DispatchWorkItem?
    private var blocklistSaveWorkItem: DispatchWorkItem?

    private let fileURL: URL
    private let blocklistFileURL: URL

    init(fileURL: URL? = nil, blocklistFileURL: URL? = nil) {
        self.fileURL = fileURL ?? DictionaryStore.defaultFileURL()
        self.blocklistFileURL = blocklistFileURL ?? DictionaryStore.defaultBlocklistFileURL()
        load()
        loadBlocklist()
        rebuildRegexCache()
    }

    // MARK: - Paths

    private static func defaultFileURL() -> URL {
        VoicePaths.prepareApplicationSupportVoiceDirectory()
        return VoicePaths.applicationSupportVoiceDirectory.appendingPathComponent("dictionary.json")
    }

    private static func defaultBlocklistFileURL() -> URL {
        VoicePaths.prepareApplicationSupportVoiceDirectory()
        return VoicePaths.applicationSupportVoiceDirectory.appendingPathComponent("blocklist.json")
    }

    // MARK: - Load / save

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            entries = try JSONDecoder().decode([DictionaryEntry].self, from: data)
        } catch {
            quarantineCorruptFile(at: fileURL, label: "dictionary.json", error: error) {
                self.entries = []
            }
        }
    }

    private func loadBlocklist() {
        guard FileManager.default.fileExists(atPath: blocklistFileURL.path) else { return }
        guard let data = try? Data(contentsOf: blocklistFileURL) else { return }
        do {
            let pairs = try JSONDecoder().decode([BlockedPair].self, from: data)
            blocklist = Set(pairs)
        } catch {
            quarantineCorruptFile(at: blocklistFileURL, label: "blocklist.json", error: error) {
                self.blocklist = []
            }
        }
    }

    private func quarantineCorruptFile(at url: URL, label: String, error: Error, reset: () -> Void) {
        let bak = URL(fileURLWithPath: url.path + ".corrupt.\(Int(Date().timeIntervalSince1970))")
        do {
            if FileManager.default.fileExists(atPath: bak.path) {
                try FileManager.default.removeItem(at: bak)
            }
            try FileManager.default.moveItem(at: url, to: bak)
            logger.error("Quarantined corrupt \(label) → \(bak.lastPathComponent): \(error.localizedDescription)")
        } catch {
            logger.error("Failed to quarantine corrupt \(label): \(error.localizedDescription)")
        }
        reset()
    }

    private func save() {
        rebuildRegexCache()
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func saveBlocklist() {
        let pairs = Array(blocklist)
        guard let data = try? JSONEncoder().encode(pairs) else { return }
        try? data.write(to: blocklistFileURL, options: .atomic)
    }

    private func scheduleSave() {
        // Rebuild caches immediately so correct()/expand() see new entries
        // before the debounced disk write lands.
        rebuildRegexCache()
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.save()
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func scheduleBlocklistSave() {
        blocklistSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveBlocklist()
        }
        blocklistSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        blocklistSaveWorkItem?.cancel()
        blocklistSaveWorkItem = nil
        save()
        saveBlocklist()
    }

    func blocklistPair(heard: String, replaced: String) {
        let pair = BlockedPair(
            heard: heard.lowercased(),
            replaced: replaced.lowercased()
        )
        let mutate = {
            self.blocklist.insert(pair)
            self.scheduleBlocklistSave()
        }
        Thread.isMainThread ? mutate() : DispatchQueue.main.async(execute: mutate)
    }

    func isBlocklisted(heard: String, replaced: String) -> Bool {
        blocklist.contains(BlockedPair(heard: heard.lowercased(), replaced: replaced.lowercased()))
    }

    private func rebuildRegexCache() {
        var cache: [String: NSRegularExpression] = [:]
        var index: [String: [UUID]] = [:]
        for entry in entries {
            for variant in entry.variants where !variant.isEmpty {
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: variant))\\b"
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    cache[variant] = regex
                }
            }
            let encoded = PhoneticMatcher.encode(entry.term)
            for code in [encoded.primary, encoded.secondary].compactMap({ $0 }) where !code.isEmpty {
                index[code, default: []].append(entry.id)
            }
        }
        variantRegexCache = cache
        phoneticIndex = index
    }

    // MARK: - CRUD

    func add(term: String, variants: [String]) {
        _ = addReturningID(term: term, variants: variants, isAutoLearned: false)
    }

    /// Same as `add`, but hands back the id of the created entry so callers
    /// (namely `recordLearnedVariant`) can track what they just wrote without
    /// re-searching `entries` by term after the fact. Returns `nil` if the
    /// term was empty and nothing was created.
    @discardableResult
    private func addReturningID(term: String, variants: [String], isAutoLearned: Bool) -> UUID? {
        let cleanTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTerm.isEmpty else { return nil }
        let cleanVariants = variants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let newEntry = DictionaryEntry(term: cleanTerm, variants: cleanVariants, isAutoLearned: isAutoLearned)
        let mutate = {
            self.entries.append(newEntry)
            self.scheduleSave()
        }
        Thread.isMainThread ? mutate() : DispatchQueue.main.async(execute: mutate)
        return newEntry.id
    }

    func update(_ entry: DictionaryEntry) {
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

    // MARK: - Correction (literal, whole-word, MVP — no LLM layer)

    /// Applies case-insensitive, whole-word replacement of each entry's
    /// variants with its canonical term. Increments `fixCount` per
    /// replacement actually performed and persists. Safe to call from any
    /// thread (mutation is hopped to main synchronously via a semaphore-free
    /// approach: callers on a background queue should tolerate the persisted
    /// counts landing slightly after return — the returned corrected string
    /// is always computed synchronously and correct immediately).
    func correct(_ text: String) -> (text: String, records: [CorrectionRecord]) {
        guard !entries.isEmpty else { return (text, []) }

        var result = text
        var fixCounts: [UUID: Int] = [:]
        var records: [CorrectionRecord] = []

        for entry in entries {
            for variant in entry.variants {
                guard !variant.isEmpty else { continue }
                guard !isBlocklisted(heard: variant, replaced: entry.term) else { continue }
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
                let source: CorrectionSource = entry.isAutoLearned ? .autoLearned : .dictionary
                for _ in 0..<matches {
                    records.append(CorrectionRecord(heard: variant, replaced: entry.term, source: source))
                }
            }
        }

        result = applyPhoneticPass(to: result, fixCounts: &fixCounts, records: &records)

        guard !fixCounts.isEmpty else { return (result, records) }

        let apply = {
            for (id, count) in fixCounts {
                if let idx = self.entries.firstIndex(where: { $0.id == id }) {
                    self.entries[idx].fixCount += count
                }
            }
            self.scheduleSave()
        }
        Thread.isMainThread ? apply() : DispatchQueue.main.async(execute: apply)

        return (result, records)
    }

    private func applyPhoneticPass(
        to text: String,
        fixCounts: inout [UUID: Int],
        records: inout [CorrectionRecord]
    ) -> String {
        guard let regex = wordTokenRegex else { return text }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        guard !matches.isEmpty else { return text }

        var output = ""
        var lastIndex = text.startIndex

        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            output += text[lastIndex..<matchRange.lowerBound]
            let token = String(text[matchRange])

            if let replacement = phoneticReplacement(for: token) {
                output += replacement.term
                fixCounts[replacement.entryID, default: 0] += 1
                records.append(
                    CorrectionRecord(
                        heard: token,
                        replaced: replacement.term,
                        source: replacement.source
                    )
                )
            } else {
                output += token
            }

            lastIndex = matchRange.upperBound
        }

        output += text[lastIndex...]
        return output
    }

    private struct PhoneticReplacement {
        let term: String
        let entryID: UUID
        let source: CorrectionSource
    }

    private func phoneticReplacement(for token: String) -> PhoneticReplacement? {
        guard !token.isEmpty else { return nil }

        if entries.contains(where: { $0.term.caseInsensitiveCompare(token) == .orderedSame }) {
            return nil
        }

        let encoded = PhoneticMatcher.encode(token)
        var tokenCodes = Set([encoded.primary])
        if let secondary = encoded.secondary { tokenCodes.insert(secondary) }

        var candidateIDs = Set<UUID>()
        for code in tokenCodes {
            if let ids = phoneticIndex[code] {
                candidateIDs.formUnion(ids)
            }
        }
        guard !candidateIDs.isEmpty else { return nil }

        var best: (entry: DictionaryEntry, distance: Int)?
        for entry in entries where candidateIDs.contains(entry.id) {
            guard !isBlocklisted(heard: token, replaced: entry.term) else { continue }
            let primaryKeyMatch = PhoneticMatcher.encode(entry.term).primary == encoded.primary
            guard PhoneticMatcher.guardAccepts(
                heard: token,
                candidate: entry.term,
                primaryKeyMatch: primaryKeyMatch
            ) else { continue }
            let distance = PhoneticMatcher.levenshteinDistance(token, entry.term)
            if let current = best {
                if distance < current.distance {
                    best = (entry, distance)
                }
            } else {
                best = (entry, distance)
            }
        }

        guard let winner = best else { return nil }
        let source: CorrectionSource = winner.entry.isAutoLearned ? .autoLearned : .phonetic
        return PhoneticReplacement(term: winner.entry.term, entryID: winner.entry.id, source: source)
    }

    // MARK: - Learn from corrections (History edit → Dictionary)

    /// Folds a user's manual History edit into the dictionary as one or more
    /// variant→term mappings, reusing `add`/`update`'s persistence path.
    ///
    /// When `userInitiated` is true (History Save), every changed word pair is
    /// learned — the user explicitly corrected the transcript and can undo via
    /// the Learned pill. The similarity gate only applies to automated callers.
    ///
    /// User-initiated learning also handles word-count changes when ASR splits
    /// one term into several words (e.g. "Get ignore" → "gitignore") or vice
    /// versa, by aligning unchanged suffixes around the changed run.
    @discardableResult
    func learn(from oldText: String, to newText: String, userInitiated: Bool = false) -> [LearnedCorrection] {
        let old = oldText.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard old != new else { return [] }

        let oldWords = tokenizeWords(old)
        let newWords = tokenizeWords(new)
        guard !oldWords.isEmpty, !newWords.isEmpty else { return [] }

        let recorded: [LearnedCorrection]
        if oldWords.count == newWords.count {
            recorded = learnSameWordCount(oldWords: oldWords, newWords: newWords, userInitiated: userInitiated)
        } else if userInitiated {
            recorded = learnAligned(oldWords: oldWords, newWords: newWords, userInitiated: true)
        } else {
            recorded = []
        }

        if !recorded.isEmpty {
            let batch = LearnBatch(corrections: recorded)
            let publish = { self.recentlyLearned = batch }
            Thread.isMainThread ? publish() : DispatchQueue.main.async(execute: publish)
        }

        return recorded
    }

    private func learnSameWordCount(
        oldWords: [String],
        newWords: [String],
        userInitiated: Bool
    ) -> [LearnedCorrection] {
        let punctuation = CharacterSet.punctuationCharacters
        var recorded: [LearnedCorrection] = []

        for (oldWord, newWord) in zip(oldWords, newWords) {
            guard oldWord != newWord else { continue }

            let strippedOld = oldWord.trimmingCharacters(in: punctuation)
            let strippedNew = newWord.trimmingCharacters(in: punctuation)
            guard isLearnableVariant(strippedOld), !strippedNew.isEmpty else { continue }
            guard strippedOld.caseInsensitiveCompare(strippedNew) != .orderedSame else { continue }

            if !userInitiated {
                let maxLen = max(strippedOld.count, strippedNew.count)
                let similarity = maxLen == 0 ? 0 : 1.0 - Double(editDistance(strippedOld, strippedNew)) / Double(maxLen)
                guard similarity >= Self.minLearnSimilarity else { continue }
            }

            if let correction = recordLearnedVariant(
                strippedOld,
                mapsTo: strippedNew,
                respectBlocklist: !userInitiated
            ) {
                recorded.append(correction)
            }
        }

        return recorded
    }

    /// Aligns word sequences when counts differ — handles ASR splitting one term
    /// into multiple words (merge) or joining multiple heard words into one.
    private func learnAligned(
        oldWords: [String],
        newWords: [String],
        userInitiated: Bool
    ) -> [LearnedCorrection] {
        var recorded: [LearnedCorrection] = []
        var i = 0
        var j = 0

        while i < oldWords.count && j < newWords.count {
            if wordsMatch(oldWords[i], newWords[j]) {
                i += 1
                j += 1
                continue
            }

            if let merge = findMerge(oldWords: oldWords, newWords: newWords, startOld: i, startNew: j) {
                if let correction = recordLearnedVariant(
                    merge.variant,
                    mapsTo: merge.term,
                    respectBlocklist: !userInitiated
                ) {
                    recorded.append(correction)
                }
                i += merge.oldCount
                j += 1
                continue
            }

            if let split = findSplit(oldWords: oldWords, newWords: newWords, startOld: i, startNew: j) {
                if let correction = recordLearnedVariant(
                    split.variant,
                    mapsTo: split.term,
                    respectBlocklist: !userInitiated
                ) {
                    recorded.append(correction)
                }
                i += 1
                j += split.newCount
                continue
            }

            let strippedOld = stripWord(oldWords[i])
            let strippedNew = stripWord(newWords[j])
            if isLearnableVariant(strippedOld),
               !strippedNew.isEmpty,
               strippedOld.caseInsensitiveCompare(strippedNew) != .orderedSame {
                if userInitiated,
                   let correction = recordLearnedVariant(
                    strippedOld,
                    mapsTo: strippedNew,
                    respectBlocklist: false
                   ) {
                    recorded.append(correction)
                }
            }
            i += 1
            j += 1
        }

        return recorded
    }

    private struct WordRunMapping {
        let variant: String
        let term: String
        let oldCount: Int
        let newCount: Int
    }

    /// Multiple heard words → one corrected word (e.g. "Get ignore" → "gitignore").
    private func findMerge(
        oldWords: [String],
        newWords: [String],
        startOld: Int,
        startNew: Int
    ) -> WordRunMapping? {
        let maxRun = min(4, oldWords.count - startOld)
        guard maxRun >= 2 else { return nil }

        for runLength in (2...maxRun).reversed() {
            let run = Array(oldWords[startOld..<(startOld + runLength)])
            let variant = run.map(stripWord).filter { !$0.isEmpty }.joined(separator: " ")
            let term = stripWord(newWords[startNew])
            guard !variant.isEmpty, !term.isEmpty else { continue }
            guard suffixesMatch(
                oldWords: oldWords,
                fromOld: startOld + runLength,
                newWords: newWords,
                fromNew: startNew + 1
            ) else { continue }

            return WordRunMapping(variant: variant, term: term, oldCount: runLength, newCount: 1)
        }

        return nil
    }

    /// One heard word → multiple corrected words (rare; symmetric to merge).
    private func findSplit(
        oldWords: [String],
        newWords: [String],
        startOld: Int,
        startNew: Int
    ) -> WordRunMapping? {
        let maxRun = min(4, newWords.count - startNew)
        guard maxRun >= 2 else { return nil }

        for runLength in (2...maxRun).reversed() {
            let run = Array(newWords[startNew..<(startNew + runLength)])
            let term = run.map(stripWord).filter { !$0.isEmpty }.joined(separator: " ")
            let variant = stripWord(oldWords[startOld])
            guard !variant.isEmpty, !term.isEmpty else { continue }
            guard suffixesMatch(
                oldWords: oldWords,
                fromOld: startOld + 1,
                newWords: newWords,
                fromNew: startNew + runLength
            ) else { continue }

            return WordRunMapping(variant: variant, term: term, oldCount: 1, newCount: runLength)
        }

        return nil
    }

    private func suffixesMatch(
        oldWords: [String],
        fromOld: Int,
        newWords: [String],
        fromNew: Int
    ) -> Bool {
        let restOld = Array(oldWords[fromOld...])
        let restNew = Array(newWords[fromNew...])
        guard restOld.count == restNew.count else { return false }
        guard !restOld.isEmpty else { return true }
        return zip(restOld, restNew).allSatisfy { wordsMatch($0, $1) }
    }

    private func stripWord(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet.punctuationCharacters)
    }

    private func wordsMatch(_ a: String, _ b: String) -> Bool {
        stripWord(a).caseInsensitiveCompare(stripWord(b)) == .orderedSame
    }

    private func isLearnableVariant(_ stripped: String) -> Bool {
        guard !stripped.isEmpty else { return false }
        guard stripped.count > 1 || stripped.rangeOfCharacter(from: .punctuationCharacters) == nil else { return false }
        guard stripped.rangeOfCharacter(from: .decimalDigits.inverted) != nil else { return false }
        return true
    }

    /// Records a single learned variant→term mapping: appends to an existing
    /// entry whose `term` matches `newWord` case-insensitively (deduping the
    /// variant case-insensitively), or creates a new entry. Returns the
    /// `LearnedCorrection` describing what happened (and where), or `nil` if
    /// the variant was already present and nothing changed.
    private func recordLearnedVariant(
        _ variant: String,
        mapsTo term: String,
        respectBlocklist: Bool = false
    ) -> LearnedCorrection? {
        if respectBlocklist, isBlocklisted(heard: variant, replaced: term) {
            return nil
        }
        if let existing = entries.first(where: { $0.term.caseInsensitiveCompare(term) == .orderedSame }) {
            let alreadyPresent = existing.variants.contains { $0.caseInsensitiveCompare(variant) == .orderedSame }
            guard !alreadyPresent else { return nil }
            var updated = existing
            updated.variants.append(variant)
            update(updated)
            return LearnedCorrection(variant: variant, term: term, createdNewEntry: false, entryID: existing.id)
        } else {
            guard let newID = addReturningID(term: term, variants: [variant], isAutoLearned: true) else { return nil }
            return LearnedCorrection(variant: variant, term: term, createdNewEntry: true, entryID: newID)
        }
    }

    /// Reverses a single learned correction: deletes the entry it created, or
    /// removes just the variant it appended to a pre-existing entry (keeping
    /// the entry and its other variants intact). Also clears `recentlyLearned`
    /// if the pill currently showing is the batch this correction belongs to,
    /// so undoing doesn't leave a stale pill on screen.
    func unlearn(_ correction: LearnedCorrection) {
        if correction.createdNewEntry {
            if let entry = entries.first(where: { $0.id == correction.entryID }) {
                delete(entry)
            }
        } else {
            guard let existing = entries.first(where: { $0.id == correction.entryID }) else { return }
            var updated = existing
            updated.variants.removeAll { $0.caseInsensitiveCompare(correction.variant) == .orderedSame }
            update(updated)
        }

        let clearIfMatching = {
            if let batch = self.recentlyLearned, batch.corrections.contains(where: { $0.id == correction.id }) {
                self.recentlyLearned = nil
            }
        }
        Thread.isMainThread ? clearIfMatching() : DispatchQueue.main.async(execute: clearIfMatching)
    }

    // MARK: - Tokenization

    private func tokenizeWords(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    // MARK: - Edit distance (similarity gate for `learn`)

    /// Damerau–Levenshtein distance (optimal string alignment variant: single
    /// transpositions of adjacent characters count as one edit, same as an
    /// insertion/deletion/substitution). Case-insensitive by comparing
    /// lowercased character arrays. This is the standard metric for "is this
    /// a typo of that" — it's what makes "teh"→"the" (distance 1, a
    /// transposition) and "wispr"→"whisper" (distance 2) read as near
    /// neighbors, while unrelated words score far apart.
    private func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a.lowercased())
        let b = Array(b.lowercased())
        let (m, n) = (a.count, b.count)
        guard m > 0 else { return n }
        guard n > 0 else { return m }

        // dp[i][j] = edit distance between a[0..<i] and b[0..<j]
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var best = min(
                    dp[i - 1][j] + 1,      // deletion
                    dp[i][j - 1] + 1,      // insertion
                    dp[i - 1][j - 1] + cost // substitution (or match)
                )
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    best = min(best, dp[i - 2][j - 2] + cost) // transposition
                }
                dp[i][j] = best
            }
        }

        return dp[m][n]
    }
}
