import Foundation

enum AppGroupStore {
    static let suiteName = "group.com.matt.murmur.ios"
    static let apiKeyKey = "elevenLabsAPIKey"
    static let languageKey = "languageCode"
    static let lastHostKey = "lastHostBundleID"
    static let microphoneLevelKey = "microphoneLevel"

    private static var suite: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    static var apiKey: String {
        get { suite?.string(forKey: apiKeyKey) ?? "" }
        set { suite?.set(newValue, forKey: apiKeyKey) }
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
}
