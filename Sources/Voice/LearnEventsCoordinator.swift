import Foundation

/// Sole owner of CorrectionsLog appends for learn-time outcomes
/// (`learnAccepted` / `learnRejected`). Wired from AppDelegate.
@MainActor
final class LearnEventsCoordinator {

    private let correctionsLog: CorrectionsLog
    private let dictionaryStore: DictionaryStore
    private let learnToast: LearnToastHUD

    init(
        correctionsLog: CorrectionsLog,
        dictionaryStore: DictionaryStore,
        learnToast: LearnToastHUD
    ) {
        self.correctionsLog = correctionsLog
        self.dictionaryStore = dictionaryStore
        self.learnToast = learnToast
    }

    func bind() {
        dictionaryStore.onLearnBatch = { [weak self] event in
            self?.handleLearnBatch(event)
        }
        dictionaryStore.onRejectCompleted = { [weak self] batch in
            self?.handleRejectCompleted(batch)
        }
        dictionaryStore.onUnlearn = { [weak self] identities in
            self?.learnToast.dismissBatchesContaining(identities: identities)
        }

        learnToast.onReject = { [weak self] batch in
            self?.dictionaryStore.rejectLearnedBatch(batch)
        }
    }

    private func handleLearnBatch(_ event: LearnBatchEvent) {
        // Empty batch (e.g. no-op Restore) → skip learnAccepted append.
        guard !event.batch.corrections.isEmpty else { return }
        let records = event.batch.corrections.map { correction in
            CorrectionRecord(
                heard: correction.variant,
                replaced: correction.term,
                source: .learnAccepted,
                entryID: correction.entryID,
                createdNewEntry: correction.createdNewEntry
            )
        }
        correctionsLog.append(records)

        // Toast display only for announced learns (not Restore).
        if event.announce {
            learnToast.show(batch: event.batch)
        }
    }

    private func handleRejectCompleted(_ batch: LearnBatch) {
        let records = batch.corrections.map { correction in
            CorrectionRecord(
                heard: correction.variant,
                replaced: correction.term,
                source: .learnRejected,
                entryID: correction.entryID,
                createdNewEntry: correction.createdNewEntry
            )
        }
        correctionsLog.append(records)
    }
}

/// Payload for `DictionaryStore.onLearnBatch` — non-empty recorded learns.
struct LearnBatchEvent: Equatable {
    let batch: LearnBatch
    let announce: Bool
}
