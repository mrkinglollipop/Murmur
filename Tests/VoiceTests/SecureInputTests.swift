import XCTest
@testable import Voice

final class SecureInputTests: XCTestCase {

    func testSecureInputActiveNeverLogsAndSurfacesSecureInputBlocked() {
        let outcome = TranscriptionPipeline.secureInputOutcome(secureInput: true, injected: false)
        XCTAssertFalse(outcome.shouldLog)
        XCTAssertEqual(outcome.failure, .secureInputBlocked)
    }

    func testInjectionFailedWithoutSecureInputLogsAndSurfacesInjectionFailed() {
        let outcome = TranscriptionPipeline.secureInputOutcome(secureInput: false, injected: false)
        XCTAssertTrue(outcome.shouldLog)
        XCTAssertEqual(outcome.failure, .injectionFailed)
    }

    func testSuccessfulInjectionWithoutSecureInputLogsWithNoFailure() {
        let outcome = TranscriptionPipeline.secureInputOutcome(secureInput: false, injected: true)
        XCTAssertTrue(outcome.shouldLog)
        XCTAssertNil(outcome.failure)
    }

    func testShouldAbortWhenSecureInputActivatesWhileRecording() {
        XCTAssertTrue(
            AudioRecorder.shouldAbortForSecureInput(secureInput: true, isRecording: true)
        )
    }

    func testShouldNotAbortWhenNotRecording() {
        XCTAssertFalse(
            AudioRecorder.shouldAbortForSecureInput(secureInput: true, isRecording: false)
        )
    }

    func testShouldNotAbortWhenSecureInputInactive() {
        XCTAssertFalse(
            AudioRecorder.shouldAbortForSecureInput(secureInput: false, isRecording: true)
        )
    }
}
