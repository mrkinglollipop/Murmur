import XCTest
@testable import Voice

extension DictionaryStore {
    /// Automated ("other apps") learning promotes a pair on its second
    /// sighting from a different dictation; this feeds two such sightings.
    @discardableResult
    func learnSeenTwice(from old: String, to new: String, announce: Bool = true) -> [LearnedCorrection] {
        _ = learn(from: old, to: new, userInitiated: false, announce: announce)
        return learn(from: old, to: new, userInitiated: false, announce: announce)
    }
}

/// Guards on automated correction learning (CorrectionWatcher → learn).
/// Every store lives in a fresh temp directory with an injected lexicon:
/// no real Application Support files, no Keychain.
@MainActor
final class LearnGuardTests: XCTestCase {

    private let words: Set<String> = ["mark", "mock", "mess", "miss", "like", "foo", "bar"]

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("learn-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeStore(in directory: URL) -> DictionaryStore {
        let lexicon = RealWordLexicon { [words] in words.contains($0) }
        return DictionaryStore(
            fileURL: directory.appendingPathComponent("dictionary.json"),
            blocklistFileURL: directory.appendingPathComponent("blocklist.json"),
            learnCandidatesFileURL: directory.appendingPathComponent("learn-candidates.json"),
            lexicon: lexicon
        )
    }

    private func makeStore() throws -> DictionaryStore {
        makeStore(in: try makeDirectory())
    }

    // MARK: - Ordinary English never learns

