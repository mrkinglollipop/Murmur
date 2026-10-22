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

    func testQueueIsFIFOAndOverflowMergesIntoVisiblePopUp() {
        var state = LearnToastState()
        for variant in ["a", "b", "c", "d", "e", "f"] {
            state.receive(batch(variant))
        }
        // "a" visible, three queued, overflow merged into the visible batch.
        XCTAssertEqual(state.queued.map { $0.corrections[0].variant }, ["b", "c", "d"])
        XCTAssertEqual(state.current?.corrections.map(\.variant), ["a", "e", "f"])
        let all = ([state.current!] + state.queued).flatMap(\.corrections).map(\.variant)
        XCTAssertEqual(Set(all), ["a", "b", "c", "d", "e", "f"], "no suggestion is dropped")

        XCTAssertEqual(state.takeCurrent()?.corrections.count, 3)
        XCTAssertEqual(state.current?.corrections[0].variant, "b")
        XCTAssertEqual(state.queued.count, 2)
    }

    func testMergeKeepsVisibleIDAndSkipsDuplicates() {
        let shown = batch("a")
        let merged = LearnToastState.merging(
            LearnBatch(corrections: shown.corrections + batch("b").corrections),
            into: shown
        )
        XCTAssertEqual(merged.id, shown.id)
        XCTAssertEqual(merged.corrections.map(\.variant), ["a", "b"])
    }

    func testReceiveIgnoresEmptyBatch() {
        var state = LearnToastState()
        state.receive(LearnBatch(corrections: []))
        XCTAssertNil(state.current)
        XCTAssertTrue(state.queued.isEmpty)
    }

    func testDictationActiveHidesWithoutDroppingAndRestores() {
        var state = LearnToastState()
        state.receive(batch("a"))
        XCTAssertTrue(state.isOnScreen)
        state.dictationActive = true
        XCTAssertFalse(state.isOnScreen)
        XCTAssertEqual(state.current?.corrections[0].variant, "a")
        state.receive(batch("b"))
        state.dictationActive = false
        XCTAssertTrue(state.isOnScreen)
        XCTAssertEqual(state.current?.corrections[0].variant, "a")
        XCTAssertEqual(state.queued.map { $0.corrections[0].variant }, ["b"])
    }

    func testStripPromotesNextWhenVisibleEmpties() {
        let id = UUID()
        var state = LearnToastState()
        state.receive(batch("a", entryID: id))
        state.receive(batch("b"))
        state.strip([UnlearnedCorrectionIdentity(entryID: id, variant: "a", term: "Term")])
        XCTAssertEqual(state.current?.corrections[0].variant, "b")
        XCTAssertTrue(state.queued.isEmpty)
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
}
