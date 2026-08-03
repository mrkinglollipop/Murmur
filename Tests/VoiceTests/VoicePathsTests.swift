import XCTest
@testable import Voice

final class VoicePathsTests: XCTestCase {

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
