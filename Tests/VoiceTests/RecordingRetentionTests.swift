import XCTest
@testable import Voice

final class RecordingRetentionTests: XCTestCase {

    private var tempRoot: URL!
    private var recordingsDir: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-retention-\(UUID().uuidString)", isDirectory: true)
        recordingsDir = tempRoot.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        RecordingRetention.recordingsDirectoryOverride = recordingsDir
    }

    override func tearDown() {
        RecordingRetention.recordingsDirectoryOverride = nil
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func writeTempSource(named name: String, bytes: Int) -> URL {
        let url = tempRoot.appendingPathComponent(name)
        let data = Data(repeating: 0xAB, count: bytes)
        try! data.write(to: url)
        return url
    }

    private func touch(_ url: URL, age: TimeInterval) {
        let date = Date().addingTimeInterval(-age)
        try? FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }

    func testRetainCopiesAndRespectsCountLimit() {
        for i in 0 ..< 7 {
            let src = writeTempSource(named: "src-\(i).caf", bytes: 100)
            let retained = RecordingRetention.retain(
                from: src,
                maxCount: 5,
                maxBytes: 10_000_000
            )
            XCTAssertNotNil(retained)
            // Stagger mtimes so prune order is deterministic.
            if let retained {
                touch(retained, age: TimeInterval(7 - i) * 60)
            }
        }
        XCTAssertEqual(RecordingRetention.fileCount(), 5)
    }

    func testBudgetPrunesOldestUnprotected() {
        var urls: [URL] = []
        for i in 0 ..< 4 {
            let src = writeTempSource(named: "budget-\(i).caf", bytes: 1_000)
            guard let retained = RecordingRetention.retain(
                from: src,
                maxCount: 10,
                maxBytes: 10_000_000
            ) else {
                XCTFail("retain failed")
                return
            }
            touch(retained, age: TimeInterval(4 - i) * 120)
            urls.append(retained)
        }

        // 4 × 1000 = 4000 bytes → budget 2500 should drop oldest until under.
        RecordingRetention.pruneNow(maxCount: 10, maxBytes: 2_500)
        let remaining = RecordingRetention.fileCount()
        XCTAssertLessThanOrEqual(RecordingRetention.usageBytes(), 2_500)
        XCTAssertLessThan(remaining, 4)
        // Newest should survive.
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[3].path))
    }

    func testProtectedPathsSurviveBudgetPrune() {
        let srcA = writeTempSource(named: "prot-a.caf", bytes: 2_000)
        let srcB = writeTempSource(named: "prot-b.caf", bytes: 2_000)
        guard
            let a = RecordingRetention.retain(from: srcA, maxCount: 10, maxBytes: 10_000_000),
            let b = RecordingRetention.retain(from: srcB, maxCount: 10, maxBytes: 10_000_000)
        else {
            XCTFail("retain failed")
            return
        }
        touch(a, age: 300)
        touch(b, age: 60)

        RecordingRetention.pruneNow(keepPaths: [a.path], maxCount: 10, maxBytes: 2_500)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path), "protected file must survive")
    }

    func testExportZipPackagesAudioAndTranscripts() throws {
        let src = writeTempSource(named: "export-me.caf", bytes: 512)
        guard let retained = RecordingRetention.retain(
            from: src,
            maxCount: 5,
            maxBytes: 10_000_000
        ) else {
            XCTFail("retain failed")
            return
        }

        let entry = HistoryEntry(
            text: "hello export world",
            engine: "test",
            injected: true,
            audioPath: retained.path,
            failed: false
        )
        let dest = tempRoot.appendingPathComponent("out.zip")
        let count = try RecordingRetention.exportZip(to: dest, historyEntries: [entry])
        XCTAssertEqual(count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.intValue ?? 0, 0)
    }

    func testExportNothingThrows() {
        XCTAssertThrowsError(
            try RecordingRetention.exportZip(to: tempRoot.appendingPathComponent("empty.zip"), historyEntries: [])
        ) { error in
            XCTAssertEqual(error as? RecordingRetention.ExportError, .nothingToExport)
        }
    }
}
