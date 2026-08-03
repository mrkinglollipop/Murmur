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

    func testTransformsCorruptFileSeedsDefaults() {
        let url = tempFile("transforms-corrupt")
        try? Data("garbage".utf8).write(to: url)
        let store = TransformsStore(fileURL: url)
        XCTAssertFalse(store.transforms.isEmpty, "corrupt file should seed defaults")
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
