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

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()

            process.executableURL = python.executable
            process.arguments = python.argumentsPrefix + [scriptURL.path, audioURL.path]
            process.standardOutput = stdout
            process.standardError = stderr

            // Accumulate stdout/stderr incrementally via readabilityHandler
            // instead of readDataToEndOfFile() inside terminationHandler.
            // readDataToEndOfFile() blocks until EOF, but the pipe's kernel
            // buffer is only ~64KB — if the child writes more than that before
            // the parent starts draining, the child blocks on write() and the
            // process never terminates, so terminationHandler never fires
            // (deadlock). Draining continuously as data arrives avoids this.
            let outBuffer = NSMutableData()
            let errBuffer = NSMutableData()
            let bufferLock = NSLock()
            var resumed = false

            func resumeOnce(_ result: Result<String, Error>) {
                bufferLock.lock()
                defer { bufferLock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                bufferLock.lock()
                outBuffer.append(data)
                bufferLock.unlock()
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                bufferLock.lock()
                errBuffer.append(data)
                bufferLock.unlock()
            }

            // Capture self STRONGLY here: if self were weak and deallocated
            // mid-process, the continuation would never resume (the checked
            // continuation contract requires exactly one resume, and a nil
            // self would silently skip it — a hang, not a crash).
            process.terminationHandler = { proc in
                // Tear down the readability handlers and do one final drain
                // in case data arrived between the last callback and exit.
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil

                let finalOut = stdout.fileHandleForReading.readDataToEndOfFile()
                let finalErr = stderr.fileHandleForReading.readDataToEndOfFile()

                bufferLock.lock()
                if !finalOut.isEmpty { outBuffer.append(finalOut) }
                if !finalErr.isEmpty { errBuffer.append(finalErr) }
                let outData = Data(referencing: outBuffer)
                let errData = Data(referencing: errBuffer)
                bufferLock.unlock()

                if proc.terminationStatus != 0 {
                    let errMsg = String(data: errData, encoding: .utf8) ?? "unknown error"
                    self.logger.error("Parakeet sidecar exited \(proc.terminationStatus): \(errMsg)")
                    resumeOnce(.failure(ParakeetError.sidecarExitCode(
                        proc.terminationStatus,
                        errMsg,
                        interpreterDescription: interpreterDescription
                    )))
                    return
                }

                do {
                    guard let json = try JSONSerialization.jsonObject(with: outData) as? [String: Any],
                          let text = json["text"] as? String else {
                        resumeOnce(.failure(ParakeetError.invalidJSON))
                        return
                    }
                    self.logger.info("Parakeet: got \(text.count) chars of transcript")
                    resumeOnce(.success(text.trimmingCharacters(in: .whitespaces)))
                } catch {
                    resumeOnce(.failure(error))
                }
            }

            // Wedge-breaker only — generous so cold model loads never trip it.
            let timeoutSeconds: TimeInterval = 120
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                bufferLock.lock()
                let already = resumed
                bufferLock.unlock()
                guard !already else { return }
                self.logger.error("Parakeet sidecar timed out after \(Int(timeoutSeconds))s — terminating")
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                process.terminate()
                resumeOnce(.failure(ParakeetError.sidecarExitCode(
                    -1,
                    "timed out after \(Int(timeoutSeconds))s",
                    interpreterDescription: interpreterDescription
                )))
            }

            do {
                try process.run()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                resumeOnce(.failure(error))
            }
        }
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
