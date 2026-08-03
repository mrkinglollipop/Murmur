import Foundation
import os.log

/// Single owner for `Application Support/Voice/` paths and directory hardening.
enum VoicePaths {

    private static let logger = Logger(subsystem: "com.matt.voice-dictation", category: "voice-paths")

    private static var didChmodThisLaunch = false

    static var applicationSupportVoiceDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Voice", isDirectory: true)
    }

    /// WhisperKit `downloadBase` — `Application Support/Voice/Models`.
    static var modelsDirectory: URL {
        applicationSupportVoiceDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    static var recordingsDirectory: URL {
        applicationSupportVoiceDirectory.appendingPathComponent("Recordings", isDirectory: true)
    }

    /// Creates `Voice/` when missing, `chmod` 0700 once per launch (including
    /// pre-existing dirs), and removes the legacy inject-debug log file.
    static func prepareApplicationSupportVoiceDirectory() {
        let fm = FileManager.default
        let dir = applicationSupportVoiceDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        chmodApplicationSupportVoiceDirectory0700OncePerLaunch()
        deleteLegacyInjectDebugLog()
    }

    private static func chmodApplicationSupportVoiceDirectory0700OncePerLaunch() {
        guard !didChmodThisLaunch else { return }
        didChmodThisLaunch = true
        let path = applicationSupportVoiceDirectory.path
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: path
            )
        } catch {
            logger.error(
                "chmod 0700 failed for Voice Application Support: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func deleteLegacyInjectDebugLog() {
        let url = applicationSupportVoiceDirectory.appendingPathComponent("inject-debug.log")
        try? FileManager.default.removeItem(at: url)
    }
}
