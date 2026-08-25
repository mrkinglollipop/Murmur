import Foundation

enum AppGroupStore {
    static let suiteName = "group.com.matt.murmur.ios"
    static let apiKeyKey = "elevenLabsAPIKey"
    static let giphyAPIKeyKey = "giphyAPIKey"
    static let languageKey = "languageCode"
    static let lastHostKey = "lastHostBundleID"
    static let microphoneLevelKey = "microphoneLevel"
    static let listenGateRequestIDKey = "listenGateRequestID"
    static let swipeTypingEnabledKey = "swipeTypingEnabled"
    static let recentEmojiKey = "recentEmoji"
    static let interstitialAppsKey = "interstitialReturnAppIDs"

    private static var suite: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    static var apiKey: String {
        get { suite?.string(forKey: apiKeyKey) ?? "" }
        set { suite?.set(newValue, forKey: apiKeyKey) }
    }

    static var giphyAPIKey: String {
        get { suite?.string(forKey: giphyAPIKeyKey) ?? "" }
        set { suite?.set(newValue, forKey: giphyAPIKeyKey) }
    }

    /// Picks up a one-shot `giphy-key.txt` from the App Group (device copy), then deletes it.
    static func consumeGiphySeedIfNeeded() {
        guard giphyAPIKey.isEmpty else { return }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: suiteName
        ) else { return }
        let candidates = [
            container.appendingPathComponent("giphy-key.txt"),
            container.appendingPathComponent("Library/Caches/giphy-key.txt")
        ]
        for file in candidates {
            guard let raw = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            giphyAPIKey = key
            try? FileManager.default.removeItem(at: file)
            return
        }
    }

    /// Keyboard and Scribe are English-only. Stored values other than `en` are ignored.
    static var languageCode: String {
        get { "en" }
        set { suite?.set("en", forKey: languageKey) }
    }

    static var lastHostBundleID: String {
        get { suite?.string(forKey: lastHostKey) ?? "" }
        set { suite?.set(newValue, forKey: lastHostKey) }
    }

    static var microphoneLevel: Double {
        get { suite?.double(forKey: microphoneLevelKey) ?? 0 }
        set { suite?.set(min(1, max(0, newValue)), forKey: microphoneLevelKey) }
    }

    /// Non-empty while a keyboard-initiated take has the input graph armed but is
    /// waiting for the keyboard to reappear before opening the WAV segment.
    static var listenGateRequestID: String {
        get { suite?.string(forKey: listenGateRequestIDKey) ?? "" }
        set { suite?.set(newValue, forKey: listenGateRequestIDKey) }
    }

    static var recentEmoji: [String] {
        get { suite?.stringArray(forKey: recentEmojiKey) ?? [] }
        set {
            var seen = Set<String>()
            var ordered: [String] = []
            for glyph in newValue where !glyph.isEmpty {
                guard seen.insert(glyph).inserted else { continue }
                ordered.append(glyph)
                if ordered.count == 36 { break }
            }
            suite?.set(ordered, forKey: recentEmojiKey)
        }
    }

    static func rememberEmoji(_ glyph: String) {
        let trimmed = glyph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = recentEmoji.filter { $0 != trimmed }
        next.insert(trimmed, at: 0)
        recentEmoji = next
    }

    /// Missing key means off. Typing quality first; turn on in Settings to experiment.
    static var swipeTypingEnabled: Bool {
        get {
            guard let suite, suite.object(forKey: swipeTypingEnabledKey) != nil else { return false }
            return suite.bool(forKey: swipeTypingEnabledKey)
        }
        set { suite?.set(newValue, forKey: swipeTypingEnabledKey) }
    }

    /// Bundle IDs shown as jump-back tiles on the swipe interstitial, in grid order.
    static var interstitialReturnAppIDs: [String] {
        get {
            let exists = suite?.object(forKey: interstitialAppsKey) != nil
            return ReturnAppCatalog.resolvedIDs(
                stored: suite?.stringArray(forKey: interstitialAppsKey),
                keyExists: exists
            )
        }
        set {
            suite?.set(ReturnAppCatalog.sanitizedIDs(newValue), forKey: interstitialAppsKey)
        }
    }

    static func addInterstitialReturnApp(_ bundleID: String) {
        var ids = interstitialReturnAppIDs
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ReturnAppCatalog.isAllowed(id), !ids.contains(id) else { return }
        ids.append(id)
        interstitialReturnAppIDs = ids
    }

    static func removeInterstitialReturnApp(_ bundleID: String) {
        interstitialReturnAppIDs = interstitialReturnAppIDs.filter { $0 != bundleID }
    }

    static func reorderInterstitialReturnApp(moving: String, onto: String) {
        interstitialReturnAppIDs = ReturnAppCatalog.reorderedIDs(
            interstitialReturnAppIDs,
            moving: moving,
            onto: onto
        )
    }

    static func setInterstitialReturnApp(_ bundleID: String, enabled: Bool) {
        if enabled {
            addInterstitialReturnApp(bundleID)
        } else {
            removeInterstitialReturnApp(bundleID)
        }
    }

    static let selectedStyleKey = "selectedStyle"
    static let dictionaryIntroKey = "dictionaryIntroDismissed"
    static let snippetsIntroKey = "snippetsIntroDismissed"

    static var selectedStyleRaw: String {
        get { suite?.string(forKey: selectedStyleKey) ?? "casual" }
        set { suite?.set(newValue, forKey: selectedStyleKey) }
    }

    static func introDismissed(_ key: String) -> Bool {
        suite?.bool(forKey: key) ?? false
    }

    static func dismissIntro(_ key: String) {
        suite?.set(true, forKey: key)
    }

    /// App Group file, or a temp directory when the suite is unavailable (unit tests).
    static func sharedFile(_ name: String) -> URL {
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: suiteName
        ) {
            return container.appendingPathComponent(name)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "murmur-ios-stores",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }
}
