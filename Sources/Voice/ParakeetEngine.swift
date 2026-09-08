import Darwin
import Foundation
import os.log

// MARK: - Parakeet ASR Engine

/// Speech recognition using the `parakeet-mlx` Python package via a subprocess.
///
/// The Python sidecar `Resources/parakeet_transcribe.py` is bundled inside the
/// app. It receives the audio file path as argv[1] and prints a JSON object
/// `{"text": "..."}` to stdout.
///
/// REQUIREMENT (developer): `pip install parakeet-mlx` must be run once in the
/// Python environment resolved at launch (Homebrew, pyenv, or system `python3`).
/// Proper app-bundling of the Python environment is a later task.
final class ParakeetEngine: ASREngine {

    let id = "parakeet"
    let displayName = "Parakeet (MLX sidecar)"

    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "parakeet")

    // MARK: - ASREngine

    func transcribe(audioURL: URL) async throws -> String {
        let interpreterDescription = Self.resolvedPythonInterpreterDescription()

        guard let scriptURL = Bundle.main.url(
            forResource: "parakeet_transcribe",
            withExtension: "py",
            subdirectory: nil
        ) else {
            // Fallback path for running directly from build products (no bundle)
            let devScriptURL = Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("parakeet_transcribe.py")
            if FileManager.default.fileExists(atPath: devScriptURL.path) {
                return try await runSidecar(
                    scriptURL: devScriptURL,
                    audioURL: audioURL,
                    interpreterDescription: interpreterDescription
                )
            }
            logger.error("Parakeet: sidecar script not found in bundle or build products.")
            throw ParakeetError.sidecarNotFound(interpreterDescription: interpreterDescription)
        }

        return try await runSidecar(
            scriptURL: scriptURL,
            audioURL: audioURL,
            interpreterDescription: interpreterDescription
        )
    }

    // MARK: - Private

    /// Probes common macOS Python installs before falling back to `/usr/bin/env python3`.
    private static func resolvedPythonExecutable() -> (executable: URL, argumentsPrefix: [String], description: String) {
        let fm = FileManager.default
        let candidates: [(path: String, description: String)] = [
            ("/opt/homebrew/bin/python3", "/opt/homebrew/bin/python3"),
            ("/usr/local/bin/python3", "/usr/local/bin/python3"),
            (
                fm.homeDirectoryForCurrentUser
                    .appendingPathComponent(".pyenv/shims/python3").path,
                "\(fm.homeDirectoryForCurrentUser.path)/.pyenv/shims/python3"
            ),
        ]

        for candidate in candidates {
            if fm.isExecutableFile(atPath: candidate.path) {
                return (
                    URL(fileURLWithPath: candidate.path),
                    [],
                    candidate.description
                )
            }
        }

        return (
            URL(fileURLWithPath: "/usr/bin/env"),
            ["python3"],
            "/usr/bin/env python3"
        )
    }

    private static func resolvedPythonInterpreterDescription() -> String {
        resolvedPythonExecutable().description
    }

    private func runSidecar(
        scriptURL: URL,
        audioURL: URL,
        interpreterDescription: String
    ) async throws -> String {
        logger.info("Parakeet: launching sidecar \(scriptURL.lastPathComponent) for \(audioURL.lastPathComponent)")

        let python = Self.resolvedPythonExecutable()

        let text = try await ParakeetProcessRunner.run(
            executableURL: python.executable,
            arguments: python.argumentsPrefix + [scriptURL.path, audioURL.path],
            interpreterDescription: interpreterDescription
        )
        logger.info("Parakeet: got \(text.count) chars of transcript")
        return text
    }
}

// MARK: - Owned subprocess runner

enum ParakeetProcessRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        interpreterDescription: String,
        timeoutSeconds: TimeInterval = 120,
        terminationGraceSeconds: TimeInterval = 0.35
    ) async throws -> String {
        let invocation = ParakeetProcessInvocation(
            executableURL: executableURL,
            arguments: arguments,
            interpreterDescription: interpreterDescription,
            timeoutSeconds: timeoutSeconds,
            terminationGraceSeconds: terminationGraceSeconds
        )
        return try await withTaskCancellationHandler {
            try await invocation.run()
        } onCancel: {
            invocation.cancel()
        }
    }
}

private final class ParakeetProcessInvocation: @unchecked Sendable {
    private enum StopReason {
        case cancelled
        case timedOut
    }

    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let interpreterDescription: String
    private let timeoutSeconds: TimeInterval
    private let terminationGraceSeconds: TimeInterval
    private let stateLock = NSLock()
    private let outputLock = NSLock()

    private var continuation: CheckedContinuation<String, Error>?
    private var completed = false
    private var launched = false
    private var terminated = false
    private var shutdownStarted = false
    private var stopReason: StopReason?
    private var timeoutWorkItem: DispatchWorkItem?
    private var stdoutData = Data()
    private var stderrData = Data()
    private var pipesClosed = false

    init(
        executableURL: URL,
        arguments: [String],
        interpreterDescription: String,
        timeoutSeconds: TimeInterval,
        terminationGraceSeconds: TimeInterval
    ) {
        self.interpreterDescription = interpreterDescription
        self.timeoutSeconds = timeoutSeconds
        self.terminationGraceSeconds = terminationGraceSeconds
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func run() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            stateLock.lock()
            self.continuation = continuation
            let cancelledBeforeLaunch = stopReason != nil
            stateLock.unlock()
            guard !cancelledBeforeLaunch else {
                finish(.failure(CancellationError()))
                return
            }

            installPipeReaders()
            process.terminationHandler = { [weak self] process in
                self?.processTerminated(process)
            }

            do {
                try process.run()
                // Process retains the duplicated child descriptors. The parent
                // must close its write ends so EOF reflects child ownership.
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
            } catch {
                closePipesAndSnapshot()
                finish(.failure(error))
                return
            }

            stateLock.lock()
            launched = true
            let shouldStop = stopReason != nil
            stateLock.unlock()

            let timeout = DispatchWorkItem { [weak self] in self?.timeOut() }
            stateLock.lock()
            if completed {
                stateLock.unlock()
                timeout.cancel()
            } else {
                timeoutWorkItem = timeout
                stateLock.unlock()
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + max(0, timeoutSeconds),
                    execute: timeout
                )
            }

