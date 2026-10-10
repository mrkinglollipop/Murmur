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
                terminationGraceSeconds: 0.1,
                temporaryDirectory: fixture.directory
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
        let wavPath = try String(contentsOf: fixture.directory.appendingPathComponent("wav-path.txt"), encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wavPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: wavPath).deletingLastPathComponent().path))
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
                terminationGraceSeconds: 0.1,
                temporaryDirectory: fixture.directory
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
        let wavPath = try String(contentsOf: fixture.directory.appendingPathComponent("wav-path.txt"), encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wavPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: wavPath).deletingLastPathComponent().path))
    }

    func testSidecarTempFilesAreRemovedOnNormalAndErrorExit() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("temp.py")
        let marker = directory.appendingPathComponent("wav-path.txt")
        let source = #"""
import json, os, pathlib, sys, tempfile
fd, wav = tempfile.mkstemp(suffix=".wav", prefix="parakeet_")
os.write(fd, b"private audio")
os.close(fd)
pathlib.Path(sys.argv[1]).write_text(wav)
if sys.argv[2] == "fail":
    sys.exit(7)
print(json.dumps({"text": "result"}))
"""#
        try source.write(to: script, atomically: true, encoding: .utf8)
        let unrelated = directory.appendingPathComponent("unrelated.wav")
        try Data([1]).write(to: unrelated)
        for mode in ["success", "fail"] {
            do {
                let text = try await ParakeetProcessRunner.run(
                    executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                    arguments: [script.path, marker.path, mode], interpreterDescription: "test python",
                    timeoutSeconds: 2, temporaryDirectory: directory
                )
                XCTAssertEqual(mode, "success")
                XCTAssertEqual(text, "result")
            } catch let error as ParakeetError {
                guard case .sidecarExitCode(let code, _, _) = error else { throw error }
                XCTAssertEqual(mode, "fail")
                XCTAssertEqual(code, 7)
            }
            let wavPath = try String(contentsOf: marker, encoding: .utf8)
            XCTAssertTrue(wavPath.hasPrefix(directory.path + "/"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: wavPath))
            XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: wavPath).deletingLastPathComponent().path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        }
    }

    func testSIGTERMCleanupDoesNotDependOnPythonFinally() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("term.py")
        let marker = directory.appendingPathComponent("pids.json")
        let source = #"""
import json, os, pathlib, sys, tempfile, time
fd, wav = tempfile.mkstemp(suffix=".wav", prefix="parakeet_")
os.close(fd)
pathlib.Path(sys.argv[1]).parent.joinpath("wav-path.txt").write_text(wav)
pathlib.Path(sys.argv[1]).write_text(json.dumps([os.getpid()]))
time.sleep(60)
"""#
        try source.write(to: script, atomically: true, encoding: .utf8)
        let task = Task {
            try await ParakeetProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: [script.path, marker.path], interpreterDescription: "test python",
                timeoutSeconds: 5, temporaryDirectory: directory
            )
        }
        let pids = try await readPIDs(from: marker)
        let wavPath = try String(contentsOf: directory.appendingPathComponent("wav-path.txt"), encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wavPath))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        let exited = await waitUntilGone(pids)
        XCTAssertTrue(exited)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wavPath))
    }

    func testLaunchFailureCleansOwnedTempDirectory() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await ParakeetProcessRunner.run(
                executableURL: directory.appendingPathComponent("missing-python"),
                arguments: [], interpreterDescription: "missing python", temporaryDirectory: directory
            )
            XCTFail("expected launch failure")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testSidecarResolutionHonorsBuildConfiguration() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Murmur.app")
        let adjacent = directory.appendingPathComponent("parakeet_transcribe.py")
        let bundled = app.appendingPathComponent("Contents/Resources/parakeet_transcribe.py")
        XCTAssertNil(ParakeetEngine.resolveScriptURL(bundledURL: nil, appBundleURL: app))
        try Data([0]).write(to: adjacent)
        XCTAssertEqual(ParakeetEngine.resolveScriptURL(bundledURL: bundled, appBundleURL: app), bundled)
        #if DEBUG
        XCTAssertEqual(ParakeetEngine.resolveScriptURL(bundledURL: nil, appBundleURL: app), adjacent)
        #else
        XCTAssertNil(ParakeetEngine.resolveScriptURL(bundledURL: nil, appBundleURL: app))
        #endif
    }

    private func makeStubbornFixture() throws -> (directory: URL, script: URL, pidFile: URL) {
        let directory = try makeTemporaryDirectory()
        let script = directory.appendingPathComponent("stubborn.py")
        let pidFile = directory.appendingPathComponent("pids.json")
        let source = #"""
import json, os, pathlib, signal, subprocess, sys, tempfile, time
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
fd, wav = tempfile.mkstemp(suffix=".wav", prefix="parakeet_")
os.write(fd, b"private audio")
os.close(fd)
pathlib.Path(sys.argv[1]).parent.joinpath("wav-path.txt").write_text(wav)
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
