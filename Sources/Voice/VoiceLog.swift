import Foundation

/// Fixed diagnostic events cannot carry dictated text or arbitrary error payloads.
enum AudioTapLogEvent {
    enum Provider: String { case xai, elevenlabs, gemini, muse }
    enum Failure: String { case emptyConversion, converterCreation, bufferAllocation, conversion }
    case conversionFailure(Provider, Failure)
    case geminiDurationCap

    var message: String {
        switch self {
        case let .conversionFailure(provider, failure):
            return "\(provider.rawValue)-stream: audio conversion failure (\(failure.rawValue))"
        case .geminiDurationCap:
            return "gemini-stream: 10min cap"
        }
    }
}

/// The injectable sink keeps diagnostics tests away from the app's real log.
final class VoiceDebugLog {
    private let fileLock = NSLock()
    private let path: String
    private let maxBytes: Int
    private let writer: ((Data) -> Void)?
    private let diagnosticQueue = DispatchQueue(label: "com.matt.voice-dictation.tap-diagnostics", qos: .utility)
    private let pendingSlots: DispatchSemaphore

    init(path: String, maxBytes: Int = 1_048_576, pendingLimit: Int = 128, writer: ((Data) -> Void)? = nil) {
        precondition(maxBytes > 0 && pendingLimit > 0)
        self.path = path
        self.maxBytes = maxBytes
        self.writer = writer
        self.pendingSlots = DispatchSemaphore(value: pendingLimit)
    }

    func write(_ message: String) {
        let ts = String(format: "%.3f", Date().timeIntervalSince1970)
        append(Data("[\(ts)] \(message)\n".utf8))
    }

    @discardableResult
    func record(_ event: AudioTapLogEvent) -> Bool {
        // Admission includes the in-flight event. Saturation drops diagnostics,
        // never audio, without waiting for the file lock or writer.
        guard pendingSlots.wait(timeout: .now()) == .success else { return false }
        diagnosticQueue.async { [self] in
            defer { pendingSlots.signal() }
            write(event.message)
        }
        return true
    }

    /// Never wait for diagnostics from an audio callback.
    func drain() {
        diagnosticQueue.sync {}
    }

    func append(_ data: Data) {
        fileLock.lock()
        defer { fileLock.unlock() }
        if let writer { writer(data); return }
        let fm = FileManager.default
        let boundedData = Data(data.prefix(maxBytes))
        do {
            if fm.fileExists(atPath: path) {
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
                let attributes = try fm.attributesOfItem(atPath: path)
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                if size > UInt64(maxBytes - boundedData.count) {
                    // A legacy unbounded log must not become an oversized backup.
                    if size > UInt64(maxBytes) {
                        let legacy = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                        defer { try? legacy.close() }
                        try legacy.truncate(atOffset: UInt64(maxBytes))
                    }
                    let backup = path + ".1"
                    if fm.fileExists(atPath: backup) {
                        try fm.removeItem(atPath: backup)
                    }
                    try fm.moveItem(atPath: path, toPath: backup)
                }
            }
        } catch {
            return
        }
        if !fm.fileExists(atPath: path) {
            guard fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        do {
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: boundedData)
        } catch {
            return
        }
    }
}

private let vlogEnabled = ProcessInfo.processInfo.environment["VOICE_DEBUG"] != nil
private let vlogSink = VoiceDebugLog(
    path: (NSTemporaryDirectory() as NSString).appendingPathComponent("voice-debug.log")
)

/// Debug-only, owner-only diagnostics. Never pass user-dictated transcript text.
func vlog(_ message: @autoclosure () -> String) {
    guard vlogEnabled else { return }
    vlogSink.write(message())
}

/// Fixed-size events are formatted and written off the audio-tap thread.
func vlogFromAudioTap(_ event: AudioTapLogEvent) {
    guard vlogEnabled else { return }
    vlogSink.record(event)
}