            if shouldStop { beginShutdown() }
        }
    }

    func cancel() {
        requestStop(.cancelled)
    }

    private func timeOut() {
        requestStop(.timedOut)
    }

    private func requestStop(_ reason: StopReason) {
        stateLock.lock()
        guard !completed else {
            stateLock.unlock()
            return
        }
        if stopReason == nil { stopReason = reason }
        let shouldShutdown = launched
        stateLock.unlock()
        if shouldShutdown { beginShutdown() }
    }

    private func beginShutdown() {
        stateLock.lock()
        guard launched, !terminated, !shutdownStarted else {
            stateLock.unlock()
            return
        }
        shutdownStarted = true
        stateLock.unlock()

        DispatchQueue.global().async { [self] in
            signalOwnedProcess(SIGTERM)
            waitWhileRunning(for: terminationGraceSeconds)
            if process.isRunning {
                signalOwnedProcess(SIGKILL)
                waitWhileRunning(for: 2.0)
            }
            // Never wait for pipe EOF here: a descendant may have inherited a
            // writer. Closing our readers also releases a blocked writer.
            if process.isRunning {
                closePipesAndSnapshot()
                finish(stopResult())
            }
        }
    }

    private func signalOwnedProcess(_ signal: Int32) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        let processGroup = Darwin.getpgid(pid)
        guard processGroup >= 0 else { return }
        if processGroup == pid {
            // Negative PID targets only the verified group owned by this child.
            _ = Darwin.kill(-pid, signal)
        } else {
            _ = Darwin.kill(pid, signal)
        }
    }

    private func waitWhileRunning(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(max(0, seconds))
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
    }

    private func processTerminated(_ process: Process) {
        stateLock.lock()
        terminated = true
        let reason = stopReason
        stateLock.unlock()

        let (outData, errData) = closePipesAndSnapshot()
        if reason != nil {
            finish(stopResult())
        } else if process.terminationStatus != 0 {
            let message = String(data: errData, encoding: .utf8) ?? "unknown error"
            finish(.failure(ParakeetError.sidecarExitCode(
                process.terminationStatus,
                message,
                interpreterDescription: interpreterDescription
            )))
        } else {
            do {
                guard let json = try JSONSerialization.jsonObject(with: outData) as? [String: Any],
                      let text = json["text"] as? String else {
                    finish(.failure(ParakeetError.invalidJSON))
                    return
                }
                finish(.success(text.trimmingCharacters(in: .whitespaces)))
            } catch {
                finish(.failure(error))
            }
        }
    }

    private func stopResult() -> Result<String, Error> {
        stateLock.lock()
        let reason = stopReason
        stateLock.unlock()
        switch reason {
        case .cancelled:
            return .failure(CancellationError())
        case .timedOut, .none:
            return .failure(ParakeetError.sidecarExitCode(
                -1,
                "timed out after \(timeoutSeconds)s",
                interpreterDescription: interpreterDescription
            ))
        }
    }

    private func finish(_ result: Result<String, Error>) {
        stateLock.lock()
        guard !completed else {
            stateLock.unlock()
            return
        }
        completed = true
        let continuation = continuation
        self.continuation = nil
        let timeout = timeoutWorkItem
        timeoutWorkItem = nil
        stateLock.unlock()

        timeout?.cancel()
        continuation?.resume(with: result)
    }

    private func installPipeReaders() {
        makeNonblocking(stdout.fileHandleForReading.fileDescriptor)
        makeNonblocking(stderr.fileHandleForReading.fileDescriptor)
        stdout.fileHandleForReading.readabilityHandler = { [weak self] _ in
            self?.drain(stdout: true)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] _ in
            self?.drain(stdout: false)
        }
    }

    private func makeNonblocking(_ descriptor: Int32) {
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
    }

    private func drain(stdout isStdout: Bool) {
        outputLock.lock()
        defer { outputLock.unlock() }
        guard !pipesClosed else { return }
        let descriptor = isStdout
            ? stdout.fileHandleForReading.fileDescriptor
            : stderr.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            if isStdout {
                stdoutData.append(contentsOf: buffer.prefix(count))
            } else {
                stderrData.append(contentsOf: buffer.prefix(count))
            }
        }
    }

    @discardableResult
    private func closePipesAndSnapshot() -> (Data, Data) {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        drain(stdout: true)
        drain(stdout: false)
        outputLock.lock()
        if !pipesClosed {
            pipesClosed = true
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
        }
        let snapshot = (stdoutData, stderrData)
        outputLock.unlock()
        return snapshot
    }
}

// MARK: - Errors

enum ParakeetError: Error, LocalizedError {
    case sidecarNotFound(interpreterDescription: String)
    case sidecarExitCode(Int32, String, interpreterDescription: String)
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .sidecarNotFound(let interpreterDescription):
            return "Parakeet sidecar script not found — install parakeet-mlx for \(interpreterDescription) and ensure parakeet_transcribe.py is bundled."
        case .sidecarExitCode(let code, let msg, let interpreterDescription):
            return "Parakeet sidecar (\(interpreterDescription)) exited with code \(code): \(msg)"
        case .invalidJSON:
            return "Parakeet sidecar returned invalid JSON (expected {\"text\": \"...\"})"
        }
    }
}
