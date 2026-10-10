import XCTest
@testable import Voice

final class VoicePathsTests: XCTestCase {

    func testTestHostUsesTemporaryVoiceRoot() {
        let realRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voice", isDirectory: true)
        XCTAssertNotEqual(VoicePaths.applicationSupportVoiceDirectory.path, realRoot.path)
        XCTAssertTrue(VoicePaths.applicationSupportVoiceDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    func testPrepareApplicationSupportVoiceDirectory_setsMode0700() throws {
        VoicePaths.prepareApplicationSupportVoiceDirectory()
        let path = VoicePaths.applicationSupportVoiceDirectory.path
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, Int(0o700))
    }

    func testPrepareApplicationSupportVoiceDirectory_deletesLegacyInjectDebugLog() throws {
        let logURL = VoicePaths.applicationSupportVoiceDirectory.appendingPathComponent("inject-debug.log")
        FileManager.default.createFile(atPath: logURL.path, contents: Data("x".utf8))
        VoicePaths.prepareApplicationSupportVoiceDirectory()
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
    }
}
