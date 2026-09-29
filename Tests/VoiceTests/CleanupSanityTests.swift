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

    func testEmptyInputAccepted() {
        XCTAssertTrue(ASREngineSelector.cleanupLooksSane(input: "", output: "anything"))
        XCTAssertTrue(ASREngineSelector.cleanupLooksSane(input: "...", output: "anything"))
    }

    func testEmptyOutputRejected() {
        XCTAssertFalse(ASREngineSelector.cleanupLooksSane(input: "hello", output: ""))
    }

    /// An LLM reply with no letters or digits must not replace a dictation,
    /// including when the length ratio alone would pass.
    func testSymbolOnlyOutputRejected() {
        XCTAssertFalse(ASREngineSelector.cleanupLooksSane(input: "ok sure", output: "\u{1F44D}\u{1F44D}\u{1F44D}"))
        XCTAssertFalse(ASREngineSelector.cleanupLooksSane(input: "yes please do it", output: "..."))
        XCTAssertFalse(ASREngineSelector.cleanupLooksSane(
            input: "Please schedule a follow up meeting with the design team tomorrow morning.",
            output: "\u{2026}"
        ))
    }
}
