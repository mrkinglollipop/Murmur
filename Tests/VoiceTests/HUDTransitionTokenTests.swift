import XCTest
@testable import Voice

/// Pure-logic coverage for `HUDTransitionToken`, the generation-counter guard
/// `RecordingHUD` uses to serialize state transitions (cancel outstanding
/// hide/flash timers, and reject a stale fade-out completion that would
/// otherwise race a newer show()). No Timers, no NSAnimationContext, no
/// real windows — just the token's own bookkeeping.
final class HUDTransitionTokenTests: XCTestCase {

    func testStartsAtGenerationZero() {
        let token = HUDTransitionToken()
        XCTAssertEqual(token.generation, 0)
    }

    func testAdvanceIncrementsAndReturnsNewGeneration() {
        var token = HUDTransitionToken()
        XCTAssertEqual(token.advance(), 1)
        XCTAssertEqual(token.advance(), 2)
        XCTAssertEqual(token.generation, 2)
    }

    func testIsCurrentTrueForLatestGeneration() {
        var token = HUDTransitionToken()
        let generation = token.advance()
        XCTAssertTrue(token.isCurrent(generation))
    }

    func testIsCurrentFalseAfterASubsequentTransition() {
        // Models the flicker bug: a callback captures generation N (e.g. a
        // hide() fade-out completion or an auto-hide timer), then a newer
        // transition (show(), a fresh hide(), an error) bumps past it before
        // the callback fires — the callback must recognize itself as stale.
        var token = HUDTransitionToken()
        let staleGeneration = token.advance()
        _ = token.advance()
        XCTAssertFalse(token.isCurrent(staleGeneration))
    }

    func testOnlyTheMostRecentGenerationIsCurrent() {
        var token = HUDTransitionToken()
        let first = token.advance()
        let second = token.advance()
        let third = token.advance()
        XCTAssertFalse(token.isCurrent(first))
        XCTAssertFalse(token.isCurrent(second))
        XCTAssertTrue(token.isCurrent(third))
    }

    func testEquatableComparesGeneration() {
        var a = HUDTransitionToken()
        var b = HUDTransitionToken()
        XCTAssertEqual(a, b)
        _ = a.advance()
        XCTAssertNotEqual(a, b)
        _ = b.advance()
        XCTAssertEqual(a, b)
    }
}
