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
        XCTAssertFalse(
            StreamingCoordinator.shouldTakeSilenceCancel(
                everHadStreamText: false,
                bufferedSeconds: floor
            ),
            "exactly at the floor proceeds — the floor is a strict less-than"
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
            "truncated non-empty finalize still takes batch fallback"
        )
    }
}
