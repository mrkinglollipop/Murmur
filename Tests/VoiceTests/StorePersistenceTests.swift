import XCTest
@testable import Voice

/// Debounced store persistence — always use temp fileURLs (never production App Support).
final class StorePersistenceTests: XCTestCase {

    private var tempURLs: [URL] = []

    override func tearDown() {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        super.tearDown()
    }

    private func tempFile(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-test-\(name)-\(UUID().uuidString).json")
        tempURLs.append(url)
        return url
    }

    // MARK: - HistoryStore

    @MainActor
    func testAppendCanMarkNewRowSavedWithoutInsertion() {
        let store = HistoryStore(fileURL: tempFile("abandoned-row"))
        store.append(text: "late result", engine: "test", injected: false, savedWithoutInsertion: true)
        XCTAssertEqual(store.entries.first?.savedWithoutInsertion, true)
        store.append(text: "normal", engine: "test", injected: false)
        XCTAssertEqual(store.entries.first?.savedWithoutInsertion, false)
    }

    func testFailedRetryPreservesSuccessfulTranscriptAndProvenance() {
        let store = HistoryStore(fileURL: tempFile("failed-retry"))
        store.append(text: "Keep the original words.", engine: "original", injected: true)
        let original = store.entries[0]
        store.append(text: "", engine: "retry", injected: false, failed: true, replaceEntryID: original.id)
        XCTAssertEqual(store.entries[0], original)
    }

