import AppKit
import SwiftUI
import XCTest
@testable import Voice

final class Polish030Tests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("polish-030-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private struct RGBA {
        let r: Double
        let g: Double
        let b: Double
        var a: Double = 1

        func over(_ background: RGBA) -> RGBA {
            RGBA(r: r * a + background.r * (1 - a),
                 g: g * a + background.g * (1 - a),
                 b: b * a + background.b * (1 - a))
        }
    }

    private func wcagContrast(_ foreground: RGBA, _ background: RGBA) -> Double {
        func luminance(_ color: RGBA) -> Double {
            func linear(_ component: Double) -> Double {
                component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b)
        }
        let back = luminance(background)
        let front = luminance(foreground.over(background))
        return (max(front, back) + 0.05) / (min(front, back) + 0.05)
    }

    @MainActor
    private func rgba(_ color: Color) throws -> RGBA {
        let color = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        return RGBA(r: color.redComponent, g: color.greenComponent, b: color.blueComponent, a: color.alphaComponent)
    }

    func testWCAGReferencePairsAndAlphaCompositing() {
        let black = RGBA(r: 0, g: 0, b: 0)
        let white = RGBA(r: 1, g: 1, b: 1)
        XCTAssertEqual(wcagContrast(black, white), 21, accuracy: 0.00001)
        XCTAssertEqual(wcagContrast(white, white), 1, accuracy: 0.00001)
        let translucentBlack = RGBA(r: 0, g: 0, b: 0, a: 0.5)
        XCTAssertEqual(wcagContrast(translucentBlack, white), 3.97665, accuracy: 0.00001)
    }

    @MainActor
    func testThemePairsMeetSmallTextContrast() throws {
        let bg = try rgba(Theme.bg)
        let failed = try rgba(Theme.amberBgSubtle).over(bg)
        let selected = try rgba(Theme.selectionTint).over(bg)
        let coral = try rgba(Theme.lavender)
        let pairs: [(String, RGBA, RGBA, RGBA)] = [
            ("Failed History label", try rgba(Theme.recordRed.opacity(0.85)), try rgba(Theme.errorText), failed),
            ("Selected note metadata", try rgba(Theme.textSecondary), try rgba(Theme.selectedText), selected),
            ("Coral CTA label", try rgba(Theme.lavenderText), try rgba(Theme.ctaText), coral)
        ]
        for (name, old, new, background) in pairs {
            let before = wcagContrast(old, background)
            let after = wcagContrast(new, background)
            XCTAssertLessThan(before, 4.5, name)
            XCTAssertGreaterThanOrEqual(after, 4.5, name)
            print(String(format: "Contrast %@: %.2f:1 -> %.2f:1", name, before, after))
        }
    }

    func testSaveFailureNoticeOnlyReportsOnceEvenAfterDismissal() {
        var notice = SaveFailureNotice()
        notice.report("First failure")
        notice.report("Second failure")
        XCTAssertEqual(notice.message, "First failure")
        notice.dismiss()
        notice.report("Third failure")
        XCTAssertNil(notice.message)
    }

    @MainActor
    func testHistoryFailedWriteReportsOnceAndPreservesInMemoryEntry() {
        let store = HistoryStore(fileURL: directory.appendingPathComponent("missing/history.json"))
        store.append(text: "Keep these words", engine: "test", injected: true)
        XCTAssertNotNil(store.saveFailure.message)
        XCTAssertEqual(store.entries.first?.text, "Keep these words")
        store.dismissSaveFailure()
        store.flush()
        XCTAssertNil(store.saveFailure.message)
    }

    @MainActor
    func testScratchpadFailedWriteReportsOnceAndPreservesInMemoryNote() {
        let store = ScratchpadStore(fileURL: directory.appendingPathComponent("missing/notes.json"))
        let note = store.newNote()
        XCTAssertNotNil(store.saveFailure.message)
        store.update(id: note.id, title: "Keep this note", body: "Words")
        store.flush()
        XCTAssertEqual(store.notes.first?.body, "Words")
        store.dismissSaveFailure()
        store.flush()
        XCTAssertNil(store.saveFailure.message)
    }

    @MainActor
    func testDictionaryFailedWriteReportsOnceAndPreservesInMemoryEntry() {
        let store = DictionaryStore(fileURL: directory.appendingPathComponent("missing/dictionary.json"),
                                    blocklistFileURL: directory.appendingPathComponent("blocklist.json"))
        store.add(term: "Kubernetes", variants: ["koober nettys"])
        store.flush()
        XCTAssertNotNil(store.saveFailure.message)
        XCTAssertEqual(store.entries.first?.term, "Kubernetes")
        store.dismissSaveFailure()
        store.flush()
        XCTAssertNil(store.saveFailure.message)
    }

    @MainActor
    func testDictionaryBlocklistFailedWriteReportsFailure() {
        let store = DictionaryStore(fileURL: directory.appendingPathComponent("dictionary.json"),
                                    blocklistFileURL: directory.appendingPathComponent("missing/blocklist.json"))
        store.blocklistPair(heard: "alpha", replaced: "beta")
        store.flush()
        XCTAssertNotNil(store.saveFailure.message)
    }

    @MainActor
    func testUnreadableStoresExposeBlockedSaveWarning() throws {
        // A directory cannot be read as JSON; no permission changes or real user files.
        let history = HistoryStore(fileURL: directory)
        let scratchpad = ScratchpadStore(fileURL: directory)
        let dictionary = DictionaryStore(fileURL: directory,
                                         blocklistFileURL: directory.appendingPathComponent("blocklist.json"))
        XCTAssertNotNil(history.saveFailure.message)
        XCTAssertNotNil(scratchpad.saveFailure.message)
        XCTAssertNotNil(dictionary.saveFailure.message)
        history.flush()
        scratchpad.flush()
        dictionary.flush()
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testDictionarySearchTrimsWhitespaceAndMatchesAllEntryKinds() {
        let manual = DictionaryEntry(term: "Alpha", variants: ["alfa"])
        let learned = DictionaryEntry(term: "Beta", variants: ["ALFABET"], isAutoLearned: true)
        let other = DictionaryEntry(term: "Gamma", variants: ["gama"])
        let results = DictionarySearch.entries([manual, learned, other], query: " \n ALFA \t ")
        XCTAssertEqual(results.map(\.id), [manual.id, learned.id])
        XCTAssertEqual(results.filter(\.isAutoLearned).map(\.id), [learned.id])
        XCTAssertEqual(DictionarySearch.entries([manual, learned], query: " \n\t"), [manual, learned])
        XCTAssertTrue(DictionarySearch.entries([manual, learned], query: "absent").isEmpty)
    }

    func testDictionarySearchFiltersRecentRowsAndCountsEveryVisibleSection() {
        let first = CorrectionRecord(heard: "ALFA", replaced: "Alpha", source: .dictionary)
        let second = CorrectionRecord(heard: "other", replaced: "Alpha", source: .learnAccepted)
        let group = CorrectionGroup(replaced: "Alpha", rows: [first, second], recordIDs: [first.id, second.id])
        let matches = DictionarySearch.corrections([group], query: " \n alfa ")
        XCTAssertEqual(matches.first?.rows, [first])
        XCTAssertEqual(matches.first?.recordIDs, [first.id])
        XCTAssertEqual(DictionarySearch.corrections([group], query: " alpha "), [group])
        XCTAssertEqual(DictionarySearch.corrections([group], query: " \t\n"), [group])
        XCTAssertTrue(DictionarySearch.corrections([group], query: "absent").isEmpty)
        let learned = DictionaryEntry(term: "Alpha", variants: ["alfa"], isAutoLearned: true)
        XCTAssertEqual(DictionarySearch.resultCount(entries: [learned], groups: matches), 3)
    }

    func testDictionarySearchSortsDisplayEntriesWithoutMutatingInput() {
        let tieFirst = DictionaryEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            term: "Áegis",
            variants: []
        )
        let tieSecond = DictionaryEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            term: "aegis",
            variants: []
        )
        let entries = [
            DictionaryEntry(term: "Z", variants: []),
            DictionaryEntry(term: "xAI", variants: []),
            DictionaryEntry(term: "Wispr Flow", variants: ["WhisperFlow"]),
            DictionaryEntry(term: "tavily", variants: []),
            DictionaryEntry(term: "Tauri", variants: []),
            tieSecond,
            tieFirst
        ]
        let original = entries

        let sorted = DictionarySearch.sortedEntries(entries)

        XCTAssertEqual(sorted.map(\.term), ["Áegis", "aegis", "Tauri", "tavily", "Wispr Flow", "xAI", "Z"])
        XCTAssertEqual(entries, original, "sorting is display-only and must not rewrite store input")
        XCTAssertEqual(DictionarySearch.sortedEntries(Array(entries.reversed())).map(\.id), sorted.map(\.id))
        let pending = entries.map { entry in
            var pendingEntry = entry
            pendingEntry.isAutoLearned = true
            return pendingEntry
        }
        XCTAssertEqual(DictionarySearch.sortedEntries(pending).map(\.term), sorted.map(\.term))
        XCTAssertEqual(DictionarySearch.sortedEntries(DictionarySearch.entries(entries, query: " flow ")).map(\.term), ["Wispr Flow"])
    }

    func testDictionaryVariantInputParsesCommaSeparatedPreviewValues() {
        XCTAssertEqual(
            DictionaryEntryInput.variants(from: " cube net ease, , cooper netties ,\n\t"),
            ["cube net ease", "cooper netties"]
        )
    }

    @MainActor
    func testDictionaryLayoutSnapshotsAtMainPaneWidths() throws {
        let dictionaryURL = directory.appendingPathComponent("dictionary.json")
        try JSONEncoder().encode([
            DictionaryEntry(term: "Tauri", variants: ["Tari"], fixCount: 1),
            DictionaryEntry(term: "Wispr Flow", variants: ["WhisperFlow", "whisper flow"], fixCount: 2),
            DictionaryEntry(term: "tavily", variants: ["Tivoli"], isAutoLearned: true)
        ]).write(to: dictionaryURL)
        let store = DictionaryStore(
            fileURL: dictionaryURL,
            blocklistFileURL: directory.appendingPathComponent("dictionary-blocklist.json")
        )

        let corrections = CorrectionsLog(fileURL: directory.appendingPathComponent("corrections.json"))
        corrections.append([
            CorrectionRecord(heard: "Tari", replaced: "Tauri", source: .dictionary),
            CorrectionRecord(heard: "WhisperFlow", replaced: "Wispr Flow", source: .dictionary)
        ])

        let height: CGFloat = 1_050
        for width: CGFloat in [439, 559] {
            let view = NSHostingView(
                rootView: DictionaryView(store: store, correctionsLog: corrections)
                    .frame(width: width, height: height)
                    .background(Theme.bg)
                    .preferredColorScheme(.dark)
            )
            view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            view.layoutSubtreeIfNeeded()

            XCTAssertTrue(view.bounds.width.isFinite && view.bounds.height.isFinite)
            XCTAssertEqual(view.bounds.width, width)
            XCTAssertEqual(view.bounds.height, height)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
            XCTAssertEqual(bitmap.pixelsWide, Int(width * scale))
            XCTAssertEqual(bitmap.pixelsHigh, Int(height * scale))

            let image = NSImage(size: bitmap.size)
            image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = "dictionary-correct-first-\(Int(width))w"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        store.flush()
        corrections.flush()
    }

    func testRetryStateKeepsConcurrentRowsIndependentAndRejectsDuplicateStart() {
        let first = UUID()
        let second = UUID()
        var state = HistoryRetryState()
        XCTAssertTrue(state.begin(first))
        XCTAssertTrue(state.begin(second))
        XCTAssertFalse(state.begin(first))
        state.finish(second)
        XCTAssertTrue(state.contains(first))
        XCTAssertFalse(state.contains(second))
        state.finish(second)
        state.finish(first)
        XCTAssertFalse(state.contains(first))
        XCTAssertTrue(state.begin(first))
    }

    func testCancelledDownloadReturnsToIdleAndRealFailuresRemainVisible() {
        XCTAssertEqual(ModelManager.downloadFailureState(cancelled: true, message: "cancelled"), .idle)
        XCTAssertEqual(ModelManager.downloadFailureState(cancelled: false, message: "offline"), .failed("offline"))
    }

    func testHUDAndLearnAnnouncementsNameEveryState() {
        XCTAssertEqual(RecordingHUD.State.listening.accessibilityAnnouncement, "Listening")
        XCTAssertEqual(RecordingHUD.State.processing.accessibilityAnnouncement, "Transcribing")
        XCTAssertEqual(RecordingHUD.State.success.accessibilityAnnouncement, "Dictation complete")
        XCTAssertEqual(RecordingHUD.State.clipboardFlash.accessibilityAnnouncement, "Text copied to clipboard")
        XCTAssertEqual(RecordingHUD.State.error("Try again").accessibilityAnnouncement, "Dictation failed. Try again")
        XCTAssertEqual(LearnToastHUD.learnedAnnouncement(count: 1), "Learned 1 dictionary correction")
        XCTAssertEqual(LearnToastHUD.learnedAnnouncement(count: 3), "Learned 3 dictionary corrections")
    }
}
