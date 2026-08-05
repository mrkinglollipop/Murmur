import AppKit
import XCTest
@testable import Voice

final class TextInjectorTests: XCTestCase {

  private static let testPasteboardName = NSPasteboard.Name("com.matt.voice-dictation.textinjector-tests")

  private var testPasteboard: NSPasteboard {
    NSPasteboard(name: Self.testPasteboardName)
  }

  override func setUp() {
    super.setUp()
    TextInjector.resetDedupeStateForTesting()
    TextInjector.deliveryLaneForTesting = nil
  }

  override func tearDown() {
    TextInjector.resetDedupeStateForTesting()
    TextInjector.deliveryLaneForTesting = nil
    testPasteboard.clearContents()
    super.tearDown()
  }

    // MARK: - Chunking

    func testChunkUTF16Units_emptyString() {
        XCTAssertTrue(TextInjector.chunkUTF16Units("").isEmpty)
    }

    func testChunkUTF16Units_singleChunk() {
        let text = "hello"
        let chunks = TextInjector.chunkUTF16Units(text)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0], Array(text.utf16))
    }

    func testChunkUTF16Units_exactlySixteenUnits() {
        let text = String(repeating: "a", count: 16)
        let chunks = TextInjector.chunkUTF16Units(text)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, 16)
    }

    func testChunkUTF16Units_seventeenUnitsSplitsIntoTwoChunks() {
        let text = String(repeating: "b", count: 17)
        let chunks = TextInjector.chunkUTF16Units(text)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].count, 16)
        XCTAssertEqual(chunks[1].count, 1)
        XCTAssertEqual(chunks.flatMap { $0 }, Array(text.utf16))
    }

    func testChunkUTF16Units_surrogatePairCountsAsTwoUTF16Units() {
        let text = "😀"
        XCTAssertEqual(text.utf16.count, 2)
        let chunks = TextInjector.chunkUTF16Units(text)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, 2)
    }

    func testChunkUTF16Units_customChunkSize() {
        let text = "abcdefgh"
        let chunks = TextInjector.chunkUTF16Units(text, maxChunkSize: 3)
        XCTAssertEqual(chunks.map(\.count), [3, 3, 2])
    }

    // MARK: - Fallback ordering

    func testResolveOutcome_confirmedOnFirstAttempt() {
        let outcome = TextInjector.resolveOutcome(
            confirmed: true,
            retryConfirmed: false,
            pidFallbackSucceeded: false
        )
        XCTAssertEqual(outcome.path, .confirmed)
        XCTAssertTrue(outcome.shouldReturnTrue)
    }

    func testResolveOutcome_confirmedIgnoresLaterFlags() {
        let outcome = TextInjector.resolveOutcome(
            confirmed: true,
            retryConfirmed: true,
            pidFallbackSucceeded: true
        )
        XCTAssertEqual(outcome.path, .confirmed)
        XCTAssertTrue(outcome.shouldReturnTrue)
    }

    func testResolveOutcome_confirmedOnRetry() {
        let outcome = TextInjector.resolveOutcome(
            confirmed: false,
            retryConfirmed: true,
            pidFallbackSucceeded: false
        )
        XCTAssertEqual(outcome.path, .confirmedOnRetry)
        XCTAssertTrue(outcome.shouldReturnTrue)
    }

    func testResolveOutcome_confirmedOnRetryIgnoresPidFallback() {
        let outcome = TextInjector.resolveOutcome(
            confirmed: false,
            retryConfirmed: true,
            pidFallbackSucceeded: true
        )
        XCTAssertEqual(outcome.path, .confirmedOnRetry)
        XCTAssertTrue(outcome.shouldReturnTrue)
    }

    func testResolveOutcome_unverifiedFallback() {
        let outcome = TextInjector.resolveOutcome(
            confirmed: false,
            retryConfirmed: false,
            pidFallbackSucceeded: true
        )
        XCTAssertEqual(outcome.path, .unverifiedFallback)
        XCTAssertTrue(outcome.shouldReturnTrue)
    }

    func testResolveOutcome_clipboardWhenAllFail() {
        let outcome = TextInjector.resolveOutcome(
            confirmed: false,
            retryConfirmed: false,
            pidFallbackSucceeded: false
        )
        XCTAssertEqual(outcome.path, .clipboard)
        XCTAssertFalse(outcome.shouldReturnTrue)
    }

    func testResolveOutcome_allEightInputCombinations() {
        let expectations: [(
            confirmed: Bool,
            retryConfirmed: Bool,
            pidFallbackSucceeded: Bool,
            path: TextInjector.InsertDeliveryPath,
            shouldReturnTrue: Bool
        )] = [
            (true, false, false, .confirmed, true),
            (true, false, true, .confirmed, true),
            (true, true, false, .confirmed, true),
            (true, true, true, .confirmed, true),
            (false, true, false, .confirmedOnRetry, true),
            (false, true, true, .confirmedOnRetry, true),
            (false, false, true, .unverifiedFallback, true),
            (false, false, false, .clipboard, false),
        ]

        for item in expectations {
            let outcome = TextInjector.resolveOutcome(
                confirmed: item.confirmed,
                retryConfirmed: item.retryConfirmed,
                pidFallbackSucceeded: item.pidFallbackSucceeded
            )
            XCTAssertEqual(
                outcome.path,
                item.path,
                "confirmed=\(item.confirmed) retry=\(item.retryConfirmed) pid=\(item.pidFallbackSucceeded)"
            )
            XCTAssertEqual(
                outcome.shouldReturnTrue,
                item.shouldReturnTrue,
                "confirmed=\(item.confirmed) retry=\(item.retryConfirmed) pid=\(item.pidFallbackSucceeded)"
            )
        }
    }

    // MARK: - Saved pasteboard restore decision

    func testResolveSavedPasteboardRestore_pasteSucceeded() {
        let decision = TextInjector.resolveSavedPasteboardRestore(
            pasteSucceeded: true,
            unicodeSucceeded: false,
            allLanesFailed: false
        )
        XCTAssertEqual(decision, .restoreSaved)
    }

    func testResolveSavedPasteboardRestore_pasteSucceededIgnoresFailureFlags() {
        let decision = TextInjector.resolveSavedPasteboardRestore(
            pasteSucceeded: true,
            unicodeSucceeded: false,
            allLanesFailed: true
        )
        XCTAssertEqual(decision, .restoreSaved)
    }

    func testResolveSavedPasteboardRestore_unicodeSucceededAfterPasteFailed() {
        let decision = TextInjector.resolveSavedPasteboardRestore(
            pasteSucceeded: false,
            unicodeSucceeded: true,
            allLanesFailed: false
        )
        XCTAssertEqual(decision, .restoreSaved)
    }

    func testResolveSavedPasteboardRestore_allLanesFailed() {
        let decision = TextInjector.resolveSavedPasteboardRestore(
            pasteSucceeded: false,
            unicodeSucceeded: false,
            allLanesFailed: true
        )
        XCTAssertEqual(decision, .doNotRestoreLeaveTranscript)
    }

    func testResolveSavedPasteboardRestore_deferWhileLanesPending() {
        let decision = TextInjector.resolveSavedPasteboardRestore(
            pasteSucceeded: false,
            unicodeSucceeded: false,
            allLanesFailed: false
        )
        XCTAssertEqual(decision, .deferRestore)
    }

    func testResolveSavedPasteboardRestore_allEightInputCombinations() {
        let expectations: [(
            pasteSucceeded: Bool,
            unicodeSucceeded: Bool,
            allLanesFailed: Bool,
            decision: TextInjector.SavedPasteboardRestoreDecision
        )] = [
            (true, false, false, .restoreSaved),
            (true, false, true, .restoreSaved),
            (true, true, false, .restoreSaved),
            (true, true, true, .restoreSaved),
            (false, true, false, .restoreSaved),
            (false, true, true, .restoreSaved),
            (false, false, true, .doNotRestoreLeaveTranscript),
            (false, false, false, .deferRestore),
        ]

        for item in expectations {
            let decision = TextInjector.resolveSavedPasteboardRestore(
                pasteSucceeded: item.pasteSucceeded,
                unicodeSucceeded: item.unicodeSucceeded,
                allLanesFailed: item.allLanesFailed
            )
            XCTAssertEqual(
                decision,
                item.decision,
                "paste=\(item.pasteSucceeded) unicode=\(item.unicodeSucceeded) failed=\(item.allLanesFailed)"
            )
        }
    }

    // MARK: - Pasteboard helpers (named test pasteboard only)

    func testSavedPasteboardString_nilWhenEmpty() {
        testPasteboard.clearContents()
        XCTAssertNil(TextInjector.savedPasteboardString(from: testPasteboard))
    }

    func testSavedPasteboardString_roundTripsExistingContent() {
        testPasteboard.clearContents()
        testPasteboard.setString("prior clipboard", forType: .string)
        XCTAssertEqual(
            TextInjector.savedPasteboardString(from: testPasteboard),
            "prior clipboard"
        )
    }

    func testPreparePasteboardForPaste_setsStringAndConcealedMarker() {
        testPasteboard.clearContents()
        TextInjector.preparePasteboardForPaste("hello transcript", on: testPasteboard)
        XCTAssertEqual(testPasteboard.string(forType: .string), "hello transcript")
        XCTAssertNotNil(testPasteboard.data(forType: TextInjector.concealedPasteboardType))
    }

    func testRestorePasteboardSnapshot_restoresPriorString() {
        testPasteboard.clearContents()
        testPasteboard.setString("saved snapshot", forType: .string)
        let saved = TextInjector.savedPasteboardString(from: testPasteboard)

        TextInjector.preparePasteboardForPaste("injected", on: testPasteboard)
        XCTAssertEqual(testPasteboard.string(forType: .string), "injected")

        TextInjector.restorePasteboardSnapshot(saved, on: testPasteboard)
        XCTAssertEqual(testPasteboard.string(forType: .string), "saved snapshot")
    }

    func testRestorePasteboardSnapshot_clearsWhenPriorWasEmpty() {
        testPasteboard.clearContents()
        let saved = TextInjector.savedPasteboardString(from: testPasteboard)
        XCTAssertNil(saved)

        TextInjector.preparePasteboardForPaste("injected", on: testPasteboard)
        TextInjector.restorePasteboardSnapshot(saved, on: testPasteboard)
        XCTAssertNil(testPasteboard.string(forType: .string))
    }

    // MARK: - Pasteboard race helpers (Universal Clipboard gate)

    func testPasteboardHoldsExpectedString_match() {
        testPasteboard.clearContents()
        testPasteboard.setString("transcript", forType: .string)
        XCTAssertTrue(
            TextInjector.pasteboardHoldsExpectedString("transcript", on: testPasteboard)
        )
    }

    func testPasteboardHoldsExpectedString_mismatch() {
        testPasteboard.clearContents()
        testPasteboard.setString("stale phone copy", forType: .string)
        XCTAssertFalse(
            TextInjector.pasteboardHoldsExpectedString("fresh dictation", on: testPasteboard)
        )
    }

    func testPreparePasteboardForPasteStable_succeeds() {
        testPasteboard.clearContents()
        XCTAssertTrue(
            TextInjector.preparePasteboardForPasteStable("stable transcript", on: testPasteboard)
        )
        XCTAssertEqual(testPasteboard.string(forType: .string), "stable transcript")
        XCTAssertNotNil(testPasteboard.data(forType: TextInjector.concealedPasteboardType))
    }

    func testShouldRestoreSavedPasteboard_trueWhenInjectedTextPresent() {
        testPasteboard.clearContents()
        TextInjector.preparePasteboardForPaste("injected", on: testPasteboard)
        XCTAssertTrue(
            TextInjector.shouldRestoreSavedPasteboard(injectedText: "injected", on: testPasteboard)
        )
    }

    func testShouldRestoreSavedPasteboard_falseWhenOverwritten() {
        testPasteboard.clearContents()
        TextInjector.preparePasteboardForPaste("injected", on: testPasteboard)
        testPasteboard.clearContents()
        testPasteboard.setString("continuity overwrite", forType: .string)
        XCTAssertFalse(
            TextInjector.shouldRestoreSavedPasteboard(injectedText: "injected", on: testPasteboard)
        )
    }

    // MARK: - Dedupe helper (Tier A)

    func testShouldSuppressDuplicateInsert_sameTextInsideWindow() {
        let now = Date()
        let prior = now.addingTimeInterval(-0.5)
        XCTAssertTrue(
            TextInjector.shouldSuppressDuplicateInsert(
                candidate: "hello",
                lastDeliveredText: "hello",
                lastDeliveredAt: prior,
                now: now,
                window: 1.0
            )
        )
    }

    func testShouldSuppressDuplicateInsert_expiredWindow() {
        let now = Date()
        let prior = now.addingTimeInterval(-1.5)
        XCTAssertFalse(
            TextInjector.shouldSuppressDuplicateInsert(
                candidate: "hello",
                lastDeliveredText: "hello",
                lastDeliveredAt: prior,
                now: now,
                window: 1.0
            )
        )
    }

    func testShouldSuppressDuplicateInsert_differentText() {
        let now = Date()
        let prior = now.addingTimeInterval(-0.5)
        XCTAssertFalse(
            TextInjector.shouldSuppressDuplicateInsert(
                candidate: "hello",
                lastDeliveredText: "world",
                lastDeliveredAt: prior,
                now: now,
                window: 1.0
            )
        )
    }

    func testShouldSuppressDuplicateInsert_noPriorDelivery() {
        let now = Date()
        XCTAssertFalse(
            TextInjector.shouldSuppressDuplicateInsert(
                candidate: "hello",
                lastDeliveredText: nil,
                lastDeliveredAt: nil,
                now: now,
                window: 1.0
            )
        )
    }

    // Failed prior delivery leaves lastDelivered* nil at the call site; the helper
    // treats nil,nil the same as no prior successful delivery (case 4).

    // MARK: - Dedupe insert (Tier B)

    func testInsert_failedDeliveryThenRetryWithinWindow_notSuppressed() {
        var callCount = 0
        TextInjector.deliveryLaneForTesting = { _ in
            callCount += 1
            return callCount > 1
        }

        let injector = TextInjector()
        let text = "retry after failure"

        XCTAssertEqual(injector.insert(text), .failed)
        XCTAssertEqual(injector.insert(text), .inserted(deliveredText: text))
        XCTAssertEqual(callCount, 2)
    }

    func testInsert_concurrentSameText_singleDelivery() {
        let countLock = NSLock()
        var deliveryCount = 0
        TextInjector.deliveryLaneForTesting = { _ in
            countLock.lock()
            deliveryCount += 1
            countLock.unlock()
            return true
        }

        let injector = TextInjector()
        let text = "concurrent dedupe test"
        let iterations = 8

        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            _ = injector.insert(text)
        }

        XCTAssertEqual(deliveryCount, 1)
    }
}
