import XCTest
@testable import Voice

final class LearnToastPresentationTests: XCTestCase {

    private func batch(_ variant: String, term: String = "Term", entryID: UUID = UUID()) -> LearnBatch {
        LearnBatch(corrections: [
            LearnedCorrection(
                variant: variant,
                term: term,
                createdNewEntry: true,
                entryID: entryID
            )
        ])
    }

    func testEnqueueFIFOAndCapDropsNewest() {
        var pending: [LearnBatch] = []
        XCTAssertTrue(LearnToastPendingQueue.enqueue(batch("a"), into: &pending))
        XCTAssertTrue(LearnToastPendingQueue.enqueue(batch("b"), into: &pending))
        XCTAssertTrue(LearnToastPendingQueue.enqueue(batch("c"), into: &pending))
        XCTAssertEqual(pending.count, 3)
        // Cap full → refuse newest; oldest queued keep Reject.
        XCTAssertFalse(LearnToastPendingQueue.enqueue(batch("d"), into: &pending))
        XCTAssertEqual(pending.count, LearnToastPendingQueue.maxPending)
        XCTAssertEqual(pending.map { $0.corrections[0].variant }, ["a", "b", "c"])

        let first = LearnToastPendingQueue.dequeue(from: &pending)
        XCTAssertEqual(first?.corrections[0].variant, "a")
        XCTAssertEqual(pending.count, 2)
    }

    func testEnqueueIgnoresEmptyBatch() {
        var pending: [LearnBatch] = []
        XCTAssertFalse(LearnToastPendingQueue.enqueue(LearnBatch(corrections: []), into: &pending))
        XCTAssertTrue(pending.isEmpty)
    }

    func testUnlearnDismissalRemovesMatchingPendingAndFlagsCurrent() {
        let keepID = UUID()
        let dropID = UUID()
        let rejectable = batch("visible", entryID: dropID)
        let pending = [
            batch("queued-keep", entryID: keepID),
            batch("queued-drop", entryID: dropID)
        ]
        let plan = LearnToastUnlearnDismissal.plan(
            identities: [UnlearnedCorrectionIdentity(entryID: dropID, variant: "visible", term: "Term"),
                         UnlearnedCorrectionIdentity(entryID: dropID, variant: "queued-drop", term: "Term")],
            rejectable: rejectable,
            pending: pending
        )
        XCTAssertTrue(plan.dismissCurrent)
        XCTAssertNil(plan.rejectable)
        XCTAssertEqual(plan.pending.count, 1)
        XCTAssertEqual(plan.pending[0].corrections[0].variant, "queued-keep")
    }

    func testUnlearnDismissalPartialStripKeepsRemainder() {
        let keepID = UUID()
        let dropID = UUID()
        let rejectable = LearnBatch(corrections: [
            LearnedCorrection(variant: "a", term: "A", createdNewEntry: true, entryID: dropID),
            LearnedCorrection(variant: "b", term: "B", createdNewEntry: true, entryID: keepID)
        ])
        let pending = [
            LearnBatch(corrections: [
                LearnedCorrection(variant: "c", term: "C", createdNewEntry: true, entryID: dropID),
                LearnedCorrection(variant: "d", term: "D", createdNewEntry: true, entryID: keepID)
            ])
        ]
        let plan = LearnToastUnlearnDismissal.plan(
            identities: [
                UnlearnedCorrectionIdentity(entryID: dropID, variant: "a", term: "A"),
                UnlearnedCorrectionIdentity(entryID: dropID, variant: "c", term: "C")
            ],
            rejectable: rejectable,
            pending: pending
        )
        XCTAssertFalse(plan.dismissCurrent)
        XCTAssertEqual(plan.rejectable?.corrections.map(\.entryID), [keepID])
        XCTAssertEqual(plan.rejectable?.id, rejectable.id)
        XCTAssertEqual(plan.pending.count, 1)
        XCTAssertEqual(plan.pending[0].corrections.map(\.entryID), [keepID])
        XCTAssertEqual(plan.pending[0].corrections[0].variant, "d")
    }

    func testUnlearnDismissalKeepsSameEntryIDSibling() {
        let sharedID = UUID()
        let rejectable = LearnBatch(corrections: [
            LearnedCorrection(variant: "groq", term: "Grok", createdNewEntry: false, entryID: sharedID),
            LearnedCorrection(variant: "grawk", term: "Grok", createdNewEntry: false, entryID: sharedID)
        ])
        let plan = LearnToastUnlearnDismissal.plan(
            identities: [UnlearnedCorrectionIdentity(entryID: sharedID, variant: "groq", term: "Grok")],
            rejectable: rejectable,
            pending: []
        )
        XCTAssertFalse(plan.dismissCurrent)
        XCTAssertEqual(plan.rejectable?.corrections.map(\.variant), ["grawk"])
        XCTAssertEqual(plan.rejectable?.corrections.first?.entryID, sharedID)
        XCTAssertEqual(plan.rejectable?.id, rejectable.id)
    }

    func testUnlearnDismissalNoOpWhenEntryIDsMiss() {
        let rejectable = batch("visible", entryID: UUID())
        let pending = [batch("queued", entryID: UUID())]
        let plan = LearnToastUnlearnDismissal.plan(
            identities: [UnlearnedCorrectionIdentity(entryID: UUID(), variant: "miss", term: "Miss")],
            rejectable: rejectable,
            pending: pending
        )
        XCTAssertFalse(plan.dismissCurrent)
        XCTAssertEqual(plan.rejectable?.corrections[0].variant, "visible")
        XCTAssertEqual(plan.pending.count, 1)
    }

    func testRejectDuringDismissFadeStillYieldsBatch() {
        var rejectable: LearnBatch? = batch("heard")
        // Dismiss starts: batch stays rejectable through fade.
        XCTAssertNotNil(rejectable)

        let rejected = LearnToastRejectSession.takeRejectable(&rejectable)
        XCTAssertEqual(rejected?.corrections[0].variant, "heard")
        XCTAssertNil(rejectable)

        // Fade end after Reject: no onDismiss.
        XCTAssertFalse(LearnToastRejectSession.clearIfStillPresent(&rejectable))
    }

    func testDismissFadeClearsWhenNotRejected() {
        var rejectable: LearnBatch? = batch("kept")
        XCTAssertTrue(LearnToastRejectSession.clearIfStillPresent(&rejectable))
        XCTAssertNil(rejectable)
        // Late Reject after dismiss completed: no-op.
        XCTAssertNil(LearnToastRejectSession.takeRejectable(&rejectable))
    }
}
