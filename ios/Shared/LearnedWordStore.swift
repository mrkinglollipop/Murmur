import Foundation

/// Words taught from the keyboard (Apple-style tap-to-keep). App Group JSON.
enum LearnedWordStore {
    private static let cap = 400
    private static let lock = NSLock()
    private static var cachedWords: [String]?
    private static var cachedKeys: Set<String>?
    private static var cachedModificationDate: Date?

    static func words() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return loadedLocked()
    }

    static func contains(_ raw: String) -> Bool {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        _ = loadedLocked()
        return cachedKeys?.contains(key) ?? false
    }

    static func learn(_ raw: String) {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard word.count >= 2 else { return }
        guard word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return }
        let key = word.lowercased()
        lock.lock()
        defer { lock.unlock() }
        var list = loadedLocked().filter { $0.lowercased() != key }
        list.insert(word, at: 0)
        if list.count > cap { list = Array(list.prefix(cap)) }
        persistLocked(list)
    }

    static func unlearn(_ raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let list = loadedLocked().filter { $0.lowercased() != key }
        persistLocked(list)
    }

    private static func loadedLocked() -> [String] {
        if let cachedWords, !diskIsNewerThanCache() {
            return cachedWords
        }
        let list = readFromDisk()
        cachedWords = list
        cachedKeys = Set(list.map { $0.lowercased() })
        cachedModificationDate = fileModificationDate()
        return list
    }

    private static func persistLocked(_ list: [String]) {
        cachedWords = list
        cachedKeys = Set(list.map { $0.lowercased() })
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: fileURL, options: .atomic)
        cachedModificationDate = fileModificationDate()
    }

    private static func diskIsNewerThanCache() -> Bool {
        let disk = fileModificationDate()
        switch (disk, cachedModificationDate) {
        case (nil, nil):
            return false
        case (nil, .some):
            return true
        case (.some, nil):
            return true
        case let (disk?, cached?):
            return disk > cached
        }
    }

    private static func fileModificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
    }

    private static func readFromDisk() -> [String] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return list
    }

    private static var fileURL: URL {
        AppGroupStore.sharedFile("learned-words.json")
    }
}
