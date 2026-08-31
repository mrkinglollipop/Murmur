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

    // MARK: - Delayed-vs-dropped delivery follow-up (2026-08-31 double-injection fix)

    func testDeliveryFollowUp_observedMeetsTarget_confirmed() {
        XCTAssertEqual(TextInjector.deliveryFollowUp(observed: 5, target: 5), .confirmed)
    }

    func testDeliveryFollowUp_observedExceedsTarget_confirmed() {
        XCTAssertEqual(TextInjector.deliveryFollowUp(observed: 7, target: 5), .confirmed)
    }

    func testDeliveryFollowUp_observedZero_retryEligible() {
        XCTAssertEqual(TextInjector.deliveryFollowUp(observed: 0, target: 5), .retryEligible)
    }

    func testDeliveryFollowUp_observedZeroTargetZero_confirmed() {
        // Degenerate case (nothing was posted, nothing to observe) counts as
        // met rather than eligible for a retry that would post nothing again.
        XCTAssertEqual(TextInjector.deliveryFollowUp(observed: 0, target: 0), .confirmed)
    }

    func testDeliveryFollowUp_observedBetweenZeroAndTarget_acceptPartial() {
        XCTAssertEqual(TextInjector.deliveryFollowUp(observed: 1, target: 5), .acceptPartial)
        XCTAssertEqual(TextInjector.deliveryFollowUp(observed: 4, target: 5), .acceptPartial)
    }

    func testNextConfirmationDeadline_extendsByProgressExtension() {
        let start = Date()
        let currentDeadline = start.addingTimeInterval(0.4)
        let next = TextInjector.nextConfirmationDeadline(
            startedAt: start,
            currentDeadline: currentDeadline,
            progressExtension: 0.4,
            maxWait: 2.5
        )
        XCTAssertEqual(next.timeIntervalSince(start), 0.8, accuracy: 0.0001)
    }

    func testNextConfirmationDeadline_capsAtMaxWaitFromStart() {
        let start = Date()
        let currentDeadline = start.addingTimeInterval(2.3)
        let next = TextInjector.nextConfirmationDeadline(
            startedAt: start,
            currentDeadline: currentDeadline,
            progressExtension: 0.4,
            maxWait: 2.5
        )
        XCTAssertEqual(next.timeIntervalSince(start), 2.5, accuracy: 0.0001)
    }

    func testNextConfirmationDeadline_neverExceedsMaxWaitAcrossRepeatedProgress() {
        let start = Date()
        var deadline = start.addingTimeInterval(0.4)
        for _ in 0..<20 {
            deadline = TextInjector.nextConfirmationDeadline(
                startedAt: start,
                currentDeadline: deadline,
                progressExtension: 0.4,
                maxWait: 2.5
            )
        }
        XCTAssertLessThanOrEqual(deadline.timeIntervalSince(start), 2.5 + 0.0001)
    }

    // MARK: - Saved pasteboard restore decision

    func testResolveSavedPasteboardRestore_pasteSucceeded() {
        let decision = TextInjector.resolveSavedPasteboardRestore(
            pasteSucceeded: true,
            unicodeSucceeded: false,
            allLanesFailed: false
        )
        XCTAssertEqual(decision, .restoreSavedDeferred)
    }

    func testResolveSavedPasteboardRestore_pasteSucceededIgnoresFailureFlags() {
        let decision = TextInjector.resolveSavedPasteboardRestore(
            pasteSucceeded: true,
            unicodeSucceeded: false,
            allLanesFailed: true
        )
        XCTAssertEqual(decision, .restoreSavedDeferred)
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
            (true, false, false, .restoreSavedDeferred),
            (true, false, true, .restoreSavedDeferred),
            (true, true, false, .restoreSavedDeferred),
            (true, true, true, .restoreSavedDeferred),
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

    /// Paste-lane restore must outlast slow Electron/Cursor consumers — sync
    /// restore after pasteConsumerDelay alone pastes the prior clipboard.
    func testPasteboardRestoreDelay_outlastsConsumerYield() {
        XCTAssertGreaterThan(TextInjector.pasteboardRestoreDelay, 0.25)
        XCTAssertGreaterThanOrEqual(TextInjector.pasteboardRestoreDelay, 2.0)
    }

    func testScheduleDeferredPasteboardRestore_runsAfterDelayWhenTextStillPresent() {
        TextInjector.resetDeferredRestoreGenerationForTesting()
        testPasteboard.clearContents()
        testPasteboard.setString("prior clipboard", forType: .string)
        let saved = TextInjector.pasteboardSnapshot(from: testPasteboard)

        TextInjector.preparePasteboardForPaste("injected transcript", on: testPasteboard)

        var scheduledDelay: TimeInterval?
        var work: (() -> Void)?
        TextInjector.scheduleDeferredPasteboardRestore(
            injectedText: "injected transcript",
            savedPasteboard: saved,
            on: testPasteboard,
            delay: 2.0,
            asyncAfter: { delay, block in
                scheduledDelay = delay
                work = block
            }
        )

        XCTAssertEqual(scheduledDelay, 2.0)
        XCTAssertEqual(testPasteboard.string(forType: .string), "injected transcript",
                       "must not restore synchronously")

        work?()
        XCTAssertEqual(testPasteboard.string(forType: .string), "prior clipboard")
    }

    func testScheduleDeferredPasteboardRestore_skipsWhenOverwritten() {
        TextInjector.resetDeferredRestoreGenerationForTesting()
        testPasteboard.clearContents()
        testPasteboard.setString("prior clipboard", forType: .string)
        let saved = TextInjector.pasteboardSnapshot(from: testPasteboard)

        TextInjector.preparePasteboardForPaste("injected transcript", on: testPasteboard)

        var work: (() -> Void)?
        TextInjector.scheduleDeferredPasteboardRestore(
            injectedText: "injected transcript",
            savedPasteboard: saved,
            on: testPasteboard,
            delay: 2.0,
            asyncAfter: { _, block in work = block }
        )

        testPasteboard.clearContents()
        testPasteboard.setString("user copied something else", forType: .string)
        work?()
        XCTAssertEqual(testPasteboard.string(forType: .string), "user copied something else")
    }

    func testScheduleDeferredPasteboardRestore_supersededSkipsOlderCallback() {
        TextInjector.resetDeferredRestoreGenerationForTesting()
        testPasteboard.clearContents()
        testPasteboard.setString("original", forType: .string)
        let savedOriginal = TextInjector.pasteboardSnapshot(from: testPasteboard)

        TextInjector.preparePasteboardForPaste("first", on: testPasteboard)
        var firstWork: (() -> Void)?
        TextInjector.scheduleDeferredPasteboardRestore(
            injectedText: "first",
            savedPasteboard: savedOriginal,
            on: testPasteboard,
            delay: 2.0,
            asyncAfter: { _, block in firstWork = block }
        )

        let savedAfterFirst = TextInjector.pasteboardSnapshot(from: testPasteboard)
        TextInjector.preparePasteboardForPaste("second", on: testPasteboard)
        var secondWork: (() -> Void)?
        TextInjector.scheduleDeferredPasteboardRestore(
            injectedText: "second",
            savedPasteboard: savedAfterFirst,
            on: testPasteboard,
            delay: 2.0,
            asyncAfter: { _, block in secondWork = block }
        )

        firstWork?()
        XCTAssertEqual(testPasteboard.string(forType: .string), "second",
                       "superseded restore must not clobber newer inject")

        secondWork?()
        XCTAssertEqual(testPasteboard.string(forType: .string), "first")
    }

    // MARK: - Pasteboard helpers (named test pasteboard only)

    func testPasteboardSnapshot_emptyWhenPasteboardEmpty() {
        testPasteboard.clearContents()
        XCTAssertTrue(TextInjector.pasteboardSnapshot(from: testPasteboard).isEmpty)
    }

    func testPasteboardSnapshot_capturesExistingString() {
        testPasteboard.clearContents()
        testPasteboard.setString("prior clipboard", forType: .string)
        let snapshot = TextInjector.pasteboardSnapshot(from: testPasteboard)
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(
            snapshot.first?[.string].flatMap { String(data: $0, encoding: .utf8) },
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
        let saved = TextInjector.pasteboardSnapshot(from: testPasteboard)

        TextInjector.preparePasteboardForPaste("injected", on: testPasteboard)
        XCTAssertEqual(testPasteboard.string(forType: .string), "injected")

        TextInjector.restorePasteboardSnapshot(saved, on: testPasteboard)
        XCTAssertEqual(testPasteboard.string(forType: .string), "saved snapshot")
    }

    func testRestorePasteboardSnapshot_clearsWhenPriorWasEmpty() {
        testPasteboard.clearContents()
        let saved = TextInjector.pasteboardSnapshot(from: testPasteboard)
        XCTAssertTrue(saved.isEmpty)

        TextInjector.preparePasteboardForPaste("injected", on: testPasteboard)
        TextInjector.restorePasteboardSnapshot(saved, on: testPasteboard)
        XCTAssertNil(testPasteboard.string(forType: .string))
    }

    /// The regression this snapshot type exists for: a plain-text-only capture
    /// silently destroyed any non-string payload on the user's clipboard.
    func testPasteboardSnapshot_preservesNonStringRepresentations() {
        let tiffType = NSPasteboard.PasteboardType.tiff
        let imageBytes = Data([0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08])

        testPasteboard.clearContents()
        let original = NSPasteboardItem()
        original.setData(imageBytes, forType: tiffType)
        original.setString("alt text", forType: .string)
        testPasteboard.writeObjects([original])

        let saved = TextInjector.pasteboardSnapshot(from: testPasteboard)

        TextInjector.preparePasteboardForPaste("injected", on: testPasteboard)
        XCTAssertNil(testPasteboard.data(forType: tiffType), "precondition: injection clears the image")

        TextInjector.restorePasteboardSnapshot(saved, on: testPasteboard)
        XCTAssertEqual(testPasteboard.data(forType: tiffType), imageBytes)
        XCTAssertEqual(testPasteboard.string(forType: .string), "alt text")
    }

    func testPasteboardSnapshot_preservesMultipleItems() {
        testPasteboard.clearContents()
        let first = NSPasteboardItem()
        first.setString("one", forType: .string)
        let second = NSPasteboardItem()
        second.setString("two", forType: .string)
        testPasteboard.writeObjects([first, second])

        let saved = TextInjector.pasteboardSnapshot(from: testPasteboard)
        XCTAssertEqual(saved.count, 2)

        TextInjector.preparePasteboardForPaste("injected", on: testPasteboard)
        TextInjector.restorePasteboardSnapshot(saved, on: testPasteboard)
        XCTAssertEqual(testPasteboard.pasteboardItems?.count, 2)
    }

    // MARK: - Confirmed-delivery gate for the pasteboard decision (F-01)

    /// `.unverifiedFallback` stops the lane chain but proves nothing, so it must
    /// not drive a pasteboard restore — the pipeline maps it to `.failed`, which
    /// the HUD renders as "your text is on the clipboard". Same contract as
    /// paste-blind (observer tap missing): leave the transcript; never restore
    /// the pre-insert snapshot on that path.
    func testIsConfirmedDelivery_trueOnlyForObservedDelivery() {
        XCTAssertTrue(TextInjector.InsertDeliveryPath.confirmed.isConfirmedDelivery)
        XCTAssertTrue(TextInjector.InsertDeliveryPath.confirmedOnRetry.isConfirmedDelivery)
        XCTAssertFalse(TextInjector.InsertDeliveryPath.unverifiedFallback.isConfirmedDelivery)
        XCTAssertFalse(TextInjector.InsertDeliveryPath.clipboard.isConfirmedDelivery)
    }

    /// Guards the specific divergence: `shouldReturnTrue` and
    /// `isConfirmedDelivery` agree everywhere except `.unverifiedFallback`.
    func testUnverifiedFallbackDivergesFromShouldReturnTrue() {
        let outcome = TextInjector.resolveOutcome(
            confirmed: false,
            retryConfirmed: false,
            pidFallbackSucceeded: true
        )
        XCTAssertEqual(outcome.path, .unverifiedFallback)
        XCTAssertTrue(outcome.shouldReturnTrue, "lane chain stops here")
        XCTAssertFalse(outcome.path.isConfirmedDelivery, "but delivery was never observed")

        let decision = TextInjector.resolveSavedPasteboardRestore(
            pasteSucceeded: false,
            unicodeSucceeded: outcome.path.isConfirmedDelivery,
            allLanesFailed: !outcome.path.isConfirmedDelivery
        )
        XCTAssertEqual(decision, .doNotRestoreLeaveTranscript)
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
