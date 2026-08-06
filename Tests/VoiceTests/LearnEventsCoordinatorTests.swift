import XCTest
@testable import Voice

@MainActor
final class LearnEventsCoordinatorTests: XCTestCase {

    private func makeStore() -> DictionaryStore {
        let dictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dict-\(UUID().uuidString).json")
        let blockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("block-\(UUID().uuidString).json")
        return DictionaryStore(fileURL: dictURL, blocklistFileURL: blockURL)
    }

    private func makeCoordinator(store: DictionaryStore, log: CorrectionsLog? = nil) -> (LearnEventsCoordinator, CorrectionsLog, LearnToastHUD) {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-\(UUID().uuidString).json")
        let correctionsLog = log ?? CorrectionsLog(fileURL: logURL)
        let toast = LearnToastHUD()
        let coordinator = LearnEventsCoordinator(
            correctionsLog: correctionsLog,
            dictionaryStore: store,
            learnToast: toast
        )
        return (coordinator, correctionsLog, toast)
    }

    func testOnLearnBatchFiresForAnnounceFalse() {
        let store = makeStore()
        var events: [LearnBatchEvent] = []
        store.onLearnBatch = { events.append($0) }

        let learned = store.learn(
            from: "Groq",
            to: "Grok",
            userInitiated: false,
            announce: false
        )
        XCTAssertFalse(learned.isEmpty)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].announce, false)
        XCTAssertEqual(events[0].batch.corrections.first?.entryID, learned.first?.entryID)
    }

    func testCoordinatorRestoreAnnounceFalseSkipsToastPathStillLogsAccepted() {
        let store = makeStore()
        let (coordinator, log, _) = makeCoordinator(store: store)
        coordinator.bind()

        _ = store.learn(from: "Groq", to: "Grok", userInitiated: true, announce: false)
        XCTAssertEqual(log.records.filter { $0.source == .learnAccepted }.count, 1)
        // announce:false must not require a visible toast; Revert stays in Dictionary.
    }

    func testUnblockPairLowercaseIdempotent() {
        let store = makeStore()
        store.blocklistPair(heard: "Groq", replaced: "Grok")
        XCTAssertTrue(store.isBlocklisted(heard: "groq", replaced: "grok"))
        store.unblockPair(heard: "GROQ", replaced: "GROK")
        XCTAssertFalse(store.isBlocklisted(heard: "groq", replaced: "grok"))
        store.unblockPair(heard: "groq", replaced: "grok")
        XCTAssertFalse(store.isBlocklisted(heard: "groq", replaced: "grok"))
    }

    func testRejectCompletedCallbackAfterRejectBatch() {
        let store = makeStore()
        let learned = store.learn(from: "Groq", to: "Grok", userInitiated: false, announce: true)
        XCTAssertFalse(learned.isEmpty)
        let batch = LearnBatch(corrections: learned)

        var rejected: LearnBatch?
        store.onRejectCompleted = { rejected = $0 }
        store.rejectLearnedBatch(batch)

        XCTAssertNotNil(rejected)
        XCTAssertTrue(store.isBlocklisted(heard: "Groq", replaced: "Grok"))
    }

    func testRejectLearnedBatchSkipsBlocklistWhenAlreadyUnlearned() {
        let store = makeStore()
        let learned = store.learn(from: "Groq", to: "Grok", userInitiated: false, announce: true)
        XCTAssertEqual(learned.count, 1)
        let correction = learned[0]
        let batch = LearnBatch(corrections: [correction])

        XCTAssertTrue(store.unlearn(correction))
        XCTAssertFalse(store.entries.contains { $0.id == correction.entryID })

        var rejected: LearnBatch?
        store.onRejectCompleted = { rejected = $0 }
        store.rejectLearnedBatch(batch)

        XCTAssertNil(rejected)
        XCTAssertFalse(store.isBlocklisted(heard: "Groq", replaced: "Grok"))
    }

    func testUnlearnFiresOnUnlearnForToastTeardown() {
        let store = makeStore()
        let learned = store.learn(from: "Groq", to: "Grok", userInitiated: false, announce: true)
        XCTAssertEqual(learned.count, 1)

        var notified: Set<UnlearnedCorrectionIdentity>?
        store.onUnlearn = { notified = $0 }
        XCTAssertTrue(store.unlearn(learned[0]))
        XCTAssertEqual(notified, [UnlearnedCorrectionIdentity(learned[0])])
    }

    func testNotifyUnlearnedFiresOnUnlearnCallback() {
        let store = makeStore()
        let identity = UnlearnedCorrectionIdentity(entryID: UUID(), variant: "a", term: "A")
        var notified: Set<UnlearnedCorrectionIdentity>?
        store.onUnlearn = { notified = $0 }
        store.notifyUnlearned([identity])
        XCTAssertEqual(notified, [identity])
        store.notifyUnlearned([])
        XCTAssertEqual(notified, [identity])
    }

    func testUnlearnDismissalPlanClearsMatchingToastBatch() {
        let store = makeStore()
        let learned = store.learn(from: "Groq", to: "Grok", userInitiated: false, announce: true)
        XCTAssertEqual(learned.count, 1)
        let rejectable = LearnBatch(corrections: learned)
        let other = LearnBatch(corrections: [
            LearnedCorrection(variant: "x", term: "X", createdNewEntry: true, entryID: UUID())
        ])
        let plan = LearnToastUnlearnDismissal.plan(
            identities: [UnlearnedCorrectionIdentity(learned[0])],
            rejectable: rejectable,
            pending: [other]
        )
        XCTAssertTrue(plan.dismissCurrent)
        XCTAssertNil(plan.rejectable)
        XCTAssertEqual(plan.pending.count, 1)
        XCTAssertEqual(plan.pending[0].corrections[0].variant, "x")
    }

    func testCoordinatorAppendsLearnAcceptedAndRejected() {
        let store = makeStore()
        let (coordinator, log, _) = makeCoordinator(store: store)
        coordinator.bind()

        _ = store.learn(from: "Groq", to: "Grok", userInitiated: false, announce: true)
        XCTAssertEqual(log.records.filter { $0.source == .learnAccepted }.count, 1)
        XCTAssertNotNil(log.records.first?.entryID)
        XCTAssertNotNil(log.records.first?.createdNewEntry)

        let accepted = log.records.first!
        let batch = LearnBatch(corrections: [
            LearnedCorrection(
                variant: accepted.heard,
                term: accepted.replaced,
                createdNewEntry: accepted.createdNewEntry!,
                entryID: accepted.entryID!
            )
        ])
        store.rejectLearnedBatch(batch)
        XCTAssertEqual(log.records.filter { $0.source == .learnRejected }.count, 1)
    }

    func testOnRejectWiringCallsRejectLearnedBatch() {
        let store = makeStore()
        let (coordinator, log, toast) = makeCoordinator(store: store)
        coordinator.bind()

        let learned = store.learn(from: "Groq", to: "Grok", userInitiated: false, announce: true)
        XCTAssertFalse(learned.isEmpty)
        let batch = LearnBatch(corrections: learned)

        // Simulate toast Reject affordance via coordinator wiring.
        toast.onReject?(batch)

        XCTAssertTrue(store.isBlocklisted(heard: "Groq", replaced: "Grok"))
        XCTAssertEqual(log.records.filter { $0.source == .learnRejected }.count, 1)
        XCTAssertFalse(store.entries.contains { $0.id == learned[0].entryID })
    }

    func testCoordinatorUnlearnWiresToastDismissal() {
        let store = makeStore()
        let (coordinator, _, _) = makeCoordinator(store: store)
        coordinator.bind()
        XCTAssertNotNil(store.onUnlearn)

        let learned = store.learn(from: "Groq", to: "Grok", userInitiated: false, announce: true)
        XCTAssertEqual(learned.count, 1)
        // Wired handler must be safe to invoke (dismissBatchesContaining is idempotent
        // when HUD has no matching batch).
        store.onUnlearn?([UnlearnedCorrectionIdentity(learned[0])])
    }

    func testEmptyLearnSkipsAcceptedAppend() {
        let store = makeStore()
        let (coordinator, log, _) = makeCoordinator(store: store)
        coordinator.bind()

        // Same text → no learn path; no onLearnBatch.
        _ = store.learn(from: "same", to: "same", userInitiated: true, announce: false)
        XCTAssertTrue(log.records.isEmpty)
    }
}
