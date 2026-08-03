import XCTest
@testable import Voice

final class EngineDisplayNameTests: XCTestCase {

    func testKnownStoredIDsMapToDisplayNames() {
        XCTAssertEqual(
            EngineDisplayName.displayName(for: "parakeet"),
            LocalModel.parakeetTDT06BV3.displayName
        )
        XCTAssertEqual(
            EngineDisplayName.displayName(for: "cloud:elevenlabs-streaming"),
            "\(CloudProvider.elevenLabs.displayName) (streaming)"
        )
        XCTAssertEqual(
            EngineDisplayName.displayName(for: "cloud:elevenLabs"),
            CloudProvider.elevenLabs.displayName
        )
        XCTAssertEqual(
            EngineDisplayName.displayName(for: "cloud:xai-streaming"),
            "\(CloudProvider.xai.displayName) (streaming)"
        )
        XCTAssertEqual(
            EngineDisplayName.displayName(for: "whisperKit:streaming"),
            "Whisper (streaming)"
        )
        XCTAssertEqual(
            EngineDisplayName.displayName(for: "whisperKit:openai_whisper-large-v3_turbo"),
            LocalModel.whisperLargeV3Turbo.displayName
        )
    }
}
