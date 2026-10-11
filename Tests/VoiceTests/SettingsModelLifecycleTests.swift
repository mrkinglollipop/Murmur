import XCTest
@testable import Voice

final class SettingsModelLifecycleTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-model-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor
    func testLegacyDefaultWhisperSelectionSurvivesMigrationAndRelaunch() throws {
        let suite = "murmur-model-upgrade-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let oldRepo = VoicePaths.legacyWhisperKitDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
        let newRepo = ModelManager.downloadBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
        let completion = newRepo.deletingLastPathComponent()
            .appendingPathComponent(".whisperkit-coreml-migration-complete")
        let fm = FileManager.default
        for path in [oldRepo, newRepo, completion, VoicePaths.huggingFaceHubDirectory] {
            XCTAssertTrue(path.path.hasPrefix(VoicePaths.applicationSupportVoiceDirectory.path))
            _ = try XCTUnwrap(fm.fileExists(atPath: path.path) ? nil : true,
                              "Requires an empty isolated model cache: \(path.path)")
        }
        let previous = RecordingRetention.recordingsDirectoryOverride
        RecordingRetention.recordingsDirectoryOverride = directory
        defer {
            RecordingRetention.recordingsDirectoryOverride = previous
            defaults.removePersistentDomain(forName: suite)
            for path in [oldRepo, newRepo, completion] where fm.fileExists(atPath: path.path) {
                try? fm.removeItem(at: path)
            }
        }
        let variantName = try XCTUnwrap(LocalModel.default.whisperKitModelID)
        let variant = oldRepo.appendingPathComponent(variantName)
        try fm.createDirectory(at: variant, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: variant.appendingPathComponent("config.json"))
        let metadataOnly = SettingsStore(defaults: defaults, profileDirectory: directory,
                                         apiKeyLookup: { _ in nil })
        XCTAssertEqual(metadataOnly.selectedLocalModel, .appleSpeech)
        try Data("weights".utf8).write(to: variant.appendingPathComponent("weights.bin"))

        let explicitApple = SettingsStore(defaults: defaults, profileDirectory: directory,
                                          apiKeyLookup: { _ in nil })
        XCTAssertEqual(explicitApple.selectedLocalModel, .appleSpeech)
        defaults.removePersistentDomain(forName: suite)

        // Use the production cache lookup before the manager's launch-time migration.
        let store = SettingsStore(defaults: defaults, profileDirectory: directory,
                                  apiKeyLookup: { _ in nil })
        XCTAssertEqual(store.selectedLocalModel, .default)
        XCTAssertEqual(defaults.string(forKey: "voice.settings.selectedLocalModel"), LocalModel.default.rawValue)

        ModelManager.migrateWhisperKitModelsIfNeeded(from: oldRepo, to: newRepo)
        XCTAssertFalse(fm.fileExists(atPath: oldRepo.path))
        XCTAssertEqual(try Data(contentsOf: newRepo.appendingPathComponent("\(variantName)/weights.bin")),
                       Data("weights".utf8))

        let reloaded = SettingsStore(defaults: defaults, profileDirectory: directory,
                                     apiKeyLookup: { _ in nil })
        XCTAssertEqual(reloaded.selectedLocalModel, .default)
        XCTAssertEqual(defaults.string(forKey: "voice.settings.selectedLocalModel"), LocalModel.default.rawValue)

        // A completed migration must not make a deleted model look downloaded
        // merely because an old cache remains (the both-caches-present case).
        try fm.copyItem(at: newRepo, to: oldRepo)
        try fm.removeItem(at: newRepo)
        let afterDeletion = SettingsStore(defaults: defaults, profileDirectory: directory,
                                          apiKeyLookup: { _ in nil })
        XCTAssertEqual(afterDeletion.selectedLocalModel, .default)
        defaults.removePersistentDomain(forName: suite)
        let fresh = SettingsStore(defaults: defaults, profileDirectory: directory,
                                  apiKeyLookup: { _ in nil })
        XCTAssertEqual(fresh.selectedLocalModel, .appleSpeech)
        XCTAssertEqual(defaults.string(forKey: "voice.settings.selectedLocalModel"), LocalModel.appleSpeech.rawValue)
    }

    @MainActor
    func testFreshAppleSelectionSurvivesCloudToggleAndRelaunch() throws {
        let suite = "murmur-model-lifecycle-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let previous = RecordingRetention.recordingsDirectoryOverride
        RecordingRetention.recordingsDirectoryOverride = directory
        defer {
            RecordingRetention.recordingsDirectoryOverride = previous
            defaults.removePersistentDomain(forName: suite)
        }
        let store = SettingsStore(defaults: defaults, profileDirectory: directory,
                                  apiKeyLookup: { _ in nil }, downloadedLocalModelLookup: { false })
        XCTAssertEqual(store.selectedLocalModel, .appleSpeech)
        store.useCloudEngine = true
        store.useCloudEngine = false
        let reloaded = SettingsStore(defaults: defaults, profileDirectory: directory,
                                     apiKeyLookup: { _ in nil }, downloadedLocalModelLookup: { false })
        XCTAssertEqual(reloaded.selectedLocalModel, .appleSpeech)
    }

    func testDeletingLastCurrentModelDoesNotReimportLegacyCache() throws {
        let oldRepo = directory.appendingPathComponent("old/argmaxinc/whisperkit-coreml")
        let newRepo = directory.appendingPathComponent("new/argmaxinc/whisperkit-coreml")
        for repo in [oldRepo, newRepo] {
            let variant = repo.appendingPathComponent("openai_whisper-base")
            try FileManager.default.createDirectory(at: variant, withIntermediateDirectories: true)
            try Data("weights".utf8).write(to: variant.appendingPathComponent("weights.bin"))
        }
        ModelManager.migrateWhisperKitModelsIfNeeded(from: oldRepo, to: newRepo)
        try FileManager.default.removeItem(at: newRepo.appendingPathComponent("openai_whisper-base"))
        ModelManager.migrateWhisperKitModelsIfNeeded(from: oldRepo, to: newRepo)
        XCTAssertFalse(ModelManager.whisperKitRepoHasUsableContent(newRepo))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRepo.path))
        try FileManager.default.removeItem(at: newRepo)
        ModelManager.migrateWhisperKitModelsIfNeeded(from: oldRepo, to: newRepo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newRepo.path))
    }

    func testWhisperModelCachePreparationExcludesBackups() throws {
        let cache = directory.appendingPathComponent("Voice/Models")
        try VoicePaths.prepareModelCacheDirectory(cache)
        XCTAssertEqual(try cache.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testFluidAudioModelCachePreparationExcludesBackups() throws {
        let cache = directory.appendingPathComponent("FluidAudio/Models")
        try FluidAudioEmbeddingProvider.prepareModelCacheDirectory(cache)
        XCTAssertEqual(try cache.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testExistingModelCachePreparationRepairsBackupEligibilityWithoutDeletingPayload() throws {
        var cache = directory.appendingPathComponent("existing/Models")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let payload = cache.appendingPathComponent("weights.bin")
        try Data("weights".utf8).write(to: payload)
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try cache.setResourceValues(values)
        try VoicePaths.prepareModelCacheDirectory(cache)
        let refreshed = URL(fileURLWithPath: cache.path)
        XCTAssertEqual(try refreshed.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try Data(contentsOf: payload), Data("weights".utf8))
    }
}
