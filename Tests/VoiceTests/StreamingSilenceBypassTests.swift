import AVFoundation
import XCTest
@testable import Voice

/// Silence-cancel predicate + Class A residual recovery for ghost dictation.
final class StreamingSilenceBypassTests: XCTestCase {

    func testSilenceCancelOnlyWhenNoStreamTextAndNoBuffers() {
        XCTAssertTrue(
            StreamingCoordinator.shouldTakeSilenceCancel(
                everHadStreamText: false,
                hasBufferedAudio: false
            )
        )
        XCTAssertFalse(
            StreamingCoordinator.shouldTakeSilenceCancel(
                everHadStreamText: true,
                hasBufferedAudio: false
            ),
            "Class A: interim words must bypass silence cancel"
        )
        XCTAssertFalse(
            StreamingCoordinator.shouldTakeSilenceCancel(
                everHadStreamText: false,
                hasBufferedAudio: true
            ),
            "Class B: non-empty pcmBuffers must bypass silence cancel"
        )
        XCTAssertFalse(
            StreamingCoordinator.shouldTakeSilenceCancel(
                everHadStreamText: true,
                hasBufferedAudio: true
            )
        )
    }

    /// Production file path (`stopFileBasedCapture`): empty buffers abort;
    /// non-empty buffers always proceed (no dead bypass helper).
    func testFilePathProceedsWhenBuffersNonEmpty() {
        // Empty buffers → silence cancel would apply only when also no stream text.
        XCTAssertTrue(
            StreamingCoordinator.shouldTakeSilenceCancel(
                everHadStreamText: false,
                hasBufferedAudio: false
            ),
            "empty buffers + no stream text → cancel/discard path"
        )
        // Non-empty buffers always bypass silence cancel — file path writes them.
        XCTAssertFalse(
            StreamingCoordinator.shouldTakeSilenceCancel(
                everHadStreamText: false,
                hasBufferedAudio: true
            ),
            "non-empty buffers always proceed to writeToFile"
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
