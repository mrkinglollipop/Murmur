import XCTest
@testable import Voice

final class CleanupSanityTests: XCTestCase {

    func testLightCleanupAccepted() {
        let input = "um hello there how are you"
        let output = "Hello there, how are you?"
        XCTAssertTrue(ASREngineSelector.cleanupLooksSane(input: input, output: output))
    }

    func testAnswerRewriteRejected() {
        let input = "Can we deploy this today?"
        let output = "Yes, we can deploy this today after the review finishes."
        XCTAssertFalse(ASREngineSelector.cleanupLooksSane(input: input, output: output))
    }

    func testWildlyLongOutputRejected() {
        let input = "Send the report."
        let output = String(repeating: "extra words ", count: 20)
        XCTAssertFalse(ASREngineSelector.cleanupLooksSane(input: input, output: output))
    }

    func testWildlyShortOutputRejected() {
        let input = "Please schedule a follow up meeting with the design team tomorrow morning."
        let output = "OK."
        XCTAssertFalse(ASREngineSelector.cleanupLooksSane(input: input, output: output))
    }

    func testEmptyInputOrOutputAccepted() {
        XCTAssertTrue(ASREngineSelector.cleanupLooksSane(input: "", output: "anything"))
        XCTAssertTrue(ASREngineSelector.cleanupLooksSane(input: "hello", output: ""))
    }
}
