import XCTest
@testable import Voice

final class ModelMigrationTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
    }

    private func whisperKitRepo(under base: URL) -> URL {
        base
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
    }

    private func writeUsableVariant(in repo: URL, named name: String, payload: String = "model-bytes") throws {
        let variant = repo.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: variant, withIntermediateDirectories: true)
        let file = variant.appendingPathComponent("weights.bin")
        try Data(payload.utf8).write(to: file)
    }

    func testHappyPath_movesOldRepoToNew() throws {
        let oldBase = root.appendingPathComponent("old-hf", isDirectory: true)
        let newBase = root.appendingPathComponent("new-hf", isDirectory: true)
        let oldRepo = whisperKitRepo(under: oldBase)
        let newRepo = whisperKitRepo(under: newBase)
        try writeUsableVariant(in: oldRepo, named: "openai_whisper-base")

        ModelManager.migrateWhisperKitModelsIfNeeded(from: oldRepo, to: newRepo)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRepo.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newRepo.path))
        XCTAssertTrue(ModelManager.whisperKitRepoHasUsableContent(newRepo))
    }

    func testEmptyNew_fullOld_migrates() throws {
        let oldBase = root.appendingPathComponent("old-hf", isDirectory: true)
        let newBase = root.appendingPathComponent("new-hf", isDirectory: true)
        let oldRepo = whisperKitRepo(under: oldBase)
        let newRepo = whisperKitRepo(under: newBase)
        try writeUsableVariant(in: oldRepo, named: "openai_whisper-base", payload: "from-old")
        try FileManager.default.createDirectory(at: newRepo, withIntermediateDirectories: true)

        ModelManager.migrateWhisperKitModelsIfNeeded(from: oldRepo, to: newRepo)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRepo.path))
        let moved = newRepo
            .appendingPathComponent("openai_whisper-base", isDirectory: true)
            .appendingPathComponent("weights.bin")
        let data = try Data(contentsOf: moved)
        XCTAssertEqual(String(data: data, encoding: .utf8), "from-old")
    }

    func testBothFull_leavesOrphanNewWins() throws {
        let oldBase = root.appendingPathComponent("old-hf", isDirectory: true)
        let newBase = root.appendingPathComponent("new-hf", isDirectory: true)
        let oldRepo = whisperKitRepo(under: oldBase)
        let newRepo = whisperKitRepo(under: newBase)
        try writeUsableVariant(in: oldRepo, named: "openai_whisper-base", payload: "legacy")
        try writeUsableVariant(in: newRepo, named: "openai_whisper-large-v3-turbo", payload: "canonical")

        ModelManager.migrateWhisperKitModelsIfNeeded(from: oldRepo, to: newRepo)

        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRepo.path))
        let oldMarker = try Data(contentsOf: oldRepo
            .appendingPathComponent("openai_whisper-base", isDirectory: true)
            .appendingPathComponent("weights.bin"))
        XCTAssertEqual(String(data: oldMarker, encoding: .utf8), "legacy")
        let newMarker = try Data(contentsOf: newRepo
            .appendingPathComponent("openai_whisper-large-v3-turbo", isDirectory: true)
            .appendingPathComponent("weights.bin"))
        XCTAssertEqual(String(data: newMarker, encoding: .utf8), "canonical")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: newRepo.appendingPathComponent("openai_whisper-base").path
            )
        )
    }

    func testConfigOnlyNew_fullOld_migrates() throws {
        let oldBase = root.appendingPathComponent("old-hf", isDirectory: true)
        let newBase = root.appendingPathComponent("new-hf", isDirectory: true)
        let oldRepo = whisperKitRepo(under: oldBase)
        let newRepo = whisperKitRepo(under: newBase)
        try writeUsableVariant(in: oldRepo, named: "openai_whisper-base", payload: "from-old")
        try FileManager.default.createDirectory(at: newRepo, withIntermediateDirectories: true)
        try Data("{\"hub\":true}".utf8).write(to: newRepo.appendingPathComponent("config.json"))

        ModelManager.migrateWhisperKitModelsIfNeeded(from: oldRepo, to: newRepo)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRepo.path))
        XCTAssertTrue(ModelManager.whisperKitRepoHasUsableContent(newRepo))
        let moved = newRepo
            .appendingPathComponent("openai_whisper-base", isDirectory: true)
            .appendingPathComponent("weights.bin")
        XCTAssertEqual(try String(data: Data(contentsOf: moved), encoding: .utf8), "from-old")
    }

    func testMetadataOnlyVariantNew_fullOld_migrates() throws {
        let oldBase = root.appendingPathComponent("old-hf", isDirectory: true)
        let newBase = root.appendingPathComponent("new-hf", isDirectory: true)
        let oldRepo = whisperKitRepo(under: oldBase)
        let newRepo = whisperKitRepo(under: newBase)
        try writeUsableVariant(in: oldRepo, named: "openai_whisper-base", payload: "from-old")
        let skeleton = newRepo.appendingPathComponent("openai_whisper-base", isDirectory: true)
        try FileManager.default.createDirectory(at: skeleton, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: skeleton.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: skeleton.appendingPathComponent("generation_config.json"))
        try Data("{}".utf8).write(to: skeleton.appendingPathComponent("tokenizer.json"))

        ModelManager.migrateWhisperKitModelsIfNeeded(from: oldRepo, to: newRepo)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRepo.path))
        let moved = newRepo
            .appendingPathComponent("openai_whisper-base", isDirectory: true)
            .appendingPathComponent("weights.bin")
        XCTAssertEqual(try String(data: Data(contentsOf: moved), encoding: .utf8), "from-old")
    }

    func testEmptyMlmodelcShellNew_fullOld_migrates() throws {
        let oldBase = root.appendingPathComponent("old-hf", isDirectory: true)
        let newBase = root.appendingPathComponent("new-hf", isDirectory: true)
        let oldRepo = whisperKitRepo(under: oldBase)
        let newRepo = whisperKitRepo(under: newBase)
        try writeUsableVariant(in: oldRepo, named: "openai_whisper-base", payload: "from-old")
        let shell = newRepo
            .appendingPathComponent("openai_whisper-base", isDirectory: true)
            .appendingPathComponent("AudioEncoder.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: shell, withIntermediateDirectories: true)

        ModelManager.migrateWhisperKitModelsIfNeeded(from: oldRepo, to: newRepo)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRepo.path))
        let moved = newRepo
            .appendingPathComponent("openai_whisper-base", isDirectory: true)
            .appendingPathComponent("weights.bin")
        XCTAssertEqual(try String(data: Data(contentsOf: moved), encoding: .utf8), "from-old")
    }

    func testTokenizerModelSidecarNew_fullOld_migrates() throws {
        let oldBase = root.appendingPathComponent("old-hf", isDirectory: true)
        let newBase = root.appendingPathComponent("new-hf", isDirectory: true)
        let oldRepo = whisperKitRepo(under: oldBase)
        let newRepo = whisperKitRepo(under: newBase)
        try writeUsableVariant(in: oldRepo, named: "openai_whisper-base", payload: "from-old")
        let skeleton = newRepo.appendingPathComponent("openai_whisper-base", isDirectory: true)
        try FileManager.default.createDirectory(at: skeleton, withIntermediateDirectories: true)
        try Data("spm".utf8).write(to: skeleton.appendingPathComponent("tokenizer.model"))
        try Data("{}".utf8).write(to: skeleton.appendingPathComponent("config.json"))

        ModelManager.migrateWhisperKitModelsIfNeeded(from: oldRepo, to: newRepo)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRepo.path))
        let moved = newRepo
            .appendingPathComponent("openai_whisper-base", isDirectory: true)
            .appendingPathComponent("weights.bin")
        XCTAssertEqual(try String(data: Data(contentsOf: moved), encoding: .utf8), "from-old")
    }

    func testPopulatedMlmodelcCountsAsUsable() throws {
        let repo = whisperKitRepo(under: root.appendingPathComponent("hf", isDirectory: true))
        let bundle = repo
            .appendingPathComponent("openai_whisper-base", isDirectory: true)
            .appendingPathComponent("AudioEncoder.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("coreml".utf8).write(to: bundle.appendingPathComponent("coremldata.bin"))

        XCTAssertTrue(ModelManager.whisperKitRepoHasUsableContent(repo))
    }

    func testEmptyVariantFolderNew_fullOld_migrates() throws {
        let oldBase = root.appendingPathComponent("old-hf", isDirectory: true)
        let newBase = root.appendingPathComponent("new-hf", isDirectory: true)
        let oldRepo = whisperKitRepo(under: oldBase)
        let newRepo = whisperKitRepo(under: newBase)
        try writeUsableVariant(in: oldRepo, named: "openai_whisper-base", payload: "from-old")
        let emptyVariant = newRepo.appendingPathComponent("openai_whisper-base", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyVariant, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: emptyVariant.appendingPathComponent("config.json"))

        ModelManager.migrateWhisperKitModelsIfNeeded(from: oldRepo, to: newRepo)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRepo.path))
        let moved = newRepo
            .appendingPathComponent("openai_whisper-base", isDirectory: true)
            .appendingPathComponent("weights.bin")
        XCTAssertEqual(try String(data: Data(contentsOf: moved), encoding: .utf8), "from-old")
    }

    func testSiblingOpenAIVendorUntouched() throws {
        let oldBase = root.appendingPathComponent("old-hf", isDirectory: true)
        let newBase = root.appendingPathComponent("new-hf", isDirectory: true)
        let oldRepo = whisperKitRepo(under: oldBase)
        let newRepo = whisperKitRepo(under: newBase)
        try writeUsableVariant(in: oldRepo, named: "openai_whisper-base")

        let openaiSibling = oldBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("openai", isDirectory: true)
            .appendingPathComponent("whisper-tiny", isDirectory: true)
        try FileManager.default.createDirectory(at: openaiSibling, withIntermediateDirectories: true)
        let siblingFile = openaiSibling.appendingPathComponent("config.json")
        try Data("{\"ok\":true}".utf8).write(to: siblingFile)

        ModelManager.migrateWhisperKitModelsIfNeeded(from: oldRepo, to: newRepo)

        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRepo.path))
        XCTAssertTrue(ModelManager.whisperKitRepoHasUsableContent(newRepo))
    }
}
