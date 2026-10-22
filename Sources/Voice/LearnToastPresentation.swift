import Foundation

/// What the learn suggestion pop-up holds. Pure state, unit-testable.
///
/// A suggestion stays until the user acts on it (Add / Never / ✕): there is
/// no timer. While a dictation records or processes the pop-up is hidden and
/// comes back afterwards. Batches that arrive while one is showing wait in a
/// FIFO queue; once the queue is full they merge into the visible pop-up
/// instead of being dropped.
struct LearnToastState: Equatable {
    static let maxQueued = 3

    /// Shown (or held while a dictation is active).
    private(set) var current: LearnBatch?
    private(set) var queued: [LearnBatch] = []
    var dictationActive = false

    var isOnScreen: Bool { current != nil && !dictationActive }

    mutating func receive(_ batch: LearnBatch) {
        guard !batch.corrections.isEmpty else { return }
        guard let shown = current else {
            current = batch
            return
        }
        if queued.count < Self.maxQueued {
            queued.append(batch)
        } else {
            current = Self.merging(batch, into: shown)
        }
    }

    /// Removes the visible batch (Add / Never / decide later) and promotes
    /// the next queued one. Returns what was visible.
    mutating func takeCurrent() -> LearnBatch? {
        let taken = current
        current = queued.isEmpty ? nil : queued.removeFirst()
        return taken
    }

    /// Drops corrections resolved elsewhere (Dictionary Add / Never / Revert).
    mutating func strip(_ identities: Set<UnlearnedCorrectionIdentity>) {
        let plan = LearnToastUnlearnDismissal.plan(
            identities: identities,
            rejectable: current,
            pending: queued
        )
        queued = plan.pending
        if plan.dismissCurrent {
            current = queued.isEmpty ? nil : queued.removeFirst()
        } else {
            current = plan.rejectable
        }
    }

    /// Appends `incoming` corrections not already shown; keeps `shown.id`.
    static func merging(_ incoming: LearnBatch, into shown: LearnBatch) -> LearnBatch {
        let existing = Set(shown.corrections.map(UnlearnedCorrectionIdentity.init))
        let added = incoming.corrections.filter { !existing.contains(UnlearnedCorrectionIdentity($0)) }
        guard !added.isEmpty else { return shown }
        return LearnBatch(id: shown.id, corrections: shown.corrections + added)
    }
}

/// Plan pop-up teardown when Dictionary Add / Never / Revert resolves
/// correction identities that are still on-screen or queued.
enum LearnToastUnlearnDismissal {
    /// Strips matching corrections from a batch. Returns `nil` when empty,
    /// the same batch when nothing matched, or a same-id batch with remainder.
    /// Match is entryID + variant + term (not entryID alone).
    static func stripping(_ batch: LearnBatch, identities: Set<UnlearnedCorrectionIdentity>) -> LearnBatch? {
        let remaining = batch.corrections.filter { correction in
            !identities.contains { $0.matches(correction) }
        }
        guard !remaining.isEmpty else { return nil }
        if remaining.count == batch.corrections.count { return batch }
        return LearnBatch(id: batch.id, corrections: remaining)
    }

    /// Strips matching corrections from pending and the visible/rejectable
    /// batch. Dismiss current only when its remainder is empty (silent — not
    /// Reject, not user dismiss). Partial unlearn keeps the toast with the
    /// remaining corrections (including same-entryID siblings).
    static func plan(
        identities: Set<UnlearnedCorrectionIdentity>,
        rejectable: LearnBatch?,
        pending: [LearnBatch]
    ) -> (dismissCurrent: Bool, rejectable: LearnBatch?, pending: [LearnBatch]) {
        guard !identities.isEmpty else {
            return (false, rejectable, pending)
        }
        let filtered = pending.compactMap { stripping($0, identities: identities) }
        guard let current = rejectable else {
            return (false, nil, filtered)
        }
        if let stripped = stripping(current, identities: identities) {
            return (false, stripped, filtered)
        }
        return (true, nil, filtered)
    }
}
