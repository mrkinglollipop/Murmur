import Foundation

enum SelectedCloudEngine: String, CaseIterable, Identifiable, Codable {
    case elevenLabs
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .elevenLabs: return "ElevenLabs Scribe v2"
        case .gemini: return "Gemini 3.5 Transcribe"
        }
    }
}

enum AppGroupStore {
    static let suiteName = "group.com.matt.murmur.ios"
    static let apiKeyKey = "elevenLabsAPIKey"
    static let geminiAPIKeyKey = "geminiAPIKey"
    static let selectedCloudEngineKey = "selectedCloudEngine"
    static let geminiVadModeKey = "geminiVadMode"
    static let geminiStartSensitivityKey = "geminiStartSensitivity"
    static let geminiEndSensitivityKey = "geminiEndSensitivity"
    static let geminiPrefixPaddingMsKey = "geminiPrefixPaddingMs"
    static let geminiSilenceDurationMsKey = "geminiSilenceDurationMs"
    static let elevenLabsFilterBackgroundAudioKey = "elevenLabsFilterBackgroundAudio"
    static let elevenLabsCommitStrategyKey = "elevenLabsCommitStrategy"
    static let elevenLabsVadThresholdKey = "elevenLabsVadThreshold"
    static let elevenLabsVadSilenceThresholdSecsKey = "elevenLabsVadSilenceThresholdSecs"
    static let elevenLabsMinSpeechDurationMsKey = "elevenLabsMinSpeechDurationMs"
    static let elevenLabsMinSilenceDurationMsKey = "elevenLabsMinSilenceDurationMs"
    static let giphyAPIKeyKey = "giphyAPIKey"
    static let languageKey = "languageCode"
    static let lastHostKey = "lastHostBundleID"
    static let microphoneLevelKey = "microphoneLevel"
    static let listenGateRequestIDKey = "listenGateRequestID"
    static let swipeTypingEnabledKey = "swipeTypingEnabled"
    static let removeFillerWordsKey = "removeFillerWords"
    static let recentEmojiKey = "recentEmoji"
    static let interstitialAppsKey = "interstitialReturnAppIDs"

    private static var suite: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    static var apiKey: String {
        get { suite?.string(forKey: apiKeyKey) ?? "" }
        set { suite?.set(newValue, forKey: apiKeyKey) }
    }

    static var geminiAPIKey: String {
        get { suite?.string(forKey: geminiAPIKeyKey) ?? "" }
        set { suite?.set(newValue, forKey: geminiAPIKeyKey) }
    }

    static var selectedCloudEngine: SelectedCloudEngine {
        get {
            guard let raw = suite?.string(forKey: selectedCloudEngineKey),
                  let engine = SelectedCloudEngine(rawValue: raw) else {
                return .elevenLabs
            }
            return engine
        }
        set { suite?.set(newValue.rawValue, forKey: selectedCloudEngineKey) }
    }

    static var geminiVadMode: GeminiVadMode {
        get {
            guard let raw = suite?.string(forKey: geminiVadModeKey),
                  let mode = GeminiVadMode(rawValue: raw) else {
                return .manual
            }
            return mode
        }
        set { suite?.set(newValue.rawValue, forKey: geminiVadModeKey) }
    }

    static var geminiStartSensitivity: GeminiStartSensitivity {
        get {
            guard let raw = suite?.string(forKey: geminiStartSensitivityKey),
                  let value = GeminiStartSensitivity(rawValue: raw) else {
                return .high
            }
            return value
        }
        set { suite?.set(newValue.rawValue, forKey: geminiStartSensitivityKey) }
    }

    static var geminiEndSensitivity: GeminiEndSensitivity {
        get {
            guard let raw = suite?.string(forKey: geminiEndSensitivityKey),
                  let value = GeminiEndSensitivity(rawValue: raw) else {
                return .high
            }
            return value
        }
        set { suite?.set(newValue.rawValue, forKey: geminiEndSensitivityKey) }
    }

