import XCTest
@testable import Voice

final class VoiceLogTests: XCTestCase {
    func testConversionFailureDiagnosticReturnsWhileWriterIsBlocked() {
        let writerEntered = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let diagnosticEntered = DispatchSemaphore(value: 0)
        let diagnosticReturned = DispatchSemaphore(value: 0)
        let blockerFinished = expectation(description: "blocked writer finishes")
        let diagnosticFinished = expectation(description: "diagnostic finishes")
        let log = VoiceDebugLog(path: "unused", writer: { _ in
            writerEntered.signal()
            releaseWriter.wait()
        })
        DispatchQueue.global().async {
            log.write("writer blocker")
            blockerFinished.fulfill()
        }
        XCTAssertEqual(writerEntered.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async {
            diagnosticEntered.signal()
            log.record(.conversionFailure(.xai, .emptyConversion))
            diagnosticReturned.signal()
            diagnosticFinished.fulfill()
        }
        XCTAssertEqual(diagnosticEntered.wait(timeout: .now() + 5), .success)
        let returnedBeforeRelease = diagnosticReturned.wait(timeout: .now() + 5)
        // Release both sink calls even when the regression assertion fails.
        releaseWriter.signal()
        releaseWriter.signal()
        wait(for: [blockerFinished, diagnosticFinished], timeout: 5)
        log.drain()
        XCTAssertEqual(returnedBeforeRelease, .success, "Audio-tap diagnostics waited for the file writer")
    }

    func testTapDiagnosticAdmissionIsBoundedWhileWriterIsBlocked() {
        let writerEntered = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let producerReturned = DispatchSemaphore(value: 0)
        let blockerFinished = expectation(description: "blocker finishes")
        let producerFinished = expectation(description: "producer finishes")
        var firstWrite = true
        let log = VoiceDebugLog(path: "unused", pendingLimit: 2, writer: { _ in
            // The sink runs under the file lock, so this flag has one writer.
            if firstWrite {
                firstWrite = false
                writerEntered.signal()
                releaseWriter.wait()
            }
        })
        DispatchQueue.global().async {
            log.write("writer blocker")
            blockerFinished.fulfill()
        }
        XCTAssertEqual(writerEntered.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async {
            XCTAssertTrue(log.record(.conversionFailure(.xai, .emptyConversion)))
            XCTAssertTrue(log.record(.conversionFailure(.elevenlabs, .conversion)))
            XCTAssertFalse(log.record(.conversionFailure(.muse, .bufferAllocation)))
            producerReturned.signal()
            producerFinished.fulfill()
        }
        let returnedBeforeRelease = producerReturned.wait(timeout: .now() + 5)
        releaseWriter.signal()
        wait(for: [blockerFinished, producerFinished], timeout: 5)
        log.drain()
        XCTAssertEqual(returnedBeforeRelease, .success)
        XCTAssertTrue(log.record(.geminiDurationCap), "Drained events must release admission slots")
        log.drain()
    }

    func testLogRotatesBeforeExceedingByteLimit() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("debug.log")
        let log = VoiceDebugLog(path: file.path, maxBytes: 64)
        let first = Data(repeating: 65, count: 48)
        let second = Data(repeating: 66, count: 32)
        log.append(first)
        log.append(second)
        XCTAssertEqual(try Data(contentsOf: file), second)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file.path + ".1")), first)
        for path in [file.path, file.path + ".1"] {
            let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)
        }
    }

    func testRepeatedRotationKeepsOnlyOneBoundedBackup() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("debug.log")
        let backup = URL(fileURLWithPath: file.path + ".1")
        let log = VoiceDebugLog(path: file.path, maxBytes: 64)
        log.append(Data(repeating: 65, count: 128))
        XCTAssertEqual(try Data(contentsOf: file).count, 64)
        log.append(Data(repeating: 66, count: 64))
        log.append(Data(repeating: 67, count: 8))
        XCTAssertEqual(try Data(contentsOf: file), Data(repeating: 67, count: 8))
        XCTAssertEqual(try Data(contentsOf: backup), Data(repeating: 66, count: 64))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                       ["debug.log", "debug.log.1"])
    }

    func testLegacyOversizedLogIsBoundedWithOwnerOnlyPermissions() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("debug.log")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: file.path, contents: Data(repeating: 65, count: 128),
            attributes: [.posixPermissions: 0o644]
        ))
        let log = VoiceDebugLog(path: file.path, maxBytes: 64)
        log.append(Data(repeating: 66, count: 8))
        XCTAssertEqual(try Data(contentsOf: file), Data(repeating: 66, count: 8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file.path + ".1")).count, 64)
        for path in [file.path, file.path + ".1"] {
            let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)
        }
    }

    private func makeDirectory() throws -> URL {
        // #filePath anchors scratch files to this worktree, never the real data directory.
        let worktree = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = worktree.appendingPathComponent(".codex-evidence/log-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
