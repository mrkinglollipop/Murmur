import XCTest
@testable import Voice

final class CleanupSanityTests: XCTestCase {

    func testLightCleanupAccepted() {
        let input = "um hello there how are you"
        let output = "Hello there, how are you?"
        XCTAssertTrue(ASREngineSelector.cleanupLooksSane(input: input, output: output))
    }

    func testDroppedWholeSentenceRejected() {
        XCTAssertFalse(ASREngineSelector.cleanupLooksSane(
            input: "Send the report today. Call the client tomorrow.",
            output: "Send the report today."
        ))
    }

    func testDroppedRepeatedSentenceRejected() {
        XCTAssertFalse(ASREngineSelector.cleanupLooksSane(
            input: "Send the report today. Send the report today.",
            output: "Send the report today."
        ))
    }

    func testDroppedNegationsRejected() {
        for (input, output) in [
            ("Please do not send the report today.", "Please do send the report today."),
            ("There is no meeting scheduled for today.", "There is meeting scheduled for today."),
            ("Please never share this document with anyone.", "Please share this document with anyone."),
            ("Please don't send the report today.", "Please do send the report today."),
            ("Please don't send the report today.", "Please don t send the report today."),
            ("We can't deploy the changes today.", "We can deploy the changes today."),
            ("This isn't ready for the meeting today.", "This is ready for the meeting today.")
        ] {
            XCTAssertFalse(ASREngineSelector.cleanupLooksSane(input: input, output: output), input)
        }
    }

    func testDroppedChangedOrRepeatedNumbersRejected() {
        for output in ["Please send invoices and 42 today.", "Please send invoices 41 and 43 today.", "Please send invoices 41 and 42 today."] {
            XCTAssertFalse(ASREngineSelector.cleanupLooksSane(
                input: "Please send invoices 41 and 42 and 42 today.", output: output
            ))
        }
        XCTAssertFalse(ASREngineSelector.cleanupLooksSane(input: "Charge 12.50 to the client today.", output: "Charge 12 to the client today."))
    }

    /// Styles rewrite tone through cleanup; a rephrase that keeps every
    /// sentence, negation and number must still pass.
    func testRephraseKeepingContentAccepted() {
        XCTAssertTrue(ASREngineSelector.cleanupLooksSane(
            input: "so like I think we should um ship it on Friday. I mean the tests don't fail anymore.",
            output: "I think we should ship it on Friday. The tests don't fail anymore."
        ))
        XCTAssertTrue(ASREngineSelector.cleanupLooksSane(
            input: "I want to I want to go to the store",
            output: "I want to go to the store."
        ))
    }

    func testFillersPunctuationAndCasingAcceptedAcrossSentences() {
        XCTAssertTrue(ASREngineSelector.cleanupLooksSane(
            input: "um send the report today uh call the client tomorrow",
            output: "Send the report today. Call the client tomorrow."
        ))
        XCTAssertTrue(ASREngineSelector.cleanupLooksSane(
            input: "uh we don't need 42 copies um never print 43",
            output: "We don’t need 42 copies. Never print 43."
        ))
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
