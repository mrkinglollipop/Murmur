import AppKit
import XCTest
@testable import Voice

@MainActor
final class DictionaryTypographyTests: XCTestCase {
    private let typographyPairs = [
        ("don't", "don’t"), ("there's", "there’s"), ("it's", "it’s"),
        ("I've", "I’ve"), ("doesn't", "doesn’t"), ("I'll", "I’ll"),
        ("foo-bar", "foo–bar"), ("foo-bar", "foo—bar"),
        ("foo...bar", "foo…bar"), ("foo\"bar", "foo“bar"),
        ("foo\"bar", "foo”bar"), ("foo'bar", "foo‘bar"),
        ("foo bar", "foo\u{00A0}bar"), ("foo bar", "foo\u{202F}bar")
    ]

    private func makeStore(_ entries: [DictionaryEntry] = []) throws -> (DictionaryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictionary-typography-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("dictionary.json")
        try JSONEncoder().encode(entries).write(to: url)
        let lexicon = RealWordLexicon { ["idea", "whisper"].contains($0) }
        let store = DictionaryStore(fileURL: url, blocklistFileURL: directory.appendingPathComponent("blocklist.json"), lexicon: lexicon)
        addTeardownBlock {
            store.flush()
            try FileManager.default.removeItem(at: directory)
        }
        return (store, url)
    }

    private func pollutedEntries() -> [DictionaryEntry] {
        typographyPairs.prefix(6).enumerated().map { index, pair in
            DictionaryEntry(term: pair.1, variants: [pair.0], fixCount: 90 - index, isAutoLearned: true)
        }
    }

    func testLearningIgnoresTypographyForAutomaticAndUserInitiatedEdits() throws {
        for userInitiated in [false, true] {
            for (old, new) in typographyPairs {
                let (store, _) = try makeStore()
                var events = 0
                store.onLearnBatch = { _ in events += 1 }
                XCTAssertTrue(store.learn(from: old, to: new, userInitiated: userInitiated, announce: false).isEmpty, old)
                XCTAssertTrue(store.entries.isEmpty, old)
                XCTAssertEqual(events, 0, old)
            }
        }
    }

    func testTypographyDoesNotExtendManualEntryOrHideRealCorrectionInMixedEdit() throws {
        let manual = DictionaryEntry(term: "don’t", variants: ["dnot"])
        let (store, _) = try makeStore([manual])
        let learned = store.learn(from: "don't Keepu", to: "don’t Khipu", userInitiated: true, announce: false)
        XCTAssertEqual(learned.map(\.term), ["Khipu"])
        XCTAssertEqual(store.entries.first(where: { $0.id == manual.id }), manual)
    }

    func testWatcherRegionDiffIgnoresOnlyTypography() {
        for (old, new) in typographyPairs {
            XCTAssertNil(CorrectionExtractor.regionDiff(
                snapshotValue: "prefix " + old + " suffix",
                injectedUTF16Location: "prefix ".utf16.count,
                injectedUTF16Length: old.utf16.count,
                currentValue: "prefix " + new + " suffix"
            ), old)
        }
        XCTAssertNotNil(CorrectionExtractor.regionDiff(
            snapshotValue: "don't Keepu", injectedUTF16Location: 0,
            injectedUTF16Length: "don't Keepu".utf16.count, currentValue: "don’t Khipu"
        ))
    }

    func testLoadRemovesOnlyEntirelyTypographicAutoEntriesAndPersistsCleanup() throws {
        let manual = DictionaryEntry(term: "xAI", variants: ["XAI"], fixCount: 7)
        let manualTypography = DictionaryEntry(term: "don’t", variants: ["don't"], fixCount: 4)
        let mixed = DictionaryEntry(term: "I’ll", variants: ["I'll", "aill"], isAutoLearned: true)
        let real = DictionaryEntry(term: "Khipu", variants: ["Keepu"], isAutoLearned: true)
        let expected = [manual, manualTypography, mixed, real]
        let (store, url) = try makeStore(pollutedEntries() + expected)
        XCTAssertEqual(store.entries, expected)
        XCTAssertEqual(try JSONDecoder().decode([DictionaryEntry].self, from: Data(contentsOf: url)), expected)
        let saved = try Data(contentsOf: url)
        let reloaded = DictionaryStore(fileURL: url, blocklistFileURL: url.deletingLastPathComponent().appendingPathComponent("blocklist.json"))
        XCTAssertEqual(reloaded.entries, expected)
        XCTAssertEqual(try Data(contentsOf: url), saved)
    }

    func testPollutedDictionaryDoesNotRewriteSpeech() throws {
        let (store, _) = try makeStore(pollutedEntries())
        for token in ["we've", "We've", "ideas", "I'd", "they've", "we’ve", "I’d", "they’ve"] {
            let result = store.correct(token)
            XCTAssertEqual(result.text, token)
            XCTAssertTrue(result.records.isEmpty, token)
        }
    }

    func testManualContractionsAndEnglishWordsCannotBePhoneticTargets() throws {
        let (store, _) = try makeStore([
            DictionaryEntry(term: "I’ve", variants: []),
            DictionaryEntry(term: "whisper", variants: [])
        ])
        for token in ["we've", "We've", "we’ve", "wispr"] {
            XCTAssertEqual(store.correct(token).text, token)
            XCTAssertTrue(store.correct(token).records.isEmpty)
        }
    }

