import XCTest
@testable import Voice

final class RedactionTests: XCTestCase {

    func testTokenLikeRunIsRedacted() {
        let token = String(repeating: "a1B2c3D4", count: 5) // 40 chars, [A-Za-z0-9]
        let body = "Unauthorized: invalid key \(token) provided"
        let redacted = CloudTranscriptionError.redactedBodyFragment(body)
        XCTAssertFalse(redacted.contains(token))
        XCTAssertTrue(redacted.contains("…"))
    }

    func testNormalErrorMessageSurvivesReadably() {
        let body = "{\"error\": {\"message\": \"Invalid request, missing audio field.\"}}"
        let redacted = CloudTranscriptionError.redactedBodyFragment(body)
        XCTAssertEqual(redacted, body)
    }

    func testOutputNeverExceedsMaxLength() {
        let body = String(repeating: "word ", count: 200)
        let redacted = CloudTranscriptionError.redactedBodyFragment(body, max: 300)
        XCTAssertLessThanOrEqual(redacted.count, 300)
    }
}