    static var geminiPrefixPaddingMs: Int {
        get {
            guard let suite, suite.object(forKey: geminiPrefixPaddingMsKey) != nil else {
                return GeminiLiveOptions.defaults.prefixPaddingMs
            }
            return GeminiLiveOptions.clamp(
                suite.integer(forKey: geminiPrefixPaddingMsKey),
                to: GeminiLiveOptions.prefixPaddingRange
            )
        }
        set {
            suite?.set(
                GeminiLiveOptions.clamp(newValue, to: GeminiLiveOptions.prefixPaddingRange),
                forKey: geminiPrefixPaddingMsKey
            )
        }
    }

    static var geminiSilenceDurationMs: Int {
        get {
            guard let suite, suite.object(forKey: geminiSilenceDurationMsKey) != nil else {
                return GeminiLiveOptions.defaults.silenceDurationMs
            }
            return GeminiLiveOptions.clamp(
                suite.integer(forKey: geminiSilenceDurationMsKey),
                to: GeminiLiveOptions.silenceDurationRange
            )
        }
        set {
            suite?.set(
                GeminiLiveOptions.clamp(newValue, to: GeminiLiveOptions.silenceDurationRange),
                forKey: geminiSilenceDurationMsKey
            )
        }
    }

    static var elevenLabsFilterBackgroundAudio: Bool {
        get { suite?.bool(forKey: elevenLabsFilterBackgroundAudioKey) ?? false }
        set { suite?.set(newValue, forKey: elevenLabsFilterBackgroundAudioKey) }
    }

    static var elevenLabsCommitStrategy: ElevenLabsCommitStrategy {
        get {
            guard let raw = suite?.string(forKey: elevenLabsCommitStrategyKey),
                  let strategy = ElevenLabsCommitStrategy(rawValue: raw) else {
                return .manual
            }
            return strategy
        }
        set { suite?.set(newValue.rawValue, forKey: elevenLabsCommitStrategyKey) }
    }

    static var elevenLabsVadThreshold: Double {
        get {
            guard let suite, suite.object(forKey: elevenLabsVadThresholdKey) != nil else {
                return ElevenLabsRealtimeOptions.defaults.vadThreshold
            }
            return ElevenLabsRealtimeOptions.clamp(
                suite.double(forKey: elevenLabsVadThresholdKey),
                to: ElevenLabsRealtimeOptions.vadThresholdRange
            )
        }
        set {
            suite?.set(
                ElevenLabsRealtimeOptions.clamp(newValue, to: ElevenLabsRealtimeOptions.vadThresholdRange),
                forKey: elevenLabsVadThresholdKey
            )
        }
    }

    static var elevenLabsVadSilenceThresholdSecs: Double {
        get {
            guard let suite, suite.object(forKey: elevenLabsVadSilenceThresholdSecsKey) != nil else {
                return ElevenLabsRealtimeOptions.defaults.vadSilenceThresholdSecs
            }
            return ElevenLabsRealtimeOptions.clamp(
                suite.double(forKey: elevenLabsVadSilenceThresholdSecsKey),
                to: ElevenLabsRealtimeOptions.vadSilenceRange
            )
        }
        set {
            suite?.set(
                ElevenLabsRealtimeOptions.clamp(newValue, to: ElevenLabsRealtimeOptions.vadSilenceRange),
                forKey: elevenLabsVadSilenceThresholdSecsKey
            )
        }
    }

    static var elevenLabsMinSpeechDurationMs: Int {
        get {
            guard let suite, suite.object(forKey: elevenLabsMinSpeechDurationMsKey) != nil else {
                return ElevenLabsRealtimeOptions.defaults.minSpeechDurationMs
            }
            return ElevenLabsRealtimeOptions.clamp(
                suite.integer(forKey: elevenLabsMinSpeechDurationMsKey),
                to: ElevenLabsRealtimeOptions.minSpeechMsRange
            )
        }
        set {
            suite?.set(
                ElevenLabsRealtimeOptions.clamp(newValue, to: ElevenLabsRealtimeOptions.minSpeechMsRange),
                forKey: elevenLabsMinSpeechDurationMsKey
            )
        }
    }

