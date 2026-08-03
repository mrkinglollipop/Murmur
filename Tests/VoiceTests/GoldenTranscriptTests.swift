import XCTest
@testable import Voice

/// Golden chunk sequences for xAI segment-local finals. Each test folds a
/// sequence left-to-right via `mergeSegmentIntoConfirmed`, mirroring how
/// `ingestFinalSegment` stitches disjoint ~3s chunks.
final class GoldenTranscriptTests: XCTestCase {

    private func stitchSequence(_ chunks: [String]) -> String {
        guard let first = chunks.first else { return "" }
        var accumulated = first
        var committedWords: [TranscriptWord] = []
        var lastEnd: Double = 0
        for chunk in chunks.dropFirst() {
            let merged = XAIStreamingTranscriber.mergeSegmentIntoConfirmed(
                confirmed: accumulated,
                text: chunk,
                incomingWords: [],
                committedWords: committedWords,
                lastCommittedEnd: lastEnd
            )
            accumulated = merged.confirmedText
            committedWords = merged.committedWords
            lastEnd = merged.lastCommittedEnd
        }
        return accumulated
    }

    func testTwoChunkOverlap() {
        let chunks = [
            "We need to finish the report",
            "finish the report by Friday"
        ]
        XCTAssertEqual(
            stitchSequence(chunks),
            "We need to finish the report by Friday"
        )
    }

    func testThreeChunkDictation() {
        let chunks = [
            "The quick brown fox",
            "brown fox jumps over",
            "jumps over the lazy dog"
        ]
        XCTAssertEqual(
            stitchSequence(chunks),
            "The quick brown fox jumps over the lazy dog"
        )
    }

    func testDisjointChunksSpaceSeparated() {
        let chunks = [
            "First segment ends here",
            "Second segment starts fresh"
        ]
        XCTAssertEqual(
            stitchSequence(chunks),
            "First segment ends here Second segment starts fresh"
        )
    }

    func testMattFireclawFireCrawlGolden() {
        let prefix =
            "I'm wondering if we need to do option C. The reason being is I don't think the local is even working anymore. I had so many issues with getting it to run. Go ahead and verify, audit it, et cetera."
        let chunks = [
            prefix + " If I recall correctly, the conclusion I came to is I was just better off using Fireclaw for all my searches.",
            "If I recall correctly, the conclusion I came to is I was just better off using FireCrawl for all my searches."
        ]
        let stitched = stitchSequence(chunks)
        let expected =
            prefix + " If I recall correctly, the conclusion I came to is I was just better off using FireCrawl for all my searches."
        XCTAssertEqual(stitched, expected)
    }

    func testStitchedThenDedupedGolden() {
        // Exact half duplication — collapseNearDuplicateTail requires token drift;
        // dedupeRepeatedContent still collapses aligned half-and-half duplicates.
        let half = "Dictated paragraph one with enough length"
        let stitched = stitchSequence([half, half])
        XCTAssertEqual(
            XAIStreamingTranscriber.postProcessTranscript(stitched),
            half
        )
    }
}
