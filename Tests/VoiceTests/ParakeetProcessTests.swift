import Darwin
import XCTest
@testable import Voice

final class ParakeetProcessTests: XCTestCase {
    func testRunnerReturnsNormalJSON() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("normal.py")
        try #"import json; print(json.dumps({"text": "  normal result  "}), flush=True)"#
            .write(to: script, atomically: true, encoding: .utf8)

        let text = try await ParakeetProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [script.path],
            interpreterDescription: "test python",
            timeoutSeconds: 2,
            terminationGraceSeconds: 0.1
        )
        XCTAssertEqual(text, "normal result")
    }

    func testCancellationTerminatesAndReapsOwnedProcessGroup() async throws {
        let fixture = try makeStubbornFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let task = Task {
            try await ParakeetProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: [fixture.script.path, fixture.pidFile.path],
                interpreterDescription: "test python",
                timeoutSeconds: 5,
                terminationGraceSeconds: 0.1
            )
        }
        let pids = try await readPIDs(from: fixture.pidFile)
        let startedAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let processesExited = await waitUntilGone(pids)
        XCTAssertTrue(processesExited)
    }

    func testTimeoutKillsSIGTERMIgnoringProcessAndDescendant() async throws {
        let fixture = try makeStubbornFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let startedAt = Date()
        do {
            _ = try await ParakeetProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: [fixture.script.path, fixture.pidFile.path],
                interpreterDescription: "test python",
                timeoutSeconds: 0.2,
                terminationGraceSeconds: 0.1
            )
            XCTFail("expected timeout")
        } catch let error as ParakeetError {
            guard case .sidecarExitCode(let code, _, _) = error else {
                XCTFail("unexpected Parakeet error: \(error)")
                return
            }
            XCTAssertEqual(code, -1)
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
        }
        let pids = try await readPIDs(from: fixture.pidFile)
        let processesExited = await waitUntilGone(pids)
        XCTAssertTrue(processesExited)
    }

    private func makeStubbornFixture() throws -> (directory: URL, script: URL, pidFile: URL) {
        let directory = try makeTemporaryDirectory()
        let script = directory.appendingPathComponent("stubborn.py")
        let pidFile = directory.appendingPathComponent("pids.json")
        let source = #"""
import json, os, pathlib, signal, subprocess, sys, time
try:
    os.setpgid(0, 0)
except OSError:
    pass
signal.signal(signal.SIGTERM, signal.SIG_IGN)
child = subprocess.Popen([
    sys.executable,
    "-c",
    "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)",
])
pathlib.Path(sys.argv[1]).write_text(json.dumps([os.getpid(), child.pid]))
while True:
    time.sleep(1)
"""#
        try source.write(to: script, atomically: true, encoding: .utf8)
        return (directory, script, pidFile)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-parakeet-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func readPIDs(from url: URL) async throws -> [Int32] {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let values = try? JSONDecoder().decode([Int32].self, from: data) {
                return values
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("child did not publish PID fixture")
        return []
    }

    private func waitUntilGone(_ pids: [Int32]) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if pids.allSatisfy({ !processExists($0) }) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return pids.allSatisfy { !processExists($0) }
    }

    private func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }
}
