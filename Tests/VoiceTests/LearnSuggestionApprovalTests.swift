import AppKit
import SwiftUI
import XCTest
@testable import Voice

/// Auto-learned rules are suggestions: inert until the user taps Add.
/// Every store lives in a fresh temp directory: no real Application Support
/// files, no Keychain.
@MainActor
final class LearnSuggestionApprovalTests: XCTestCase {

    /// The coordinator binds with weak captures; keep it alive per test.
    private var retainedCoordinators: [LearnEventsCoordinator] = []

    override func tearDown() {
        retainedCoordinators.removeAll()
        super.tearDown()
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("learn-suggest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeStore(in directory: URL? = nil) throws -> DictionaryStore {
        let directory = try directory ?? makeDirectory()
        return DictionaryStore(
            fileURL: directory.appendingPathComponent("dictionary.json"),
            blocklistFileURL: directory.appendingPathComponent("blocklist.json"),
            learnCandidatesFileURL: directory.appendingPathComponent("learn-candidates.json"),
            lexicon: RealWordLexicon { _ in false }
        )
    }

    private func makeCoordinator(store: DictionaryStore, directory: URL) -> (LearnEventsCoordinator, LearnToastHUD) {
        let toast = LearnToastHUD()
        let coordinator = LearnEventsCoordinator(
            correctionsLog: CorrectionsLog(fileURL: directory.appendingPathComponent("corrections.json")),
            dictionaryStore: store,
            learnToast: toast
        )
        coordinator.bind()
        retainedCoordinators.append(coordinator)
        return (coordinator, toast)
    }

    private func correction(_ variant: String, term: String = "Term") -> LearnBatch {
        LearnBatch(corrections: [
            LearnedCorrection(variant: variant, term: term, createdNewEntry: true, entryID: UUID())
        ])
    }

    // MARK: - Pending rules do nothing

    func testPendingEntryNeverRewritesTextAndIsAbsentFromEngineVocabulary() throws {
        let store = try makeStore()
        let learned = store.learnSeenTwice(from: "Groq", to: "Grok")
        XCTAssertEqual(learned.map(\.term), ["Grok"])
        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertTrue(entry.isPendingApproval)

        // Literal variant pass and phonetic pass both skip it.
        let result = store.correct("try Groq and grock")
        XCTAssertEqual(result.text, "try Groq and grock")
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(store.entries.first?.fixCount, 0)

        XCTAssertTrue(store.activeEntries.isEmpty)
        XCTAssertFalse(ElevenLabsRealtimeTranscriber.selectKeyterms(from: store.entries).contains("Grok"))
        XCTAssertFalse(GeminiLiveTranscriber.selectVocabulary(from: store.entries).contains("Grok"))
        XCTAssertFalse(MuseLiveTranscriber.selectKeywords(from: store.entries).contains("Grok"))
    }

    func testPendingTermIsNoPhoneticTarget() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("dictionary.json")
        try JSONEncoder().encode([
            DictionaryEntry(term: "Heiser", variants: [], isAutoLearned: true)
        ]).write(to: url)
        let store = try makeStore(in: directory)
        XCTAssertEqual(store.correct("we listened to hyzer").text, "we listened to hyzer")

        store.approvePending(try XCTUnwrap(store.entries.first))
        XCTAssertEqual(store.correct("we listened to hyzer").text, "we listened to Heiser")
    }

    /// Entries written before this change (no `pendingVariants` key) that are
    /// auto-learned load as pending: nothing auto-approves them.
    func testExistingAutoLearnedEntriesOnDiskLoadAsPending() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("dictionary.json")
        let legacy = """
        [{"id":"\(UUID().uuidString)","term":"Khipu","variants":["Keepu"],"fixCount":4,"isAutoLearned":true},
         {"id":"\(UUID().uuidString)","term":"Tauri","variants":["Tari"],"fixCount":1}]
        """
        try Data(legacy.utf8).write(to: url)
        let store = try makeStore(in: directory)

