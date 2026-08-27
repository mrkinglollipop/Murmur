import Foundation

/// Appends a line to `NSTemporaryDirectory()/voice-debug.log` via FileHandle
/// (written immediately, no stdio buffering, survives GUI-app reparenting) so
/// diagnostics are readable regardless of how the app was launched. File mode
/// is `0o600` (owner-only).
///
/// Debug-only: silent unless `VOICE_DEBUG` is set in the environment, so a
/// shipped app never writes the log. Enable during development by launching
/// with the variable set (e.g. `VOICE_DEBUG=1 /Applications/Murmur.app/Contents/MacOS/Murmur`).
/// Never pass user-dictated transcript text to this function — content stays private.
///
/// File-sink writes are serialized: `TextInjector.log` and activation paths can
/// call `vlog` concurrently; FileHandle seek+write is not thread-safe alone.
private let vlogFileLock = NSLock()

func vlog(_ message: String) {
    guard ProcessInfo.processInfo.environment["VOICE_DEBUG"] != nil else { return }
    let ts = String(format: "%.3f", Date().timeIntervalSince1970)
    let line = "[\(ts)] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("voice-debug.log")
    vlogFileLock.lock()
    defer { vlogFileLock.unlock() }
    let fm = FileManager.default
    if !fm.fileExists(atPath: path) {
        fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    guard let handle = FileHandle(forWritingAtPath: path) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
}
