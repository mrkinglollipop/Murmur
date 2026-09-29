import XCTest
@testable import Voice

/// Accidental-tap discard and the processing-HUD watchdog. A fn tap released
/// almost immediately used to leave "Transcribing…" up for 15-20 s (batch
/// upload + local fallback) with no History row.
final class StuckProcessingHUDTests: XCTestCase {

    // MARK: - Accidental tap

    func testAccidentalTapTruthTable() {
        // (holdDuration, streamTextEver) -> discard
        XCTAssertTrue(AudioRecorder.shouldDiscardAccidentalTap(holdDuration: 0.0, streamTextEver: false))
        XCTAssertTrue(AudioRecorder.shouldDiscardAccidentalTap(holdDuration: 0.12, streamTextEver: false))
        XCTAssertTrue(AudioRecorder.shouldDiscardAccidentalTap(holdDuration: 0.299, streamTextEver: false))
        // Boundary is exclusive: a 0.3 s hold is a real (if short) hold.
        XCTAssertFalse(AudioRecorder.shouldDiscardAccidentalTap(holdDuration: 0.3, streamTextEver: false))
        XCTAssertFalse(AudioRecorder.shouldDiscardAccidentalTap(holdDuration: 1.5, streamTextEver: false))
        // Any stream text means speech landed — never discard.
        XCTAssertFalse(AudioRecorder.shouldDiscardAccidentalTap(holdDuration: 0.12, streamTextEver: true))
        XCTAssertFalse(AudioRecorder.shouldDiscardAccidentalTap(holdDuration: 1.5, streamTextEver: true))
        // Unknown duration (mic never started) is left to the failure paths.
        XCTAssertFalse(AudioRecorder.shouldDiscardAccidentalTap(holdDuration: nil, streamTextEver: false))
        XCTAssertFalse(AudioRecorder.shouldDiscardAccidentalTap(holdDuration: nil, streamTextEver: true))
    }

    /// The post-release grace inflates buffered audio past the silence guard's
    /// floor, so the tap decision must sit below the grace, not include it.
    func testAccidentalTapThresholdIsBelowPostReleaseGrace() {
        XCTAssertLessThan(
            AudioRecorder.accidentalTapMaxHoldSeconds,
            AudioRecorder.postReleaseCaptureGraceForTesting
        )
    }

    // MARK: - Watchdog bound

    func testWatchdogBoundScalesWithAudioDuration() {
        XCTAssertEqual(AudioRecorder.processingHUDWatchdogBound(audioDuration: 0), 20, accuracy: 0.001)
        XCTAssertEqual(AudioRecorder.processingHUDWatchdogBound(audioDuration: 5), 25, accuracy: 0.001)
        XCTAssertEqual(AudioRecorder.processingHUDWatchdogBound(audioDuration: 90), 110, accuracy: 0.001)
    }

    func testWatchdogBoundIgnoresNonsenseDurations() {
        XCTAssertEqual(AudioRecorder.processingHUDWatchdogBound(audioDuration: -4), 20, accuracy: 0.001)
        XCTAssertEqual(AudioRecorder.processingHUDWatchdogBound(audioDuration: .nan), 20, accuracy: 0.001)
        XCTAssertEqual(AudioRecorder.processingHUDWatchdogBound(audioDuration: .infinity), 20, accuracy: 0.001)
    }

    // MARK: - Watchdog firing

    func testWatchdogFiresOnlyForCurrentGenerationWhileProcessing() {
        XCTAssertTrue(AudioRecorder.shouldFireProcessingWatchdog(
            generation: 4, currentGeneration: 4, hudIsProcessing: true))
        // Cancelled on normal completion / superseded by a newer hold.
        XCTAssertFalse(AudioRecorder.shouldFireProcessingWatchdog(
            generation: 4, currentGeneration: 5, hudIsProcessing: true))
        // HUD already left processing (failure pill, success, newer hold).
        XCTAssertFalse(AudioRecorder.shouldFireProcessingWatchdog(
            generation: 4, currentGeneration: 4, hudIsProcessing: false))
    }

    // MARK: - Abandoned hold reaches History without insertion

    private struct Logged {
        let text: String
        let injected: Bool
        let failed: Bool
        let replaceID: UUID?
    }

    private func finish(
        pipeline: TranscriptionPipeline,
        text: String,
        token: UInt64,
        replaceID: UUID? = nil
    ) -> (result: TranscriptionPipeline.InjectPipelineResult, logged: [Logged], failures: Int) {
        var logged: [Logged] = []
        var failures = 0
        pipeline.onTranscriptionLogged = { text, _, injected, _, failed, replaceID in
            logged.append(Logged(text: text, injected: injected, failed: failed, replaceID: replaceID))
        }
        pipeline.onFailure = { _ in failures += 1 }
        let done = expectation(description: "pipeline completion")
        var result: TranscriptionPipeline.InjectPipelineResult = .failed
        pipeline.finishTranscription(
            text: text,
            hadExplicitTrailingNewline: false,
            engineID: "test",
            audioPath: nil,
            replaceHistoryEntryID: replaceID,
            sessionHeldToken: token,
            sessionHeldSnapshot: nil,
            sessionHeldFrontmostPID: nil
        ) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return (result, logged, failures)
    }

    func testAbandonedHoldIsSavedToHistoryWithoutInsertion() {
        let pipeline = TranscriptionPipeline()
        pipeline.markHoldAbandoned(42)
        let out = finish(pipeline: pipeline, text: "late result", token: 42)
        XCTAssertEqual(out.result, .savedToHistory)
        XCTAssertEqual(out.logged.count, 1)
        XCTAssertEqual(out.logged.first?.text, "late result")
        XCTAssertEqual(out.logged.first?.injected, false)
        XCTAssertEqual(out.logged.first?.failed, false)
        XCTAssertNil(out.logged.first?.replaceID)
        XCTAssertEqual(out.failures, 0)
        XCTAssertTrue(pipeline.test_abandonedHoldTokens.isEmpty, "abandonment is one-shot")
    }

    func testAbandonedHoldWithEmptyResultRaisesNoLateErrorPill() {
        let pipeline = TranscriptionPipeline()
        pipeline.markHoldAbandoned(7)
        let out = finish(pipeline: pipeline, text: "   ", token: 7)
        XCTAssertEqual(out.result, .failed)
        XCTAssertEqual(out.failures, 0)
        XCTAssertTrue(pipeline.test_abandonedHoldTokens.isEmpty)
    }

    func testRetryNeverConsumesAbandonment() {
        let pipeline = TranscriptionPipeline()
        pipeline.markHoldAbandoned(9)
        let retryID = UUID()
        let out = finish(pipeline: pipeline, text: "retried", token: 9, replaceID: retryID)
        XCTAssertEqual(out.result, .savedToHistory)
        XCTAssertEqual(out.logged.first?.replaceID, retryID)
        XCTAssertEqual(pipeline.test_abandonedHoldTokens, [9])
    }

    func testAbandonedTokenSetIsCapped() {
        let pipeline = TranscriptionPipeline()
        for token in 1 ... 40 { pipeline.markHoldAbandoned(UInt64(token)) }
        XCTAssertLessThanOrEqual(pipeline.test_abandonedHoldTokens.count, 8)
        XCTAssertTrue(pipeline.test_abandonedHoldTokens.contains(40), "newest hold is kept")
    }
}