        XCTAssertEqual(store.pendingEntries.map(\.term), ["Khipu"])
        XCTAssertEqual(store.activeEntries.map(\.term), ["Tauri"])
        XCTAssertEqual(store.correct("Keepu and Tari").text, "Keepu and Tauri")
        XCTAssertEqual(ElevenLabsRealtimeTranscriber.selectKeyterms(from: store.entries), ["Tauri"])
    }

    func testLearnedVariantOnApprovedEntryWaitsForApproval() throws {
        let store = try makeStore()
        store.add(term: "Zork", variants: ["Zorg"])
        let learned = store.learnSeenTwice(from: "Zorp", to: "Zork")
        XCTAssertEqual(learned.first?.createdNewEntry, false)
        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(entry.variants, ["Zorg"])
        XCTAssertEqual(entry.pendingVariants, ["Zorp"])
        XCTAssertEqual(store.correct("Zorp Zorg").text, "Zorp Zork")

        store.approveLearnedBatch(LearnBatch(corrections: learned))
        XCTAssertEqual(store.entries.first?.variants, ["Zorg", "Zorp"])
        XCTAssertEqual(store.entries.first?.pendingVariants, [])
        XCTAssertEqual(store.correct("Zorp Zorg").text, "Zork Zork")
    }

    // MARK: - Add / Never / decide later

    func testAddFromPopUpMakesRuleApply() throws {
        let directory = try makeDirectory()
        let store = try makeStore(in: directory)
        let (_, toast) = makeCoordinator(store: store, directory: directory)

        _ = store.learnSeenTwice(from: "Groq", to: "Grok")
        XCTAssertEqual(toast.state.current?.corrections.map(\.variant), ["Groq"])
        XCTAssertEqual(store.correct("try Groq").text, "try Groq")

        toast.performAdd()
        XCTAssertNil(toast.state.current)
        XCTAssertFalse(try XCTUnwrap(store.entries.first).isAutoLearned)
        XCTAssertEqual(store.correct("try Groq").text, "try Grok")
        XCTAssertEqual(ElevenLabsRealtimeTranscriber.selectKeyterms(from: store.activeEntries), ["Grok"])
    }

    func testNeverFromPopUpBlocklists() throws {
        let directory = try makeDirectory()
        let store = try makeStore(in: directory)
        let (_, toast) = makeCoordinator(store: store, directory: directory)

        _ = store.learnSeenTwice(from: "Groq", to: "Grok")
        toast.performNever()
        XCTAssertNil(toast.state.current)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.isBlocklisted(heard: "Groq", replaced: "Grok"))
        XCTAssertTrue(store.learnSeenTwice(from: "Groq", to: "Grok").isEmpty, "never suggested again")
    }

    func testDecideLaterLeavesSuggestionPendingAndInert() throws {
        let directory = try makeDirectory()
        let store = try makeStore(in: directory)
        let (_, toast) = makeCoordinator(store: store, directory: directory)

        _ = store.learnSeenTwice(from: "Groq", to: "Grok")
        toast.performDecideLater()
        XCTAssertNil(toast.state.current)
        XCTAssertEqual(store.pendingEntries.map(\.term), ["Grok"])
        XCTAssertFalse(store.isBlocklisted(heard: "Groq", replaced: "Grok"))
        XCTAssertEqual(store.correct("try Groq").text, "try Groq")
    }

    func testDictionaryAddApprovesAndClearsMatchingPopUpLine() throws {
        let directory = try makeDirectory()
        let store = try makeStore(in: directory)
        let (_, toast) = makeCoordinator(store: store, directory: directory)

        _ = store.learnSeenTwice(from: "Groq", to: "Grok")
        XCTAssertNotNil(toast.state.current)
        store.approvePending(try XCTUnwrap(store.pendingEntries.first))
        XCTAssertNil(toast.state.current, "approved elsewhere: pop-up drops it")
        XCTAssertTrue(store.pendingEntries.isEmpty)
        XCTAssertEqual(store.correct("try Groq").text, "try Grok")
    }

    func testDictionaryNeverRejectsBlocklistsAndClearsPopUp() throws {
        let directory = try makeDirectory()
        let store = try makeStore(in: directory)
        let (_, toast) = makeCoordinator(store: store, directory: directory)
        store.add(term: "Grok", variants: [])
        _ = store.learnSeenTwice(from: "Groq", to: "Grok")
        XCTAssertNotNil(toast.state.current)

        store.rejectPending(try XCTUnwrap(store.pendingEntries.first))
        XCTAssertNil(toast.state.current)
        XCTAssertTrue(store.isBlocklisted(heard: "Groq", replaced: "Grok"))
        let entry = try XCTUnwrap(store.entries.first, "hand-added term survives")
        XCTAssertTrue(entry.pendingVariants.isEmpty)
        XCTAssertTrue(store.pendingEntries.isEmpty)
    }

    // MARK: - Lifetime

    func testPopUpHasNoAutoDismiss() throws {
        let toast = LearnToastHUD()
        toast.show(batch: correction("Groq", term: "Grok"))
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        XCTAssertEqual(toast.state.current?.corrections.map(\.variant), ["Groq"])
        XCTAssertTrue(toast.state.isOnScreen)
    }

    func testSuggestionsAreNotDroppedWhenQueueIsFull() {
        let toast = LearnToastHUD()
        let variants = (0..<8).map { "heard\($0)" }
        for variant in variants {
            toast.show(batch: correction(variant))
        }
        XCTAssertEqual(toast.state.queued.count, LearnToastState.maxQueued)
        var seen: [String] = []
        while let batch = toast.state.current {
            seen += batch.corrections.map(\.variant)
            toast.performDecideLater()
        }
        XCTAssertEqual(Set(seen), Set(variants))
    }

    func testHiddenDuringDictationAndShownAfter() {
        let toast = LearnToastHUD()
        toast.setDictationActive(true)
        toast.show(batch: correction("Groq", term: "Grok"))
        XCTAssertFalse(toast.state.isOnScreen)
        XCTAssertNotNil(toast.state.current)
        toast.setDictationActive(false)
        XCTAssertTrue(toast.state.isOnScreen)
        toast.setDictationActive(true)
        XCTAssertFalse(toast.state.isOnScreen)
        XCTAssertNotNil(toast.state.current, "hiding for a dictation never drops it")
    }

    // MARK: - Rendered proof

    /// Writes `/tmp/murmur-learn-toast.png` (one and three suggestions, dark)
    /// so the pop-up can be reviewed without running the app.
    func testRenderSuggestionPopUpToPNG() throws {
        let one = LearnBatch(corrections: [
            LearnedCorrection(variant: "Groq", term: "Grok", createdNewEntry: true, entryID: UUID())
        ])
        let three = LearnBatch(corrections: [("Keepu", "Khipu"), ("Tari", "Tauri"), ("cube net ease", "Kubernetes")].map {
            LearnedCorrection(variant: $0.0, term: $0.1, createdNewEntry: true, entryID: UUID())
        })
        let five = LearnBatch(corrections: three.corrections + [("Groq", "Grok"), ("Oyama", "Ollama")].map {
            LearnedCorrection(variant: $0.0, term: $0.1, createdNewEntry: true, entryID: UUID())
        })
        let root = VStack(alignment: .leading, spacing: 18) {
            ForEach([one, three, five]) { batch in
                LearnToastContent(batch: batch, onAdd: {}, onNever: {}, onDecideLater: {})
            }
        }
        .padding(24)
        .frame(width: 420, alignment: .leading)
        .background(Theme.bg)
        .preferredColorScheme(.dark)

        let view = NSHostingView(rootView: root)
        view.appearance = NSAppearance(named: .darkAqua)
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: "/tmp/murmur-learn-toast.png")
        try png.write(to: url, options: .atomic)
        XCTAssertGreaterThan(png.count, 1_000)

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "learn-suggestion-popup"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