    func testAutomatedLearnRefusesOrdinaryEnglishHeardWords() throws {
        let store = try makeStore()
        let pairs = [
            ("Mark said hi", "Mock said hi"),
            ("what a mess", "what a miss"),
            ("we've shipped", "I've shipped"),
            ("we’ve shipped", "I've shipped"),
            ("we've, shipped", "I’ve, shipped"),
        ]
        for (old, new) in pairs {
            for _ in 0..<4 {
                XCTAssertTrue(store.learn(from: old, to: new, userInitiated: false).isEmpty, old)
            }
        }
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.learnCandidates.pending.isEmpty, "English heard words must not even pend")
    }

    func testAutomatedLearnIgnoresTypographyAndCaseOnlyWords() throws {
        let store = try makeStore()
        for _ in 0..<3 {
            XCTAssertTrue(store.learn(from: "Groq", to: "groq", userInitiated: false).isEmpty)
            XCTAssertTrue(store.learn(from: "it's", to: "it’s", userInitiated: false).isEmpty)
            XCTAssertTrue(store.learn(from: "zed-ex Zork", to: "zed–ex zork", userInitiated: false).isEmpty)
        }
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.learnCandidates.pending.isEmpty)
    }

    func testHistoryEditAndHandAddedEntriesAreNotGated() throws {
        let store = try makeStore()
        let learned = store.learn(from: "Mark said hi", to: "Mock said hi", userInitiated: true)
        XCTAssertEqual(learned.map(\.variant), ["Mark"])

        store.add(term: "Missy", variants: ["mess"])
        XCTAssertEqual(store.correct("what a mess").text, "what a Missy")
    }

    // MARK: - Two independent sightings

    func testSingleSightingOnlyPends() throws {
        let store = try makeStore()
        var events = 0
        store.onLearnBatch = { _ in events += 1 }

        XCTAssertTrue(store.learn(from: "I use Groq", to: "I use Grok", userInitiated: false).isEmpty)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(events, 0, "no toast/log for a pending candidate")
        XCTAssertEqual(store.learnCandidates.pendingSightings(heard: "groq", term: "GROK"), 1)
        XCTAssertEqual(store.correct("try Groq").text, "try Groq")
    }

    func testSecondSightingFromAnotherDictationPromotes() throws {
        let store = try makeStore()
        var events = 0
        store.onLearnBatch = { _ in events += 1 }

        _ = store.learn(from: "I use Groq", to: "I use Grok", userInitiated: false)
        let learned = store.learn(from: "Groq is fast", to: "Grok is fast", userInitiated: false)

        XCTAssertEqual(learned.map(\.variant), ["Groq"])
        XCTAssertEqual(learned.map(\.term), ["Grok"])
        XCTAssertEqual(events, 1)
        XCTAssertTrue(store.entries.contains { $0.term == "Grok" && $0.isAutoLearned })
        XCTAssertTrue(store.learnCandidates.pending.isEmpty, "promotion consumes the candidate")
        XCTAssertEqual(store.correct("try Groq").text, "try Groq", "a suggestion is inert until approved")
        store.approveLearnedBatch(LearnBatch(corrections: learned))
        XCTAssertEqual(store.correct("try Groq").text, "try Grok")
    }

    func testSameDictationNeverCountsTwice() throws {
        let store = try makeStore()
        let dictation = UUID()
        XCTAssertTrue(store.learn(from: "Groq", to: "Grok", userInitiated: false, observationID: dictation).isEmpty)
        XCTAssertTrue(store.learn(from: "Groq", to: "Grok", userInitiated: false, observationID: dictation).isEmpty)
        XCTAssertTrue(store.learn(from: "Zorp and Zorp", to: "Zork and Zork", userInitiated: false).isEmpty)
        XCTAssertEqual(store.learnCandidates.pendingSightings(heard: "Groq", term: "Grok"), 1)
        XCTAssertEqual(store.learnCandidates.pendingSightings(heard: "Zorp", term: "Zork"), 1)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testPendingCandidatePersistsAcrossRelaunch() throws {
        let directory = try makeDirectory()
        let first = makeStore(in: directory)
        XCTAssertTrue(first.learn(from: "Groq", to: "Grok", userInitiated: false).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("learn-candidates.json").path
        ))

        let relaunched = makeStore(in: directory)
        XCTAssertEqual(relaunched.learnCandidates.pendingSightings(heard: "Groq", term: "Grok"), 1)
        XCTAssertEqual(relaunched.learn(from: "Groq", to: "Grok", userInitiated: false).count, 1)
    }

    func testPendingCandidateAgesOut() throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        store.learnClock = { start }
        _ = store.learn(from: "Groq", to: "Grok", userInitiated: false)

        store.learnClock = { start.addingTimeInterval(LearnCandidateLedger.maxAge + 60) }
        XCTAssertTrue(store.learn(from: "Groq", to: "Grok", userInitiated: false).isEmpty,
                      "a sighting older than the window does not count")
        XCTAssertEqual(store.learnCandidates.pendingSightings(heard: "Groq", term: "Grok"), 1)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testPendingCandidatesAreCapped() {
        var ledger = LearnCandidateLedger()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0...LearnCandidateLedger.maxPending {
            _ = ledger.observe(
                heard: "heard\(index)",
                term: "Term\(index)",
                observationID: UUID(),
                now: start.addingTimeInterval(TimeInterval(index))
            )
        }
        XCTAssertEqual(ledger.pending.count, LearnCandidateLedger.maxPending)
        XCTAssertEqual(ledger.pendingSightings(heard: "heard0", term: "term0"), 0, "oldest is evicted")
        XCTAssertEqual(ledger.pendingSightings(heard: "heard\(LearnCandidateLedger.maxPending)",
                                               term: "term\(LearnCandidateLedger.maxPending)"), 1)
    }

    // MARK: - Rejected / blocklisted pairs never come back

    func testToastRejectedPairNeverComesBack() throws {
        let store = try makeStore()
        let learned = store.learnSeenTwice(from: "Groq", to: "Grok")
        XCTAssertEqual(learned.count, 1)
        store.rejectLearnedBatch(LearnBatch(corrections: learned))
        XCTAssertTrue(store.entries.isEmpty)

        XCTAssertTrue(store.learnSeenTwice(from: "Groq", to: "Grok").isEmpty)
        XCTAssertTrue(store.learnSeenTwice(from: "groq", to: "GROK").isEmpty)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.learnCandidates.pending.isEmpty)
    }

    func testRevertedPairNeverComesBack() throws {
        let store = try makeStore()
        let learned = store.learnSeenTwice(from: "Groq", to: "Grok")
        XCTAssertTrue(store.unlearn(learned[0]))
        XCTAssertFalse(store.isBlocklisted(heard: "Groq", replaced: "Grok"), "Revert still does not blocklist")
        XCTAssertTrue(store.learnSeenTwice(from: "Groq", to: "Grok").isEmpty)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testDeletedAutoLearnedEntryNeverComesBackAcrossRelaunch() throws {
        let directory = try makeDirectory()
        let store = makeStore(in: directory)
        _ = store.learnSeenTwice(from: "Groq", to: "Grok")
        let entry = try XCTUnwrap(store.entries.first { $0.term == "Grok" })
        store.delete(entry)
        store.flush()

        let relaunched = makeStore(in: directory)
        XCTAssertTrue(relaunched.learnSeenTwice(from: "Groq", to: "Grok").isEmpty)
        XCTAssertTrue(relaunched.entries.isEmpty)
    }

    func testDeletingHandAddedEntryDoesNotReject() throws {
        let store = try makeStore()
        store.add(term: "Grok", variants: ["Groq"])
        let entry = try XCTUnwrap(store.entries.first)
        store.delete(entry)
        XCTAssertFalse(store.learnCandidates.isRejected(heard: "Groq", term: "Grok"))
        XCTAssertEqual(store.learnSeenTwice(from: "Groq", to: "Grok").count, 1)
    }

    func testBlocklistedPairNeverBecomesCandidate() throws {
        let store = try makeStore()
        store.blocklistPair(heard: "Groq", replaced: "Grok")
        XCTAssertTrue(store.learnSeenTwice(from: "Groq", to: "Grok").isEmpty)
        XCTAssertTrue(store.learnCandidates.pending.isEmpty)
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - Test isolation

    func testSiblingDefaultsKeepTestStoresOutOfApplicationSupport() throws {
        let directory = try makeDirectory()
        let dictionaryURL = directory.appendingPathComponent("dict.json")
        let store = DictionaryStore(fileURL: dictionaryURL, lexicon: RealWordLexicon { _ in false })
        _ = store.learn(from: "Groq", to: "Grok", userInitiated: false)
        store.blocklistPair(heard: "Zorp", replaced: "Zork")
        store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dictionaryURL.path + ".learn-candidates"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dictionaryURL.path + ".blocklist"))
    }
}
