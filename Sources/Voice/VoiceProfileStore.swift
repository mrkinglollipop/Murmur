import Foundation

/// Persists the enrolled speaker profile under Application Support/Voice.
/// Injectable directory URL for tests — production default never touches temp
/// paths; tests MUST pass a temp directory.
final class VoiceProfileStore {

    static let profileFileName = "voice-profile.json"

    private let directoryURL: URL
    private var profileFileURL: URL {
        directoryURL.appendingPathComponent(Self.profileFileName)
    }

    init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            VoicePaths.prepareApplicationSupportVoiceDirectory()
            self.directoryURL = VoicePaths.applicationSupportVoiceDirectory
        }
    }

    /// Returns nil on missing file, unreadable file, or JSON decode failure.
    func load() -> VoiceProfile? {
        let url = profileFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(VoiceProfile.self, from: data)
    }

    func save(_ profile: VoiceProfile) {
        do {
            let data = try JSONEncoder().encode(profile)
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let url = profileFileURL
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            fileManager.createFile(
                atPath: url.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            )
        } catch {
            // Corrupt or full disk — enrollment fails silently; dictation stays live.
        }
    }

    func deleteProfile() {
        try? FileManager.default.removeItem(at: profileFileURL)
    }
}