    static var elevenLabsMinSilenceDurationMs: Int {
        get {
            guard let suite, suite.object(forKey: elevenLabsMinSilenceDurationMsKey) != nil else {
                return ElevenLabsRealtimeOptions.defaults.minSilenceDurationMs
            }
            return ElevenLabsRealtimeOptions.clamp(
                suite.integer(forKey: elevenLabsMinSilenceDurationMsKey),
                to: ElevenLabsRealtimeOptions.minSilenceMsRange
            )
        }
        set {
            suite?.set(
                ElevenLabsRealtimeOptions.clamp(newValue, to: ElevenLabsRealtimeOptions.minSilenceMsRange),
                forKey: elevenLabsMinSilenceDurationMsKey
            )
        }
    }

    static var elevenLabsRealtimeOptions: ElevenLabsRealtimeOptions {
        ElevenLabsRealtimeOptions(
            filterBackgroundAudio: elevenLabsFilterBackgroundAudio,
            commitStrategy: elevenLabsCommitStrategy,
            vadThreshold: elevenLabsVadThreshold,
            vadSilenceThresholdSecs: elevenLabsVadSilenceThresholdSecs,
            minSpeechDurationMs: elevenLabsMinSpeechDurationMs,
            minSilenceDurationMs: elevenLabsMinSilenceDurationMs
        )
    }

    static var geminiLiveOptions: GeminiLiveOptions {
        GeminiLiveOptions(
            vadMode: geminiVadMode,
            startSensitivity: geminiStartSensitivity,
            endSensitivity: geminiEndSensitivity,
            prefixPaddingMs: geminiPrefixPaddingMs,
            silenceDurationMs: geminiSilenceDurationMs
        ).clamped()
    }

    /// API key for the currently selected cloud engine.
    static var selectedEngineAPIKey: String {
        switch selectedCloudEngine {
        case .elevenLabs: return apiKey
        case .gemini: return geminiAPIKey
        }
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

    /// Scribe batch `no_verbatim`. Missing key means on — matches the previous
    /// hardcoded `noVerbatim: true` in `DictationController`.
    static var removeFillerWords: Bool {
        get {
            guard let suite, suite.object(forKey: removeFillerWordsKey) != nil else { return true }
            return suite.bool(forKey: removeFillerWordsKey)
        }
        set { suite?.set(newValue, forKey: removeFillerWordsKey) }
    }

    /// Bundle IDs shown as jump-back tiles on the swipe interstitial, in grid order.
    ///
    /// Reads fall back to a process-local mirror before factory defaults:
    /// an App Group read that comes back key-missing after the key was set
    /// silently replaced the user's chosen grid with the factory apps. The
    /// diagnostic record is what tells us which failure actually happens.
    static var interstitialReturnAppIDs: [String] {
        get {
            let suite = self.suite
            let stored = suite?.stringArray(forKey: interstitialAppsKey)
            let exists = suite?.object(forKey: interstitialAppsKey) != nil
            if suite == nil || !exists {
                let mirror = UserDefaults.standard.stringArray(forKey: interstitialAppsKey)
                HandoffDiagnostics.record(
                    "app.returnApps.groupReadMissed",
                    detail: "suiteNil=\(suite == nil) mirror=\(mirror?.count ?? -1)"
                )
                if let mirror {
                    return ReturnAppCatalog.sanitizedIDs(mirror)
                }
            }
            return ReturnAppCatalog.resolvedIDs(stored: stored, keyExists: exists)
        }
        set {
            let ids = ReturnAppCatalog.sanitizedIDs(newValue)
            suite?.set(ids, forKey: interstitialAppsKey)
            UserDefaults.standard.set(ids, forKey: interstitialAppsKey)
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
