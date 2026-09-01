import AVFoundation
import XCTest
@testable import Voice

/// Silence-cancel predicate + Class A residual recovery for ghost dictation.
///
/// The predicate gained a duration floor on 2026-08-10: a 0.33 s dead-silent
/// tap cascaded through batch "No transcript" into a cold WhisperKit load and
/// a 120 s timeout error, while a 1.93 s quiet hold (also under the RMS
/// threshold) was legitimately rescued by the same fallback. Duration is the
/// discriminator; loudness is deliberately NOT consulted.
final class StreamingSilenceBypassTests: XCTestCase {

    private let floor = StreamingCoordinator.silenceCancelMaxBufferedSeconds

    func testSilenceCancelWhenNoStreamTextAndNoAudio() {
        XCTAssertTrue(
            StreamingCoordinator.shouldTakeSilenceCancel(
                everHadStreamText: false,
                bufferedSeconds: 0
            )
        )
        XCTAssertFalse(
            StreamingCoordinator.shouldTakeSilenceCancel(
                everHadStreamText: true,
                bufferedSeconds: 0
            ),
            "Class A: interim words must bypass silence cancel"
        )
    }

    func testTinyHoldBelowFloorIsDiscarded() {
        // The live 2026-08-10 cascade: 0.33 s of dead air must not summon
        // the batch→local fallback chain.
        XCTAssertTrue(
            StreamingCoordinator.shouldTakeSilenceCancel(
                everHadStreamText: false,
                bufferedSeconds: 0.33
            )
        )
    }

    func testQuietButRealHoldAboveFloorIsRescued() {
        // The live counter-case: 1.93 s under the RMS threshold produced 14
        // injected chars via batch fallback. Must keep bypassing.
        XCTAssertFalse(
            StreamingCoordinator.shouldTakeSilenceCancel(
                everHadStreamText: false,
                bufferedSeconds: 1.93
            )
        )
    }

    func testStreamTextAlwaysBypassesEvenWhenTiny() {
        XCTAssertFalse(
            StreamingCoordinator.shouldTakeSilenceCancel(
                everHadStreamText: true,
                bufferedSeconds: 0.1
            )
        )
    }

    func testFloorBoundary() {
        XCTAssertTrue(
            StreamingCoordinator.shouldTakeSilenceCancel(
                everHadStreamText: false,
                bufferedSeconds: floor - 0.01
            )
        )
        XCTAssertTrue(
            StreamingCoordinator.shouldTakeSilenceCancel(
                everHadStreamText: false,
                bufferedSeconds: floor
            ),
            "exactly at the floor is silence — inclusive <= (0.5 s CAF ghost fail 2026-08-31)"
        )
        XCTAssertFalse(
            StreamingCoordinator.shouldTakeSilenceCancel(
                everHadStreamText: false,
                bufferedSeconds: floor + 0.01
            ),
            "just above the floor still proceeds to batch rescue"
        )
    }

