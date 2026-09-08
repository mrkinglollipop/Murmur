import Foundation
import Darwin

/// Persists the enrolled speaker profile under Application Support/Voice.
/// Injectable directory URL for tests — production default never touches temp
/// paths; tests MUST pass a temp directory.
final class VoiceProfileStore {

    static let profileFileName = "voice-profile.json"

    private let directoryURL: URL
    private let writeProfile: (Data, URL) throws -> Void
    private var profileFileURL: URL {
        directoryURL.appendingPathComponent(Self.profileFileName)
    }

    init(directoryURL: URL? = nil, writeProfile: @escaping (Data, URL) throws -> Void = VoiceProfileStore.writeAtomically) {
        self.writeProfile = writeProfile
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

    @discardableResult
    func save(_ profile: VoiceProfile) -> Bool {
        do {
            let data = try JSONEncoder().encode(profile)
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try writeProfile(data, profileFileURL)
            return true
        } catch {
            return false
        }
    }

    static func writeAtomically(_ data: Data, to destination: URL) throws {
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".voice-profile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        guard FileManager.default.createFile(atPath: staged.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard Darwin.rename(staged.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func deleteProfile() {
        try? FileManager.default.removeItem(at: profileFileURL)
    }
}
