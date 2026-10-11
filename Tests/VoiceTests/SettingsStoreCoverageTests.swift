import XCTest
@testable import Voice

final class SettingsStoreCoverageTests: XCTestCase {
    @MainActor
    private func withStore(_ values: [String: Any] = [:],
                           check: (SettingsStore, UserDefaults) throws -> Void) throws {
        let suite = "murmur.coverage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent(".coverage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = RecordingRetention.recordingsDirectoryOverride
        RecordingRetention.recordingsDirectoryOverride = directory
        defer {
            RecordingRetention.recordingsDirectoryOverride = previous
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        // Skip ModelManager's disk discovery during hydration. Fresh-install
        // local-model decisions already have exhaustive pure-function tests.
        defaults.set(LocalModel.appleSpeech.rawValue, forKey: "voice.settings.selectedLocalModel")
        for (name, value) in values { defaults.set(value, forKey: "voice.settings.\(name)") }
        let store = SettingsStore(defaults: defaults, profileDirectory: directory,
                                  keychain: KeychainStore(service: "com.matt.voice-dictation.apikeys.TESTS"),
                                  apiKeyLookup: { _ in nil })
        try check(store, defaults)
    }

    @MainActor
    func testAbsentPreferencesUseDefaultsWithoutPersistingThem() throws {
        try withStore { store, defaults in
            XCTAssertEqual(store.activationKeyOption, .fnGlobe)
            XCTAssertEqual(store.selectedLocalModel, .appleSpeech)
            XCTAssertEqual(store.selectedCloudModel, .xaiGrokSTT)
            XCTAssertFalse(store.useCloudEngine)
            XCTAssertFalse(store.cleanupEnabled)
            XCTAssertEqual(store.cleanupBackend, .onDevice)
            XCTAssertFalse(store.codeAwareMode)
            XCTAssertFalse(store.playDictationSound)
            XCTAssertFalse(store.allowLastResortInputFallback)
            XCTAssertTrue(store.useStreaming)
            XCTAssertTrue(store.removeFillerWords)
            XCTAssertFalse(store.elevenLabsFilterBackgroundAudio)
            XCTAssertEqual(store.elevenLabsCommitStrategy, .manual)
            XCTAssertEqual(store.elevenLabsVadThreshold, 0.4)
            XCTAssertEqual(store.elevenLabsVadSilenceThresholdSecs, 1.5)
            XCTAssertEqual(store.elevenLabsMinSpeechDurationMs, 100)
            XCTAssertEqual(store.elevenLabsMinSilenceDurationMs, 100)
            XCTAssertEqual(store.geminiVadMode, .manual)
            XCTAssertEqual(store.geminiStartSensitivity, .high)
            XCTAssertEqual(store.geminiEndSensitivity, .high)
            XCTAssertEqual(store.geminiPrefixPaddingMs, 20)
            XCTAssertEqual(store.geminiSilenceDurationMs, 100)
            XCTAssertEqual(store.xaiEndpointingMs, 5000)
            XCTAssertFalse(store.useToggleLock)
            XCTAssertTrue(store.voiceEditSelectedText)
            XCTAssertTrue(store.smartLeadingSpace)
            XCTAssertTrue(store.learnFromInlineCorrections)
            XCTAssertEqual(store.selectedLanguage, "en")
            XCTAssertFalse(store.speakerGatingEnabled)
            XCTAssertEqual(store.speakerGatingSensitivity, .medium)
            XCTAssertEqual(store.recordingBudgetMB, RecordingRetention.defaultBudgetMB)
            XCTAssertNil(store.enrolledVoiceProfile)
            XCTAssertFalse(store.hasCleanupKey)
            for provider in CloudProvider.allCases { XCTAssertFalse(store.hasAPIKey(for: provider)) }
            // Hydration must not fire didSets for absent preferences.
            XCTAssertNil(defaults.object(forKey: "voice.settings.useStreaming"))
            XCTAssertNil(defaults.object(forKey: "voice.settings.cleanupEnabled"))
            XCTAssertNil(defaults.object(forKey: "voice.settings.selectedLanguage"))
        }
    }

    @MainActor
    func testExplicitFalseAndTruePreferencesSurviveHydration() throws {
        let values: [String: Any] = [
            "useStreaming": false, "removeFillerWords": false, "smartLeadingSpace": false,
            "voiceEditSelectedText": false, "learnFromInlineCorrections": false,
            "useCloudEngine": true, "cleanupEnabled": true, "codeAwareMode": true,
            "playDictationSound": true, "allowLastResortInputFallback": true,
            "elevenLabsFilterBackgroundAudio": true, "useToggleLock": true, "speakerGatingEnabled": true
        ]
        try withStore(values) { store, defaults in
            XCTAssertFalse(store.useStreaming)
            XCTAssertFalse(store.removeFillerWords)
            XCTAssertFalse(store.smartLeadingSpace)
            XCTAssertFalse(store.voiceEditSelectedText)
            XCTAssertFalse(store.learnFromInlineCorrections)
            XCTAssertTrue(store.useCloudEngine)
            XCTAssertTrue(store.cleanupEnabled)
            XCTAssertTrue(store.codeAwareMode)
            XCTAssertTrue(store.playDictationSound)
            XCTAssertTrue(store.allowLastResortInputFallback)
            XCTAssertTrue(store.elevenLabsFilterBackgroundAudio)
            XCTAssertTrue(store.useToggleLock)
            XCTAssertTrue(store.speakerGatingEnabled)
            for (name, value) in values {
                XCTAssertEqual(defaults.bool(forKey: "voice.settings.\(name)"), value as? Bool)
            }
        }
    }

    @MainActor
    func testInvalidEnumValuesFallBackDuringHydration() throws {
        let names = ["activationKey", "selectedLocalModel", "selectedCloudModel", "cleanupBackend",
                     "elevenLabsCommitStrategy", "geminiVadMode", "geminiStartSensitivity",
                     "geminiEndSensitivity", "speakerGatingSensitivity"]
        try withStore(Dictionary(uniqueKeysWithValues: names.map { ($0, "retired-value") })) { store, _ in
            XCTAssertEqual(store.activationKeyOption, .fnGlobe)
            XCTAssertEqual(store.selectedLocalModel, .default)
            XCTAssertEqual(store.selectedCloudModel, .xaiGrokSTT)
            XCTAssertEqual(store.cleanupBackend, .onDevice)
            XCTAssertEqual(store.elevenLabsCommitStrategy, .manual)
            XCTAssertEqual(store.geminiVadMode, .manual)
            XCTAssertEqual(store.geminiStartSensitivity, .high)
            XCTAssertEqual(store.geminiEndSensitivity, .high)
            XCTAssertEqual(store.speakerGatingSensitivity, .medium)
        }
    }

    @MainActor
    func testStoredEnumValuesAreHydrated() throws {
        try withStore(["activationKey": "rightOption", "selectedLocalModel": LocalModel.whisperBase.rawValue,
                       "selectedCloudModel": CloudModel.gemini35TranscribeLive.rawValue, "cleanupBackend": "xaiGrok",
                       "elevenLabsCommitStrategy": "vad", "geminiVadMode": "automatic",
                       "geminiStartSensitivity": GeminiStartSensitivity.low.rawValue,
                       "geminiEndSensitivity": GeminiEndSensitivity.low.rawValue,
                       "speakerGatingSensitivity": "high"]) { store, _ in
            XCTAssertEqual(store.activationKeyOption, .rightOption)
            XCTAssertEqual(store.selectedLocalModel, .whisperBase)
            XCTAssertEqual(store.selectedCloudModel, .gemini35TranscribeLive)
            XCTAssertEqual(store.cleanupBackend, .xaiGrok)
            XCTAssertEqual(store.elevenLabsCommitStrategy, .vad)
            XCTAssertEqual(store.geminiVadMode, .automatic)
            XCTAssertEqual(store.geminiStartSensitivity, .low)
            XCTAssertEqual(store.geminiEndSensitivity, .low)
            XCTAssertEqual(store.speakerGatingSensitivity, .high)
        }
    }

    @MainActor
    func testRetiredCloudSelectionsMigrateAndPersist() throws {
        for model in [CloudModel.assemblyAIUniversal3, .deepgramNova3, .openAIGPT4oTranscribe, .groqWhisperLargeV3Turbo] {
            try withStore(["selectedCloudModel": model.rawValue, "useCloudEngine": true]) { store, defaults in
                XCTAssertEqual(store.selectedCloudModel, .xaiGrokSTT)
                XCTAssertTrue(store.useCloudEngine)
                XCTAssertEqual(defaults.string(forKey: "voice.settings.selectedCloudModel"), CloudModel.xaiGrokSTT.rawValue)
            }
        }
    }

    @MainActor
    func testSelectableCloudSelectionsArePreserved() throws {
        for model in CloudModel.selectable {
            try withStore(["selectedCloudModel": model.rawValue]) { store, defaults in
                XCTAssertEqual(store.selectedCloudModel, model)
                XCTAssertEqual(defaults.string(forKey: "voice.settings.selectedCloudModel"), model.rawValue)
            }
        }
    }

    @MainActor
    func testLegacyLanguageTagsMigrateAndPersist() throws {
        for (stored, expected) in [("en-GB", "en"), ("cmn-Hans-CN", "zh"), ("pt-BR", "pt"),
                                   (" fr-FR ", "fr"), ("unknown", "en"), ("ja", "ja")] {
            try withStore(["selectedLanguage": stored]) { store, defaults in
                XCTAssertEqual(store.selectedLanguage, expected)
                XCTAssertEqual(defaults.string(forKey: "voice.settings.selectedLanguage"), expected)
            }
        }
        try withStore(["selectedLanguage": ""]) { store, _ in XCTAssertEqual(store.selectedLanguage, "en") }
    }

    @MainActor
    func testHydrationClampsOutOfRangeNumbersWithoutWritingThemBack() throws {
        for high in [false, true] {
            let value = high ? 10_000 : -10
            try withStore(["elevenLabsVadThreshold": value, "elevenLabsVadSilenceThresholdSecs": value,
                           "elevenLabsMinSpeechDurationMs": value, "elevenLabsMinSilenceDurationMs": value,
                           "geminiPrefixPaddingMs": value, "geminiSilenceDurationMs": value,
                           "xaiEndpointingMs": value, "recordingBudgetMB": value]) { store, defaults in
                XCTAssertEqual(store.elevenLabsVadThreshold, high ? 0.9 : 0.1)
                XCTAssertEqual(store.elevenLabsVadSilenceThresholdSecs, high ? 3 : 0.3)
                XCTAssertEqual(store.elevenLabsMinSpeechDurationMs, high ? 500 : 50)
                XCTAssertEqual(store.elevenLabsMinSilenceDurationMs, high ? 500 : 50)
                XCTAssertEqual(store.geminiPrefixPaddingMs, high ? 500 : 0)
                XCTAssertEqual(store.geminiSilenceDurationMs, high ? 2000 : 0)
                XCTAssertEqual(store.xaiEndpointingMs, high ? 5000 : 500)
                XCTAssertEqual(store.recordingBudgetMB, high ? 1000 : 50)
                XCTAssertEqual(store.recordingBudgetBytes, Int64(store.recordingBudgetMB) * 1024 * 1024)
                XCTAssertEqual(defaults.integer(forKey: "voice.settings.recordingBudgetMB"), value)
                XCTAssertEqual(defaults.integer(forKey: "voice.settings.xaiEndpointingMs"), value)
            }
        }
    }

    @MainActor
    func testStoredZeroIsDistinguishedFromMissingNumericPreference() throws {
        try withStore(["geminiPrefixPaddingMs": 0, "geminiSilenceDurationMs": 0]) { store, _ in
            XCTAssertEqual(store.geminiPrefixPaddingMs, 0)
            XCTAssertEqual(store.geminiSilenceDurationMs, 0)
        }
    }
}
