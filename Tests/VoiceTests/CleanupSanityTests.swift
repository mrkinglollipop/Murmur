import XCTest
@testable import Voice

final class CleanupSanityTests: XCTestCase {

    func testFormalContractionExpansionAccepted() {
        XCTAssertTrue(ASREngineSelector.cleanupLooksSane(
            input: "I'll send the report tomorrow.", output: "I will send the report tomorrow."))
    }

    private struct FixedCleanup: TranscriptCleanupService {
        let output: String
        func cleanup(_ text: String, codeAware: Bool, styleInstruction: String?) async throws -> String {
            XCTAssertEqual(styleInstruction, "Use a formal style.")
            let prompt = CleanupPrompt.instructions(codeAware: codeAware, styleInstruction: styleInstruction)
            XCTAssertTrue(prompt.contains("like"))
            XCTAssertTrue(prompt.contains("you know"))
            return output
        }
    }

    @MainActor
    func testPromptSupportedCleanupReachesDelivery() {
        for (input, output) in [
            ("I'll send the report tomorrow.", "I will send the report tomorrow."),
            ("I will send the report tomorrow.", "I'll send the report tomorrow."),
            ("like I'll send the report you know tomorrow", "I will send the report tomorrow."),
            ("you know we can't send 42 reports today", "We cannot send 42 reports today."),
            ("we should, like, send the report", "We should send the report."),
            ("we should, you know, send the report", "We should send the report."),
            ("we should send the report, you know.", "We should send the report.")
        ] {
            assertCleanupDelivery(input: input, output: output, expected: output)
        }
    }

    @MainActor
    func testUnsafeCleanupFallsBackInDelivery() {
        for (input, output) in [
            ("I'll send the report. Call Alice.", "I will send the report."),
            ("I'll send 42 reports tomorrow.", "I will send 43 reports tomorrow."),
            ("I won't send the report tomorrow.", "I will send the report tomorrow."),
            ("Alice will pay Bob tomorrow.", "Bob will pay Alice tomorrow."),
            ("Act like I told you.", "Act I told you."),
            ("Tell me what you know.", "Tell me what."),
            ("Do you know I paid Bob?", "Do I paid Bob?")
        ] {
            assertCleanupDelivery(input: input, output: output, expected: input)
        }
    }

    @MainActor
    private func assertCleanupDelivery(input: String, output: String, expected: String) {
        let pipeline = TranscriptionPipeline()
        pipeline.cleanupEnabled = true
        pipeline.styleInstruction = "Use a formal style."
        pipeline.cleanupService = FixedCleanup(output: output)
        let token = pipeline.test_holdSnapshot(.unknown)
        pipeline.markHoldAbandoned(token)
        let completed = expectation(description: "cleanup delivered to in-memory history hook")
        pipeline.onAbandonedHoldSaved = { text, _, _ in XCTAssertEqual(text, expected) }
        pipeline.logStreamedTranscription(text: input, engineID: "fixture", sessionHeldToken: token,
            completion: { result in
                XCTAssertEqual(result, .savedToHistory)
                completed.fulfill()
            })
        wait(for: [completed], timeout: 5)
    }

    func testContractionEquivalentsPreserveNegationAndRoles() {
        for (input, output) in [
            ("We're ready but they aren't ready.", "We are ready but they are not ready."),
            ("I won't send it because you didn't approve.", "I will not send it because you did not approve."),
            ("We've checked and cannot send it.", "We have checked and can't send it.")
        ] {
            XCTAssertTrue(ASREngineSelector.cleanupLooksSane(input: input, output: output))
            XCTAssertTrue(ASREngineSelector.cleanupLooksSane(input: output, output: input))
        }
    }

    func testLexicalFillersAndStandaloneSentencesArePreserved() {
        for (input, output) in [
            ("I like you.", "I you."),
            ("You know Alice.", "Alice."),
            ("I think you know Alice.", "I think Alice."),
            ("Call Alice. You know.", "Call Alice."),
            ("Call Alice. Like.", "Call Alice."),
            ("Charge 12.50 today.", "Charge 12 50 today."),
            ("Use -5 degrees today.", "Use 5 degrees today.")
        ] {
            XCTAssertFalse(ASREngineSelector.cleanupLooksSane(input: input, output: output), input)
        }
    }

    func testReversedRolesRejectedEvenInSingleSentence() {
        XCTAssertFalse(ASREngineSelector.cleanupLooksSane(
            input: "Alice paid Bob yesterday.",
            output: "Bob paid Alice yesterday."
        ))
    }

    func testDroppedShortSentencesRejected() {
        for sentence in ["Call Alice.", "Wait.", "Call."] {
            XCTAssertFalse(ASREngineSelector.cleanupLooksSane(
                input: "Send the report today. " + sentence,
                output: "Send the report today."
            ), sentence)
        }
    }

    func testChangedShortClauseRejected() {
        XCTAssertFalse(ASREngineSelector.cleanupLooksSane(
            input: "Send the report today. Call Alice.",
            output: "Send the report today. Call Bob."
        ))
    }

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

    /// These may be fillers or intentional words; uncertainty preserves them.
    func testAmbiguousFillerAndRestartDeletionRejected() {
        XCTAssertFalse(ASREngineSelector.cleanupLooksSane(
            input: "so like I think we should um ship it on Friday. I mean the tests don't fail anymore.",
            output: "I think we should ship it on Friday. The tests don't fail anymore."
        ))
        XCTAssertFalse(ASREngineSelector.cleanupLooksSane(
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