    func testBufferedSecondsSumsFrames() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        func buffer(frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            b.frameLength = frames
            return b
        }
        XCTAssertEqual(StreamingCoordinator.bufferedSeconds([]), 0)
        XCTAssertEqual(
            StreamingCoordinator.bufferedSeconds([buffer(frames: 24_000)]),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            StreamingCoordinator.bufferedSeconds(
                [buffer(frames: 48_000), buffer(frames: 24_000)]
            ),
            1.5,
            accuracy: 0.0001
        )
    }

    func testEmptyFinalizeRecoversPreFinalizeSnapshot() {
        let recovered = StreamingCoordinator.streamSuccessTextOrBatchFallback(
            finalizeText: "",
            preFinalizeSnapshot: "hello there",
            truncated: false
        )
        XCTAssertEqual(recovered, "hello there")
    }

    func testEmptyFinalizeWithEmptySnapshotFallsBackToBatch() {
        XCTAssertNil(
            StreamingCoordinator.streamSuccessTextOrBatchFallback(
                finalizeText: "",
                preFinalizeSnapshot: "   ",
                truncated: false
            )
        )
    }

    func testNonEmptyFinalizePrefersFinalizeText() {
        XCTAssertEqual(
            StreamingCoordinator.streamSuccessTextOrBatchFallback(
                finalizeText: "final words",
                preFinalizeSnapshot: "stale",
                truncated: false
            ),
            "final words"
        )
    }

    func testTruncatedFinalizeFallsBackEvenWithSnapshot() {
        XCTAssertNil(
            StreamingCoordinator.streamSuccessTextOrBatchFallback(
                finalizeText: "hi",
                preFinalizeSnapshot: "longer snapshot text",
                truncated: true
            ),
            "truncated non-empty finalize still takes batch fallback when snapshot does not extend"
        )
    }

    func testTailLossRecoversSnapshotWhenFinalizeIsPrefix() {
        let finalize = "I notice it happens with longer dictations."
        let snapshot = finalize + " That's when I'm noticing it."
        XCTAssertEqual(
            StreamingCoordinator.streamSuccessTextOrBatchFallback(
                finalizeText: finalize,
                preFinalizeSnapshot: snapshot,
                duration: 22,
                truncated: false
            ),
            "I notice it happens with longer dictations. That's when I'm noticing it."
        )
    }

    func testTailLossRecoversSnapshotOnLongHoldEvenWhenFinalizeIsNonEmpty() {
        let firstHalf = String(repeating: "word ", count: 80).trimmingCharacters(in: .whitespaces)
        let secondHalf = "and this is the missing tail at the end."
        let snapshot = firstHalf + " " + secondHalf
        let finalize = firstHalf
        XCTAssertEqual(
            StreamingCoordinator.streamSuccessTextOrBatchFallback(
                finalizeText: finalize,
                preFinalizeSnapshot: snapshot,
                duration: 90,
                truncated: false
            ),
            snapshot
        )
    }

    func testTruncatedFinalizeStillRecoversWhenSnapshotExtends() {
        let finalize = "short"
        let snapshot = "short but the hud had the whole sentence here"
        XCTAssertEqual(
            StreamingCoordinator.streamSuccessTextOrBatchFallback(
                finalizeText: finalize,
                preFinalizeSnapshot: snapshot,
                duration: 20,
                truncated: true
            ),
            "short but the hud had the whole sentence here"
        )
    }

    func testLongHoldLengthMismatchWithoutExtensionFallsBackToBatch() {
        XCTAssertNil(
            StreamingCoordinator.streamSuccessTextOrBatchFallback(
                finalizeText: "hello the world",
                preFinalizeSnapshot: "completely different much longer snapshot text that diverged",
                duration: 60,
                truncated: false
            ),
            "long hold with diverged snapshot must batch re-decode from buffered audio"
        )
    }

    func testShortHoldLengthMismatchDoesNotForceBatch() {
        XCTAssertEqual(
            StreamingCoordinator.streamSuccessTextOrBatchFallback(
                finalizeText: "hello the world",
                preFinalizeSnapshot: "completely different much longer snapshot text",
                duration: 10,
                truncated: false
            ),
            "hello the world",
            "below duration floor, prefer finalize over batch"
        )
    }

    func testSnapshotExtendsFinalizeCaseInsensitive() {
        XCTAssertTrue(
            StreamingCoordinator.snapshotExtendsFinalize(
                finalize: "Hello There",
                snapshot: "hello there friend"
            )
        )
    }

    func testSnapshotDoesNotExtendWhenUnrelated() {
        XCTAssertFalse(
            StreamingCoordinator.snapshotExtendsFinalize(
                finalize: "final words",
                snapshot: "stale"
            )
        )
    }

    func testSnapshotExtendsWhenFinalizeAddsTrailingPunctuation() {
        XCTAssertTrue(
            StreamingCoordinator.snapshotExtendsFinalize(
                finalize: "I notice it happens with longer dictations.",
                snapshot: "I notice it happens with longer dictations that's when I'm noticing it"
            )
        )
        XCTAssertEqual(
            StreamingCoordinator.streamSuccessTextOrBatchFallback(
                finalizeText: "I notice it happens with longer dictations.",
                preFinalizeSnapshot: "I notice it happens with longer dictations that's when I'm noticing it",
                duration: 22,
                truncated: false
            ),
            "I notice it happens with longer dictations. That's when I'm noticing it"
        )
    }

    func testTruncatedExtendingSnapshotStillBelowCpsFallsBackToBatch() {
        XCTAssertNil(
            StreamingCoordinator.streamSuccessTextOrBatchFallback(
                finalizeText: "short",
                preFinalizeSnapshot: "short and extra",
                duration: 20,
                truncated: true
            ),
            "snapshot that still fails the cps floor must batch, not inject a short HUD"
        )
    }

    func testPostReleaseCaptureGraceScalesForLongHolds() {
        XCTAssertEqual(
            AudioRecorder.postReleaseCaptureGrace(forHoldDuration: 10),
            0.250,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioRecorder.postReleaseCaptureGrace(forHoldDuration: 60),
            0.475,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioRecorder.postReleaseCaptureGrace(forHoldDuration: 180),
            1.0,
            accuracy: 0.0001,
            "long holds cap at one second of post-release capture"
        )
    }

    func testSnapshotSupersetContainsFinalizeHeadLoss() {
        let finalize = "Rest of the sentence."
        let snapshot = "First sentence. Rest of the sentence."
        XCTAssertTrue(
            StreamingCoordinator.snapshotSupersetContainsFinalize(
                finalize: finalize,
                snapshot: snapshot
            )
        )
        XCTAssertEqual(
            StreamingCoordinator.streamSuccessTextOrBatchFallback(
                finalizeText: finalize,
                preFinalizeSnapshot: snapshot,
                duration: 22,
                truncated: false
            ),
            "First sentence. Rest of the sentence."
        )
    }

    func testSnapshotSupersetRecoversHeadLossDespiteFinalizePunctuation() {
        let finalize = "then we went home."
        let snapshot = "so first we ate then we went home"
        XCTAssertTrue(
            StreamingCoordinator.snapshotSupersetContainsFinalize(
                finalize: finalize,
                snapshot: snapshot
            )
        )
        XCTAssertEqual(
            StreamingCoordinator.streamSuccessTextOrBatchFallback(
                finalizeText: finalize,
                preFinalizeSnapshot: snapshot,
                duration: 22,
                truncated: false
            ),
            "so first we ate. then we went home."
        )
    }

    func testTailRecoveryKeepsFinalizeWithoutSnapshotFiller() {
        XCTAssertEqual(
            StreamingCoordinator.streamSuccessTextOrBatchFallback(
                finalizeText: "we should go.",
                preFinalizeSnapshot: "we should go you know",
                duration: 12,
                truncated: false
            ),
            "we should go."
        )
    }

    func testSnapshotSupersetDoesNotRecoverUnrelatedText() {
        XCTAssertFalse(
            StreamingCoordinator.snapshotSupersetContainsFinalize(
                finalize: "hello the world",
                snapshot: "completely different much longer snapshot text"
            )
        )
    }

    func testSnapshotSupersetRejectsTriviallyShortFinalizeWithoutMeaningfulExtra() {
        XCTAssertFalse(
            StreamingCoordinator.snapshotSupersetContainsFinalize(
                finalize: "ok",
                snapshot: "ok then"
            )
        )
    }
}