    @MainActor
    func testSuccessfulRetryPersistsHistoryOnlyStatus() {
        let url = tempFile("successful-retry")
        let store = HistoryStore(fileURL: url)
        store.append(text: "Earlier words.", engine: "original", injected: true)
        let id = store.entries[0].id
        store.append(text: "Recovered final words.", engine: "retry", injected: false, replaceEntryID: id)
        let entry = HistoryStore(fileURL: url).entries[0]
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.text, "Recovered final words.")
        XCTAssertFalse(entry.failed)
        XCTAssertFalse(entry.injected)
        XCTAssertTrue(entry.savedWithoutInsertion)
    }

    @MainActor
    func testHistoryRetryCompletionSavesWithoutInsertionOrHeldContext() async {
        let pipeline = TranscriptionPipeline()
        let id = UUID()
        let finished = expectation(description: "retry saved")
        pipeline.onTextInserted = { _ in XCTFail("History retry must not type into a focused app") }
        pipeline.onTranscriptionLogged = { text, engine, injected, audio, failed, replacement in
            XCTAssertEqual(text, "Recover all the missing words.")
            XCTAssertEqual(replacement, id)
            XCTAssertFalse(injected)
            XCTAssertFalse(failed)
        }
        pipeline.finishTranscription(
            text: "Recover all the missing words", hadExplicitTrailingNewline: false,
            engineID: "test", audioPath: nil, replaceHistoryEntryID: id,
            sessionHeldToken: 0, sessionHeldSnapshot: nil, sessionHeldFrontmostPID: nil
        ) { result in
            XCTAssertEqual(result, .savedToHistory)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)
    }

    @MainActor
    func testFailedAudioProtectionSnapshotUpdatesAfterRetry() {
        let audio = tempFile("retained-audio")
        try? Data([0]).write(to: audio)
        let store = HistoryStore(fileURL: tempFile("protected-snapshot"))
        store.append(text: "", engine: "test", injected: false, audioPath: audio.path, failed: true)
        XCTAssertEqual(store.protectedAudioPathsSnapshot(), [audio.path])
        store.append(text: "Recovered.", engine: "retry", injected: false,
                     audioPath: audio.path, replaceEntryID: store.entries[0].id)
        XCTAssertEqual(store.protectedAudioPathsSnapshot(), [])
    }

    func testHistoryRoundTripAfterFlush() {
        let url = tempFile("history")
        let store = HistoryStore(fileURL: url)
        store.append(text: "hello world", engine: "test", injected: true)
        store.flush()
        let reloaded = HistoryStore(fileURL: url)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.text, "hello world")
    }

    func testHistoryDebounceDefersUntilFlush() {
        let url = tempFile("history-debounce")
        let store = HistoryStore(fileURL: url)
        store.append(text: "kept", engine: "test", injected: true)
        store.flush()
        let before = try? Data(contentsOf: url)
        store.updateText(id: store.entries[0].id, newText: "edited")
        let mid = try? Data(contentsOf: url)
        XCTAssertEqual(mid, before, "debounced update should not rewrite file yet")
        store.flush()
        let after = HistoryStore(fileURL: url)
        XCTAssertEqual(after.entries.first?.text, "edited")
    }

    func testHistoryCorruptFileLoadsEmpty() {
        let url = tempFile("history-corrupt")
        try? Data("not-json".utf8).write(to: url)
        let store = HistoryStore(fileURL: url)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testHistoryCapsAt1000() {
        let url = tempFile("history-cap")
        let store = HistoryStore(fileURL: url)
        for i in 0..<1001 {
            store.append(text: "entry \(i)", engine: "test", injected: true)
        }
        XCTAssertEqual(store.entries.count, 1000)
    }

    // MARK: - SnippetsStore

    func testSnippetsRoundTripAfterFlush() {
        let url = tempFile("snippets")
        let store = SnippetsStore(fileURL: url)
        store.add(trigger: "sig", expansion: "Best regards")
        store.flush()
        let reloaded = SnippetsStore(fileURL: url)
        XCTAssertEqual(reloaded.snippets.count, 1)
        XCTAssertEqual(reloaded.snippets.first?.trigger, "sig")
    }

    func testSnippetsDebounceDefersUntilFlush() {
        let url = tempFile("snippets-debounce")
        let store = SnippetsStore(fileURL: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        store.add(trigger: "x", expansion: "y")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testSnippetsCorruptFileLoadsEmpty() {
        let url = tempFile("snippets-corrupt")
        try? Data("nope".utf8).write(to: url)
        let store = SnippetsStore(fileURL: url)
        XCTAssertTrue(store.snippets.isEmpty)
    }

    // MARK: - TransformsStore

    func testTransformsRoundTripAfterFlush() {
        let url = tempFile("transforms")
        // Avoid seeding defaults: start with empty file content that decodes
        try? Data("[]".utf8).write(to: url)
        let store = TransformsStore(fileURL: url)
        store.add(name: "Tighten", prompt: "Be shorter")
        store.flush()
        let reloaded = TransformsStore(fileURL: url)
        XCTAssertTrue(reloaded.transforms.contains { $0.name == "Tighten" })
    }

    func testTransformsDebounceDefersUntilFlush() {
        let url = tempFile("transforms-debounce")
        try? Data("[]".utf8).write(to: url)
        let store = TransformsStore(fileURL: url)
        let before = try? Data(contentsOf: url)
        store.add(name: "A", prompt: "B")
        let mid = try? Data(contentsOf: url)
        XCTAssertEqual(mid, before)
        store.flush()
        let after = TransformsStore(fileURL: url)
        XCTAssertTrue(after.transforms.contains { $0.name == "A" })
    }

    func testTransformsMissingFileSeedsDefaults() {
        let store = TransformsStore(fileURL: tempFile("transforms-missing"))
        XCTAssertFalse(store.transforms.isEmpty, "first run should seed defaults")
    }

    func testTransformsCorruptFileIsQuarantinedNotSeeded() throws {
        let url = tempFile("transforms-corrupt")
        try Data("garbage".utf8).write(to: url)
        let store = TransformsStore(fileURL: url)
        XCTAssertTrue(store.transforms.isEmpty, "corrupt file must not be replaced by seed data")
        let quarantined = try FileManager.default
            .contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(url.lastPathComponent + ".corrupt.") }
        XCTAssertEqual(quarantined.count, 1)
        for name in quarantined {
            tempURLs.append(url.deletingLastPathComponent().appendingPathComponent(name))
        }
    }

    /// Unreadable-but-present file: the store must not overwrite it.
    func testTransformsUnreadableFileIsNeverOverwritten() throws {
        let url = tempFile("transforms-unreadable")
        let original = Data(#"[{"id":"\#(UUID().uuidString)","name":"Mine","prompt":"keep"}]"#.utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        try XCTSkipIf((try? Data(contentsOf: url)) != nil, "file readable despite 0o000 (root?)")

        let store = TransformsStore(fileURL: url)
        XCTAssertTrue(store.transforms.isEmpty)
        store.add(name: "New", prompt: "x")
        store.flush()

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testHistoryUnreadableFileIsNeverOverwritten() throws {
        let url = tempFile("history-unreadable")
        let seed = HistoryStore(fileURL: url)
        seed.append(text: "precious", engine: "test", injected: true)
        seed.flush()
        let original = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        try XCTSkipIf((try? Data(contentsOf: url)) != nil, "file readable despite 0o000 (root?)")

        let store = HistoryStore(fileURL: url)
        XCTAssertTrue(store.entries.isEmpty)
        store.append(text: "new", engine: "test", injected: true)
        store.flush()

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor
    func testHistoryCapDeletesOnlyUnreferencedDroppedAudio() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-history-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempURLs.append(directory)
        let droppedAudio = directory.appendingPathComponent("dropped.caf")
        let sharedAudio = directory.appendingPathComponent("shared.caf")
        let newestAudio = directory.appendingPathComponent("newest.caf")
        for audio in [droppedAudio, sharedAudio, newestAudio] { try Data([0]).write(to: audio) }
        var entries = (0..<998).map { HistoryEntry(text: "row \($0)", engine: "test", injected: true) }
        entries[0].audioPath = sharedAudio.path
        entries.append(HistoryEntry(text: "old shared", engine: "test", injected: true, audioPath: sharedAudio.path))
        entries.append(HistoryEntry(text: "", engine: "test", injected: false, audioPath: droppedAudio.path, failed: true))
        let file = directory.appendingPathComponent("history.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: file)
        let store = HistoryStore(fileURL: file)
        store.append(text: "newest", engine: "test", injected: true, audioPath: newestAudio.path)
        XCTAssertEqual(store.entries.count, 1000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: droppedAudio.path))
        XCTAssertFalse(store.protectedAudioPathsSnapshot().contains(droppedAudio.path))
        store.append(text: "another", engine: "test", injected: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedAudio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newestAudio.path))
        XCTAssertEqual(HistoryStore(fileURL: file).entries.count, 1000)
    }

    func testHistoryDeleteRemovesRetainedAudioFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-test-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempURLs.append(dir)
        let audio = dir.appendingPathComponent("clip.wav")
        let other = dir.appendingPathComponent("other.wav")
        try Data([0]).write(to: audio)
        try Data([0]).write(to: other)

        let store = HistoryStore(fileURL: dir.appendingPathComponent("history.json"))
        store.append(text: "one", engine: "test", injected: true, audioPath: audio.path)
        store.append(text: "two", engine: "test", injected: true, audioPath: other.path)
        let id = try XCTUnwrap(store.entries.first { $0.audioPath == audio.path }?.id)

        store.delete(id: id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertEqual(store.entries.count, 1)
    }

    func testEditingSelectedTransformUpdatesTheLivePipelineBeforeSave() throws {
        let key = "voice.settings.autoRunTransformID"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let url = tempFile("live-transform")
        try Data("[]".utf8).write(to: url)
        let store = TransformsStore(fileURL: url)
        let selector = ASREngineSelector()
        store.asrEngineSelector = selector
        store.add(name: "Polish", prompt: "Old instruction")
        var transform = try XCTUnwrap(store.transforms.first)
        store.autoRunTransformID = transform.id
        XCTAssertEqual(selector.autoRunTransform?.prompt, "Old instruction")
        transform.prompt = "Updated instruction"
        store.update(transform)
        XCTAssertEqual(selector.autoRunTransform?.prompt, "Updated instruction")
        store.flush()
    }

    // MARK: - DictionaryStore

    func testDictionaryRoundTripAfterFlush() {
        let url = tempFile("dictionary")
        let store = DictionaryStore(fileURL: url)
        store.add(term: "Murmur", variants: ["murmer"])
        store.flush()
        let reloaded = DictionaryStore(fileURL: url)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.term, "Murmur")
    }

    func testDictionaryDebounceDefersUntilFlush() {
        let url = tempFile("dictionary-debounce")
        let store = DictionaryStore(fileURL: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        store.add(term: "X", variants: ["y"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testDictionaryCorruptFileLoadsEmpty() {
        let url = tempFile("dictionary-corrupt")
        try? Data("bad".utf8).write(to: url)
        let store = DictionaryStore(fileURL: url)
        XCTAssertTrue(store.entries.isEmpty)
    }
}
