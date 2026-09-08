import XCTest
@testable import Voice

final class AssemblyAIRequestTests: XCTestCase {
    func testUsesCurrentPriorityOrderedSpeechModels() throws {
        let data = try AssemblyAITranscriptionService.makeTranscriptRequestBody(
            audioURL: "https://example.invalid/audio.wav",
            language: "en"
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(body["speech_models"] as? [String], ["universal-3-5-pro", "universal-2"])
        XCTAssertNil(body["speech_model"])
        XCTAssertEqual(body["language_code"] as? String, "en")
    }
}
