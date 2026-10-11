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
        try assertLegacyWhisperSelectionSurvivesMigrationAndRelaunch(.default)
    }

    @MainActor
    func testLegacyNonDefaultWhisperSelectionSurvivesMigrationAndRelaunch() throws {
        for model in LocalModel.allCases where model.whisperKitModelID != nil && model != .default {
            try assertLegacyWhisperSelectionSurvivesMigrationAndRelaunch(model)
        }
    }

    @MainActor
    func testUnrelatedParakeetCacheDoesNotOverrideUsableWhisperBase() throws {
        for repoName in ["models--mlx-community--parakeet-tdt-0.6b-v2",
                         "models--other-owner--parakeet-tdt-0.6b-v3",
                         "models--mlx-community--parakeet-tdt-0.6b-v3-backup"] {
            try withIsolatedModelCaches { hub, whisperRepo, defaults in
                let base = whisperRepo.appendingPathComponent("openai_whisper-base")
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                try Data("weights".utf8).write(to: base.appendingPathComponent("weights.bin"))
                try writeParakeetSnapshot(in: hub.appendingPathComponent(repoName))
                assertInitialModel(.whisperBase, defaults: defaults)
            }
        }
    }

    @MainActor
    func testUnrelatedParakeetCacheWithoutWhisperFallsBackToApple() throws {
        try withIsolatedModelCaches { hub, _, defaults in
            try writeParakeetSnapshot(in: hub.appendingPathComponent("models--mlx-community--parakeet-tdt-0.6b-v2"))
            assertInitialModel(.appleSpeech, defaults: defaults)
        }
    }

    @MainActor
    func testIncompleteParakeetV3SnapshotFallsBackToApple() throws {
        for defect in ["missing-config", "missing-weights", "empty-config", "empty-weights",
                       "invalid-config", "broken-weights-link", "weights-directory", "missing-ref",
                       "stale-ref", "unsafe-ref"] {
            try withIsolatedModelCaches { hub, _, defaults in
                let fm = FileManager.default
                let repo = hub.appendingPathComponent("models--mlx-community--parakeet-tdt-0.6b-v3")
                let snapshot = try writeParakeetSnapshot(in: repo)
                let config = snapshot.appendingPathComponent("config.json")
                let weights = snapshot.appendingPathComponent("model.safetensors")
                let ref = repo.appendingPathComponent("refs/main")
                switch defect {
                case "missing-config": try fm.removeItem(at: config)
                case "missing-weights": try fm.removeItem(at: weights)
                case "empty-config": try Data().write(to: config)
                case "empty-weights": try Data().write(to: weights)
                case "invalid-config": try Data("not JSON".utf8).write(to: config)
                case "broken-weights-link":
                    try fm.removeItem(at: weights)
                    try fm.createSymbolicLink(atPath: weights.path, withDestinationPath: "../../blobs/missing")
                case "weights-directory":
                    try fm.removeItem(at: weights)
                    try fm.createDirectory(at: weights, withIntermediateDirectories: true)
                    try Data("weights".utf8).write(to: weights.appendingPathComponent("payload"))
                case "missing-ref": try fm.removeItem(at: ref)
                case "stale-ref": try Data(String(repeating: "b", count: 40).utf8).write(to: ref)
                case "unsafe-ref": try Data("../snapshots/\(snapshot.lastPathComponent)".utf8).write(to: ref)
                default: XCTFail("Unknown fixture defect: \(defect)")
                }
                assertInitialModel(.appleSpeech, defaults: defaults, message: defect)
            }
        }
    }

    @MainActor
    func testCompleteParakeetV3SnapshotSelectsAndPersistsV3() throws {
        for useSymlinks in [false, true] {
            try withIsolatedModelCaches { hub, whisperRepo, defaults in
                let base = whisperRepo.appendingPathComponent("openai_whisper-base")
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                try Data("weights".utf8).write(to: base.appendingPathComponent("weights.bin"))
                let repo = hub.appendingPathComponent("models--mlx-community--parakeet-tdt-0.6b-v3")
                let snapshot = try writeParakeetSnapshot(in: repo)
                if useSymlinks {
                    let blobs = repo.appendingPathComponent("blobs")
                    try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
                    for name in ["config.json", "model.safetensors"] {
                        try FileManager.default.moveItem(at: snapshot.appendingPathComponent(name),
                                                         to: blobs.appendingPathComponent(name))
                        try FileManager.default.createSymbolicLink(atPath: snapshot.appendingPathComponent(name).path,
                                                                   withDestinationPath: "../../blobs/\(name)")
                    }
                }
                assertInitialModel(.parakeetTDT06BV3, defaults: defaults)
            }
        }
    }

    @discardableResult
    private func writeParakeetSnapshot(in repo: URL) throws -> URL {
        let revision = String(repeating: "a", count: 40)
        let snapshot = repo.appendingPathComponent("snapshots/\(revision)")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try Data("\(revision)\n".utf8).write(to: repo.appendingPathComponent("refs/main"))
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        try Data("weights".utf8).write(to: snapshot.appendingPathComponent("model.safetensors"))
        return snapshot
    }

    @MainActor
    private func assertInitialModel(_ model: LocalModel, defaults: UserDefaults, message: String = "",
                                    file: StaticString = #filePath, line: UInt = #line) {
        let store = SettingsStore(defaults: defaults, profileDirectory: directory, apiKeyLookup: { _ in nil })
        XCTAssertEqual(store.selectedLocalModel, model, message, file: file, line: line)
        XCTAssertEqual(defaults.string(forKey: "voice.settings.selectedLocalModel"), model.rawValue,
                       message, file: file, line: line)
    }

    @MainActor
    private func withIsolatedModelCaches(_ body: (URL, URL, UserDefaults) throws -> Void) throws {
        _ = try XCTUnwrap(isTestHost ? true : nil, "Fixtures require the isolated test host")
        let suite = "murmur-parakeet-selection-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let hub = VoicePaths.huggingFaceHubDirectory
        let oldRepo = VoicePaths.legacyWhisperKitDirectory.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
        let newRepo = ModelManager.downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
        let completion = newRepo.deletingLastPathComponent().appendingPathComponent(".whisperkit-coreml-migration-complete")
        let fm = FileManager.default
        for path in [hub, oldRepo, newRepo, completion] {
            XCTAssertTrue(path.path.hasPrefix(VoicePaths.applicationSupportVoiceDirectory.path))
            _ = try XCTUnwrap(fm.fileExists(atPath: path.path) ? nil : true, "Requires an empty isolated cache")
        }
        let previous = RecordingRetention.recordingsDirectoryOverride
        RecordingRetention.recordingsDirectoryOverride = directory
        defer {
            RecordingRetention.recordingsDirectoryOverride = previous
            defaults.removePersistentDomain(forName: suite)
            for path in [hub, newRepo] where fm.fileExists(atPath: path.path) {
                try? fm.removeItem(at: path)
            }
        }
        try body(hub, newRepo, defaults)
    }

    @MainActor
    private func assertLegacyWhisperSelectionSurvivesMigrationAndRelaunch(_ model: LocalModel) throws {
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
        let variantName = try XCTUnwrap(model.whisperKitModelID)
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
        XCTAssertEqual(store.selectedLocalModel, model)
        XCTAssertEqual(defaults.string(forKey: "voice.settings.selectedLocalModel"), model.rawValue)

        ModelManager.migrateWhisperKitModelsIfNeeded(from: oldRepo, to: newRepo)
        XCTAssertFalse(fm.fileExists(atPath: oldRepo.path))
        XCTAssertEqual(try Data(contentsOf: newRepo.appendingPathComponent("\(variantName)/weights.bin")),
                       Data("weights".utf8))

        let reloaded = SettingsStore(defaults: defaults, profileDirectory: directory,
                                     apiKeyLookup: { _ in nil })
        XCTAssertEqual(reloaded.selectedLocalModel, model)
        XCTAssertEqual(defaults.string(forKey: "voice.settings.selectedLocalModel"), model.rawValue)

        defaults.removePersistentDomain(forName: suite)
        let withoutSavedSelection = SettingsStore(defaults: defaults, profileDirectory: directory,
                                                  apiKeyLookup: { _ in nil })
        XCTAssertEqual(withoutSavedSelection.selectedLocalModel, model)
        XCTAssertEqual(defaults.string(forKey: "voice.settings.selectedLocalModel"), model.rawValue)
        let selectedFolder = try XCTUnwrap(ModelManager.modelFolderURL(for: withoutSavedSelection.selectedLocalModel))
        XCTAssertTrue(fm.fileExists(atPath: selectedFolder.appendingPathComponent("weights.bin").path))

        // A completed migration must not make a deleted model look downloaded
        // merely because an old cache remains (the both-caches-present case).
        try fm.copyItem(at: newRepo, to: oldRepo)
        try fm.removeItem(at: newRepo)
        let afterDeletion = SettingsStore(defaults: defaults, profileDirectory: directory,
                                          apiKeyLookup: { _ in nil })
        XCTAssertEqual(afterDeletion.selectedLocalModel, model)
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
                                  apiKeyLookup: { _ in nil }, downloadedLocalModelLookup: { nil })
        XCTAssertEqual(store.selectedLocalModel, .appleSpeech)
        store.useCloudEngine = true
        store.useCloudEngine = false
        let reloaded = SettingsStore(defaults: defaults, profileDirectory: directory,
                                     apiKeyLookup: { _ in nil }, downloadedLocalModelLookup: { nil })
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
