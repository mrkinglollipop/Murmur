import XCTest
@testable import Voice

final class DictionaryLearnTests: XCTestCase {

    private func makeStore() -> DictionaryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dict-test-\(UUID().uuidString).json")
        return DictionaryStore(fileURL: url, blocklistFileURL: url.appendingPathExtension("blocklist"))
    }

    func testUserInitiatedLearnsDissimilarWords() {
        let store = makeStore()
        let learned = store.learn(
            from: "I met with banana yesterday",
            to: "I met with Schwartz yesterday",
            userInitiated: true
        )
        XCTAssertEqual(learned.count, 1)
        XCTAssertEqual(learned.first?.variant, "banana")
        XCTAssertEqual(learned.first?.term, "Schwartz")
        XCTAssertTrue(store.entries.contains { $0.term == "Schwartz" && $0.variants.contains("banana") })
    }

    func testAutomatedLearnSkipsDissimilarWords() {
        let store = makeStore()
        let learned = store.learn(
            from: "I met with banana yesterday",
            to: "I met with Schwartz yesterday",
            userInitiated: false
        )
        XCTAssertTrue(learned.isEmpty)
    }

    func testUserInitiatedLearnsMergedPhraseForDotFix() {
        let store = makeStore()
        let learned = store.learn(
            from: "foo dot bar",
            to: "foo.bar",
            userInitiated: true
        )
        XCTAssertEqual(learned.count, 1)
        XCTAssertEqual(learned.first?.variant, "foo dot bar")
        XCTAssertEqual(learned.first?.term, "foo.bar")
        XCTAssertEqual(store.correct("use foo dot bar here").text, "use foo.bar here")
    }

    func testUserInitiatedLearnsTypoFix() {
        let store = makeStore()
        let learned = store.learn(
            from: "fix teh spelling",
            to: "fix the spelling",
            userInitiated: true
        )
        XCTAssertEqual(learned.count, 1)
        XCTAssertEqual(learned.first?.variant, "teh")
        XCTAssertEqual(learned.first?.term, "the")
    }

    func testUserInitiatedLearnsSplitWordMerge() {
        let store = makeStore()
        let learned = store.learn(
            from: "Get ignore it.",
            to: "gitignore it",
            userInitiated: true
        )
        XCTAssertEqual(learned.count, 1)
        XCTAssertEqual(learned.first?.variant, "Get ignore")
        XCTAssertEqual(learned.first?.term, "gitignore")
        XCTAssertEqual(store.correct("Get ignore it.").text, "gitignore it.")
    }

    func testAutomatedLearnSkipsWordCountMismatch() {
        let store = makeStore()
        let learned = store.learn(
            from: "Get ignore it.",
            to: "gitignore it",
            userInitiated: false
        )
        XCTAssertTrue(learned.isEmpty)
    }

    func testAddSameTermMergesVariants() {
        let store = makeStore()
        store.add(term: "Khipu", variants: ["Keepu"])
        store.add(term: "khipu", variants: ["Keefu"])
        XCTAssertEqual(store.entries.count, 1)
        let entry = store.entries.first
        XCTAssertEqual(entry?.term, "Khipu")
        XCTAssertEqual(Set(entry?.variants.map { $0.lowercased() } ?? []), ["keepu", "keefu"])
    }

    func testAddSameTermDoesNotDuplicateVariant() {
        let store = makeStore()
        store.add(term: "Khipu", variants: ["Keepu"])
        store.add(term: "Khipu", variants: ["keepu"])
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.variants, ["Keepu"])
    }

    func testLoadMergesPersistedDuplicates() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dict-load-merge-\(UUID().uuidString).json")
        let keepuID = UUID()
        let payload: [DictionaryEntry] = [
            DictionaryEntry(id: keepuID, term: "Khipu", variants: ["Keepu"], fixCount: 4),
            DictionaryEntry(id: UUID(), term: "Khipu", variants: ["Keefu"], fixCount: 0)
        ]
        try JSONEncoder().encode(payload).write(to: url)

        let store = DictionaryStore(fileURL: url, blocklistFileURL: url.appendingPathExtension("blocklist"))
        XCTAssertEqual(store.entries.count, 1)
        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(entry.id, keepuID)
        XCTAssertEqual(Set(entry.variants.map { $0.lowercased() }), ["keepu", "keefu"])
        XCTAssertEqual(entry.fixCount, 4)

        let reloaded = DictionaryStore(fileURL: url, blocklistFileURL: url.appendingPathExtension("blocklist"))
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.id, keepuID)
    }

    func testUpdateRenamesIntoExistingMerges() {
        let store = makeStore()
        store.add(term: "Khipu", variants: ["Keepu"])
        store.add(term: "Keepoo", variants: ["Keefu"])
        XCTAssertEqual(store.entries.count, 2)
        guard var duplicate = store.entries.first(where: { $0.term == "Keepoo" }) else {
            return XCTFail("missing Keepoo entry")
        }
        duplicate.term = "Khipu"
        store.update(duplicate)
        XCTAssertEqual(store.entries.count, 1)
        let entry = store.entries.first
        XCTAssertEqual(entry?.term, "Khipu")
        XCTAssertEqual(Set(entry?.variants.map { $0.lowercased() } ?? []), ["keepu", "keefu"])
    }

    func testManualAddClearsAutoLearnedFlag() {
        let store = makeStore()
        _ = store.learn(from: "Keepu", to: "Khipu", userInitiated: true)
        XCTAssertEqual(store.entries.first?.isAutoLearned, true)
        store.add(term: "Khipu", variants: ["Keefu"])
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.isAutoLearned, false)
        XCTAssertEqual(Set(store.entries.first?.variants.map { $0.lowercased() } ?? []), ["keepu", "keefu"])
    }

    func testUnlearnCreatedNewPreservesOtherMergedVariants() {
        let store = makeStore()
        let learned = store.learn(from: "Keepu", to: "Khipu", userInitiated: true)
        XCTAssertEqual(learned.count, 1)
        XCTAssertEqual(learned.first?.createdNewEntry, true)
        store.add(term: "Khipu", variants: ["Keefu"])
        XCTAssertTrue(store.unlearn(learned[0]))
        XCTAssertEqual(store.entries.count, 1)
        let entry = store.entries.first
        XCTAssertEqual(entry?.term, "Khipu")
        XCTAssertEqual(Set(entry?.variants.map { $0.lowercased() } ?? []), ["keefu"])
    }

    func testUnlearnCreatedNewStillDeletesSoleVariantEntry() {
        let store = makeStore()
        let learned = store.learn(from: "Keepu", to: "Khipu", userInitiated: true)
        XCTAssertEqual(learned.count, 1)
        XCTAssertTrue(store.unlearn(learned[0]))
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testUnlearnFallsBackAfterDuplicateTermMerge() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dict-unlearn-merge-\(UUID().uuidString).json")
        let survivorID = UUID()
        let absorbedID = UUID()
        let payload: [DictionaryEntry] = [
            DictionaryEntry(
                id: survivorID,
                term: "Khipu",
                variants: ["Keepu"],
                fixCount: 1,
                isAutoLearned: true
            ),
            DictionaryEntry(
                id: absorbedID,
                term: "Khipu",
                variants: ["Keefu"],
                fixCount: 2,
                isAutoLearned: false
            )
        ]
        try JSONEncoder().encode(payload).write(to: url)

        let store = DictionaryStore(fileURL: url, blocklistFileURL: url.appendingPathExtension("blocklist"))
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.id, survivorID)

        let correction = LearnedCorrection(
            variant: "Keefu",
            term: "Khipu",
            createdNewEntry: true,
            entryID: absorbedID
        )
        XCTAssertTrue(store.unlearn(correction))
        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(entry.id, survivorID)
        XCTAssertEqual(Set(entry.variants.map { $0.lowercased() }), ["keepu"])
        XCTAssertFalse(entry.isAutoLearned)
    }

    /// 2026-08-25 incident: ASR wrote "Type" for "the"; the user's hand-fix
    /// was offered as a learned rule mapping "Type" -> "the", which would have
    /// rewritten every legitimate "type" from then on. "type" is protected
    /// heard-side, so neither direction of that pair can be learned.
    /// (Typo fixes TO a function word, like "teh" -> "the", stay learnable.)
    func testLearnRefusesProtectedEnglishTerm() {
        let store = makeStore()
        for userInitiated in [true, false] {
            let learned = store.learn(
                from: "I like Type keyboard",
                to: "I like the keyboard",
                userInitiated: userInitiated
            )
            XCTAssertTrue(learned.isEmpty, "userInitiated=\(userInitiated)")
        }
        XCTAssertFalse(store.entries.contains { $0.term.caseInsensitiveCompare("the") == .orderedSame })
    }

    /// "type" is protected on the heard side too: no learned or phonetic rule
    /// may steal it as a variant of some jargon term.
    func testTypeIsProtectedHeardToken() {
        XCTAssertTrue(PhoneticMatcher.isProtectedHeardToken("type"))
        XCTAssertTrue(PhoneticMatcher.isProtectedHeardToken("Type"))
        let store = makeStore()
        let learned = store.learn(
            from: "use type here",
            to: "use Tauri here",
            userInitiated: true
        )
        XCTAssertTrue(learned.isEmpty)
    }

    func testSingleLetterEditDoesNotLearnPronounVariant() {
        let store = makeStore()
        let learned = store.learn(from: "I think", to: "We think", userInitiated: true)
        XCTAssertTrue(learned.isEmpty)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testSplitLearningRefusesSingleLetterNumericAndPronounVariants() {
        let store = makeStore()
        for (old, new) in [("x", "ex axis"), ("42", "forty two"), ("we", "the team"), ("I", "the speaker")] {
            XCTAssertTrue(store.learn(from: old, to: new, userInitiated: true).isEmpty, old)
        }
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testMergeLearningRefusesNumericAndProtectedPronounPhrases() {
        let store = makeStore()
        for (old, new) in [("12 34", "1234"), ("we are", "weare"), ("I am", "iam")] {
            XCTAssertTrue(store.learn(from: old, to: new, userInitiated: true).isEmpty, old)
        }
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testSplitLearningStillLearnsOrdinaryVariant() {
        let store = makeStore()
        let learned = store.learn(from: "gitignore", to: "git ignore", userInitiated: true)
        XCTAssertEqual(learned.count, 1)
        XCTAssertEqual(learned.first?.variant, "gitignore")
        XCTAssertEqual(learned.first?.term, "git ignore")
    }

    func testRejectKeepsManuallyAdoptedEntryWithSoleLearnedVariant() throws {
        let store = makeStore()
        let learned = store.learn(from: "Keepu", to: "Khipu", userInitiated: true)
        XCTAssertEqual(learned.count, 1)
        store.add(term: "Khipu", variants: ["Keepu"])
        store.rejectLearnedBatch(LearnBatch(corrections: learned))
        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(entry.id, learned.first?.entryID)
        XCTAssertEqual(entry.term, "Khipu")
        XCTAssertFalse(entry.isAutoLearned)
        XCTAssertTrue(entry.variants.isEmpty)
    }

    func testRejectStillDeletesUnadoptedLearnedEntry() {
        let store = makeStore()
        let learned = store.learn(from: "Keepu", to: "Khipu", userInitiated: true)
        XCTAssertEqual(learned.count, 1)
        store.rejectLearnedBatch(LearnBatch(corrections: learned))
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testCommonPronounsAreProtectedHeardTokens() {
        for word in ["i", "I", "us", "our", "your", "his", "her", "its", "them", "their", "me", "my", "we", "he", "she", "it"] {
            XCTAssertTrue(PhoneticMatcher.isProtectedHeardToken(word), word)
        }
    }
}
