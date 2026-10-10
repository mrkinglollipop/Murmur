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

    /// The size budget is the governor, not the file count. This used to be
    /// false: a hardcoded 5-file cap bound long before any MB option could, so
    /// the Settings picker was decoration.
    func testBudgetGovernsRatherThanFileCount() {
        for i in 0 ..< 12 {
            let src = writeTempSource(named: "governor-\(i).caf", bytes: 1_000)
            let retained = RecordingRetention.retain(
                from: src,
                maxCount: RecordingRetention.runawayFileCeiling,
                maxBytes: 10_000_000
            )
            XCTAssertNotNil(retained)
            if let retained {
                touch(retained, age: TimeInterval(12 - i) * 60)
            }
        }
        // Well past the old 5-file ring, comfortably inside the byte budget.
        XCTAssertEqual(RecordingRetention.fileCount(), 12)
    }

    func testRunawayCeilingIsNotTheUserFacingLimit() {
        XCTAssertGreaterThan(
            RecordingRetention.runawayFileCeiling,
            1_000,
            "ceiling must sit far above anything a budget option can hold"
        )
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

    func testRetainAssignsUniquePathsForSameSourceName() {
        let firstSource = writeTempSource(named: "same-name.caf", bytes: 128)
        let secondDirectory = tempRoot.appendingPathComponent("other", isDirectory: true)
        try! FileManager.default.createDirectory(
            at: secondDirectory,
            withIntermediateDirectories: true
        )
        let secondSource = secondDirectory.appendingPathComponent("same-name.caf")
        try! Data(repeating: 0xCD, count: 256).write(to: secondSource)

        let first = RecordingRetention.retain(from: firstSource, maxCount: 10, maxBytes: 10_000)
        let second = RecordingRetention.retain(from: secondSource, maxCount: 10, maxBytes: 10_000)

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first?.path, second?.path)
        XCTAssertEqual(RecordingRetention.fileCount(), 2)
        XCTAssertEqual(TranscriptionPipeline.streamedAudioPath(first), first?.path)
    }

    func testRetainReturnsNilWhenBudgetImmediatelyPrunesNewFile() {
        let source = writeTempSource(named: "too-large.caf", bytes: 512)
        let retained = RecordingRetention.retain(from: source, maxCount: 10, maxBytes: 1)

        XCTAssertNil(retained)
        XCTAssertEqual(RecordingRetention.fileCount(), 0)
        XCTAssertNil(TranscriptionPipeline.streamedAudioPath(retained))
    }

    func testRecordingsDirectoryIsExcludedFromBackup() throws {
        let directory = RecordingRetention.recordingsDirectory
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testOversizedCaptureUsesTempUntilSuccessfulTranscriptionFinishes() throws {
        try checkUnretainedCapture(failed: false, protectExisting: false)
    }

    func testProtectedBudgetUsesTempUntilFailedTranscriptionFinishes() throws {
        try checkUnretainedCapture(failed: true, protectExisting: true)
    }

    private func checkUnretainedCapture(failed: Bool, protectExisting: Bool) throws {
        let source = writeTempSource(named: "fallback.caf", bytes: protectExisting ? 128 : 512)
        let protectedSource = writeTempSource(named: "protected.caf", bytes: 512)
        let protectedURL = protectExisting
            ? try XCTUnwrap(RecordingRetention.retain(from: protectedSource, maxBytes: 1024))
            : nil
        let pipeline = TranscriptionPipeline()
        pipeline.markHoldAbandoned(42)
        let history = HistoryStore(fileURL: tempRoot.appendingPathComponent("history.json"))
        let finished = expectation(description: "transcription completed")
        pipeline.onTranscriptionLogged = { text, engine, injected, audioPath, failed, _ in
            history.append(text: text, engine: engine, injected: injected, audioPath: audioPath, failed: failed)
        }
        RecordingRetention.handoffForTranscription(
            from: source, keepPaths: protectedURL.map { [$0.path] } ?? [], maxBytes: 256
        ) { audioURL, retainedURL, cleanup in
            XCTAssertEqual(audioURL, source)
            XCTAssertNil(retainedURL)
            XCTAssertEqual(try? Data(contentsOf: audioURL), Data(repeating: 0xAB, count: protectExisting ? 128 : 512))
            pipeline.finishTranscription(
                text: failed ? "" : "Recovered all the words.", hadExplicitTrailingNewline: false,
                engineID: "test", audioPath: TranscriptionPipeline.historyAudioPath(
                    audioURL: audioURL, audioIsTemporary: retainedURL == nil
                ), replaceHistoryEntryID: nil, sessionHeldToken: 42,
                sessionHeldSnapshot: nil, sessionHeldFrontmostPID: nil
            ) { result in
                XCTAssertEqual(result, failed ? .failed : .savedToHistory)
                XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
                cleanup()
                XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
                finished.fulfill()
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
        wait(for: [finished], timeout: 2)
        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertNil(entry.audioPath)
        XCTAssertEqual(entry.failed, failed)
        XCTAssertEqual(entry.text, failed ? HistoryEntry.failedPlaceholderText : "Recovered all the words.")
        if let protectedURL { XCTAssertTrue(FileManager.default.fileExists(atPath: protectedURL.path)) }
    }

    func testRetainedHandoffPreservesHistoryAudioAfterTempCleanup() throws {
        let source = writeTempSource(named: "retained.caf", bytes: 128)
        RecordingRetention.handoffForTranscription(from: source, maxBytes: 1024) { audioURL, retainedURL, cleanup in
            XCTAssertEqual(audioURL, retainedURL)
            XCTAssertNotEqual(audioURL, source)
            XCTAssertEqual(TranscriptionPipeline.historyAudioPath(audioURL: audioURL, audioIsTemporary: false), audioURL.path)
            cleanup()
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        }
    }

    func testDoNotLogOutcomesRemoveRetainedAudio() throws {
        for (secureInput, insertResult) in [(true, TextInjector.InsertResult.failed), (false, .deduped)] {
            let source = writeTempSource(named: "unlogged.caf", bytes: 128)
            let retained = try XCTUnwrap(RecordingRetention.retain(from: source, maxBytes: 1024))
            let outcome = TranscriptionPipeline.secureInputOutcome(secureInput: secureInput, insertResult: insertResult)
            XCTAssertFalse(outcome.shouldLog)
            TranscriptionPipeline.discardUnloggedAudio(audioPath: retained.path, shouldLog: outcome.shouldLog)
            XCTAssertFalse(FileManager.default.fileExists(atPath: retained.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testLoggedOutcomesKeepRetainedAudio() throws {
        let source = writeTempSource(named: "logged.caf", bytes: 128)
        let retained = try XCTUnwrap(RecordingRetention.retain(from: source, maxBytes: 1024))
        for insertResult in [TextInjector.InsertResult.inserted(deliveredText: "words"), .failed] {
            let outcome = TranscriptionPipeline.secureInputOutcome(secureInput: false, insertResult: insertResult)
            XCTAssertTrue(outcome.shouldLog)
            TranscriptionPipeline.discardUnloggedAudio(audioPath: retained.path, shouldLog: outcome.shouldLog)
            XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        }
        TranscriptionPipeline.discardUnloggedAudio(audioPath: nil, shouldLog: false)
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

    func testFailedZipPreservesExistingDestination() throws {
        let destination = tempRoot.appendingPathComponent("previous.zip")
        let previous = Data("previous export".utf8)
        try previous.write(to: destination)
        let entry = HistoryEntry(text: "Keep this transcript.", engine: "test", injected: true)
        XCTAssertThrowsError(try RecordingRetention.exportZip(
            to: destination, historyEntries: [entry],
            zipExecutableURL: URL(fileURLWithPath: "/usr/bin/false")
        ))
        XCTAssertEqual(try Data(contentsOf: destination), previous)
    }
}
