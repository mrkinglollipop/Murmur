import Foundation

/// Pending and rejected heard→term pairs for automated ("other apps")
/// correction learning. Pure value type; `DictionaryStore` owns persistence.
///
/// A single inline edit in another app is weak evidence: live data showed
/// one-off rewrites ("Mark" → "Mock", "mess" → "miss") becoming permanent
/// rules for every future dictation. A pair is promoted to the dictionary only
/// on its second sighting from a different dictation. Pairs the user rejected
/// (toast Reject, Revert, deleting an unapproved auto-learned entry) are
/// remembered and never become candidates again.
struct LearnCandidateLedger: Codable, Equatable {

    static let requiredSightings = 2
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60
    static let maxPending = 200

    struct Pair: Codable, Hashable {
        let heard: String
        let term: String

        init(heard: String, term: String) {
            self.heard = LearnCandidateLedger.key(heard)
            self.term = LearnCandidateLedger.key(term)
        }
    }

    struct Candidate: Codable, Equatable {
        let pair: Pair
        var sightings: Int
        let firstSeen: Date
        var lastSeen: Date
        var observationIDs: [UUID]
    }

    private(set) var pending: [Candidate] = []
    private(set) var rejected: Set<Pair> = []

    /// Case- and typography-insensitive identity for a heard or term string.
    static func key(_ text: String) -> String {
        CorrectionExtractor.normalizingTypography(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    func isRejected(heard: String, term: String) -> Bool {
        rejected.contains(Pair(heard: heard, term: term))
    }

    func pendingSightings(heard: String, term: String) -> Int {
        let pair = Pair(heard: heard, term: term)
        return pending.first { $0.pair == pair }?.sightings ?? 0
    }

    /// Records one sighting. Returns true when the pair has now been seen in
    /// `requiredSightings` distinct observations (the candidate is consumed).
    /// A repeat from the same `observationID` never counts twice.
    mutating func observe(heard: String, term: String, observationID: UUID, now: Date) -> Bool {
        prune(now: now)
        let pair = Pair(heard: heard, term: term)
        guard !rejected.contains(pair) else { return false }

        if let index = pending.firstIndex(where: { $0.pair == pair }) {
            guard !pending[index].observationIDs.contains(observationID) else { return false }
            pending[index].sightings += 1
            pending[index].lastSeen = now
            pending[index].observationIDs.append(observationID)
            if pending[index].sightings >= Self.requiredSightings {
                pending.remove(at: index)
                return true
            }
            return false
        }

        pending.append(Candidate(
            pair: pair,
            sightings: 1,
            firstSeen: now,
            lastSeen: now,
            observationIDs: [observationID]
        ))
        if pending.count > Self.maxPending {
            pending.sort { $0.lastSeen > $1.lastSeen }
            pending.removeLast(pending.count - Self.maxPending)
        }
        return false
    }

    /// Drops candidates whose first sighting is older than `maxAge`.
    mutating func prune(now: Date) {
        pending.removeAll { now.timeIntervalSince($0.firstSeen) > Self.maxAge }
    }

    /// Remembers a user rejection; also drops any pending sighting of it.
    mutating func reject(heard: String, term: String) {
        let pair = Pair(heard: heard, term: term)
        pending.removeAll { $0.pair == pair }
        // Uncapped on purpose: it only grows by explicit user rejections, and
        // evicting one would let that pair come back.
        rejected.insert(pair)
    }
}