    func testProperNounCorrectionsStillApply() throws {
        let (store, _) = try makeStore([
            DictionaryEntry(term: "Khipu", variants: []),
            DictionaryEntry(term: "Tauri", variants: []),
            // Oyama and Ollama have different metaphone keys; this explicit
            // variant is needed even before the speech-protection changes.
            DictionaryEntry(term: "Ollama", variants: ["Oyama"])
        ])
        let result = store.correct("Keepu Tari Oyama")
        XCTAssertEqual(result.text, "Khipu Tauri Ollama")
        XCTAssertEqual(result.records.count, 3)
        XCTAssertEqual(result.records.map(\.source), [.dictionary, .phonetic, .phonetic])
    }

    func testRealWordPluralsAreProtectedAgainstJargonTargets() throws {
        let (store, _) = try makeStore([DictionaryEntry(term: "Idias", variants: [])])
        let result = store.correct("ideas")
        XCTAssertEqual(result.text, "ideas")
        XCTAssertTrue(result.records.isEmpty)
        let lexicon = RealWordLexicon { ["idea", "box", "party"].contains($0) }
        XCTAssertTrue(lexicon.contains("ideas"))
        XCTAssertTrue(lexicon.contains("boxes"))
        XCTAssertTrue(lexicon.contains("parties"))
    }

    func testTypographyNormalizationPreservesCaseAndRealTextDifferences() {
        for (old, new) in typographyPairs {
            XCTAssertEqual(CorrectionExtractor.normalizingTypography(old), CorrectionExtractor.normalizingTypography(new))
        }
        XCTAssertNotEqual(CorrectionExtractor.normalizingTypography("xAI"), CorrectionExtractor.normalizingTypography("XAI"))
        XCTAssertNotEqual(CorrectionExtractor.normalizingTypography("foo bar"), CorrectionExtractor.normalizingTypography("foobar"))
    }

    func testAppliedCountAndLogExcludeTypographicAndIdenticalReplacements() throws {
        let (store, url) = try makeStore([
            DictionaryEntry(term: "foo–bar", variants: ["foo-bar"]),
            DictionaryEntry(term: "xAI", variants: ["XAI"]),
            DictionaryEntry(term: "Khipu", variants: ["Keepu"])
        ])
        let result = store.correct("foo-bar xAI Keepu")
        XCTAssertEqual(result.text, "foo–bar xAI Khipu")
        XCTAssertEqual(result.records.map(\.replaced), ["Khipu"])
        XCTAssertEqual(store.entries.map(\.fixCount), [0, 0, 1])
        let log = CorrectionsLog(fileURL: url.deletingLastPathComponent().appendingPathComponent("corrections.json"))
        log.append(result.records)
        XCTAssertEqual(log.records.map(\.replaced), ["Khipu"])
    }
}

@MainActor
final class HUDCorrectionCountTests: XCTestCase {
    private func content(_ hud: RecordingHUD) throws -> NSView {
        try XCTUnwrap(Mirror(reflecting: hud).children.first(where: { $0.label == "waveformView" })?.value as? NSView)
    }

    private func count(_ view: NSView) throws -> Int {
        try XCTUnwrap(Mirror(reflecting: view).children.first(where: { $0.label == "correctionCount" })?.value as? Int)
    }

    private func label(_ view: NSView) throws -> NSTextField {
        try XCTUnwrap(Mirror(reflecting: view).children.first(where: { $0.label == "correctionLabel" })?.value as? NSTextField)
    }

    func testCorrectionLabelBelongsToOneSuccessFlash() throws {
        let hud = RecordingHUD(presentsWindows: false)
        defer { hud.hide() }
        let view = try content(hud)
        let label = try label(view)
        hud.show()
        hud.showSuccessThenHide(correctionCount: 3)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(try count(view), 3)
        XCTAssertFalse(label.isHidden)
        XCTAssertEqual(label.stringValue, "3 corrected")
        hud.show()
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(try count(view), 0)
        XCTAssertTrue(label.isHidden)
        hud.setProcessing()
        XCTAssertEqual(try count(view), 0)
        XCTAssertTrue(label.isHidden)
        hud.showSuccessThenHide(correctionCount: 0)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(try count(view), 0)
        XCTAssertTrue(label.isHidden)
    }

    func testEveryNonSuccessStateClearsCorrections() throws {
        let hud = RecordingHUD(presentsWindows: false)
        defer { hud.hide() }
        let view = try content(hud)
        let label = try label(view)
        let transitions: [(RecordingHUD) -> Void] = [
            { $0.setProcessing() }, { $0.showError("Synthetic failure") },
            { $0.showClipboardFlashThenHide() }, { $0.showMicrophoneNoAudio("Synthetic mic") },
            { $0.prepareForRecording(editingSelection: true); $0.show() }
        ]
        for transition in transitions {
            hud.show()
            hud.showSuccessThenHide(correctionCount: 3)
            transition(hud)
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(try count(view), 0)
            XCTAssertTrue(label.isHidden)
        }
    }

    func testShowClearsUnconsumedPendingCorrections() throws {
        let hud = RecordingHUD(presentsWindows: false)
        defer { hud.hide() }
        hud.show()
        hud.setPendingCorrectionCount(3)
        hud.show()
        hud.showSuccessThenHide(correctionCount: 0)
        let view = try content(hud)
        XCTAssertEqual(try count(view), 0)
        XCTAssertTrue(try label(view).isHidden)
    }
}
