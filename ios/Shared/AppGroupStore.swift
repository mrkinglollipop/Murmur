import Foundation

enum AppGroupStore {
    static let suiteName = "group.com.matt.murmur.ios"
    static let apiKeyKey = "elevenLabsAPIKey"
    static let giphyAPIKeyKey = "giphyAPIKey"
    static let languageKey = "languageCode"
    static let lastHostKey = "lastHostBundleID"
    static let microphoneLevelKey = "microphoneLevel"
    static let listenGateRequestIDKey = "listenGateRequestID"

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

    static var languageCode: String {
        get {
            let value = suite?.string(forKey: languageKey) ?? ""
            return value.isEmpty ? "en" : value
        }
        set { suite?.set(newValue, forKey: languageKey) }
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
}
