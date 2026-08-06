import Foundation
import os

/// FIFO pending batches when LearnToastHUD is already showing a toast.
enum LearnToastPendingQueue {
    static let maxPending = 3
    private static let logger = Logger(subsystem: "com.matt.voice-dictation", category: "learn-toast")

    /// Enqueues `batch` (non-empty only). If at cap, **refuses** the newest
    /// attempt (returns false) so already-queued batches keep their Reject
    /// affordance. A 4th concurrent announce may skip the toast; Dictionary
    /// Revert remains available.
    @discardableResult
    static func enqueue(_ batch: LearnBatch, into pending: inout [LearnBatch]) -> Bool {
        guard !batch.corrections.isEmpty else { return false }
        if pending.count >= maxPending {
            logger.debug("Learn toast pending queue full; refusing newest announce")
            return false
        }
        pending.append(batch)
        return true
    }

    static func dequeue(from pending: inout [LearnBatch]) -> LearnBatch? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }
}

/// Plan toast teardown when Dictionary unlearn/revert hits correction
/// identities that are still on-screen or queued.
enum LearnToastUnlearnDismissal {
    static func batchContains(identities: Set<UnlearnedCorrectionIdentity>, _ batch: LearnBatch) -> Bool {
        batch.corrections.contains { correction in
            identities.contains { $0.matches(correction) }
        }
    }

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

/// Reject-during-dismiss fade: batch stays rejectable until Reject consumes it
/// or dismiss fade completion clears it.
enum LearnToastRejectSession {
    /// Capture and clear; nil if already rejected or cleared.
    static func takeRejectable(_ batch: inout LearnBatch?) -> LearnBatch? {
        guard let value = batch else { return nil }
        batch = nil
        return value
    }

    /// Clear at end of dismiss fade. Returns true if a batch was still present
    /// (genuine dismiss — call `onDismiss`). False if Reject already took it.
    @discardableResult
    static func clearIfStillPresent(_ batch: inout LearnBatch?) -> Bool {
        guard batch != nil else { return false }
        batch = nil
        return true
    }
}
