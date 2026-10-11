import XCTest
import UIKit

@MainActor
final class KeyboardEditingRegressionTests: XCTestCase {
    func testCorrectionUndoAtIdenticalDictatedSuffixDoesNotDelete() throws {
        for clumpsBulkInserts in [false, true] {
            let keyboard = TestKeyboard()
            keyboard.proxy.clumpsBulkInserts = clumpsBulkInserts
            keyboard.insertDictationText("keep the ")
            keyboard.type("teh ")
            XCTAssertEqual(keyboard.proxy.text, "keep the the ")
            XCTAssertEqual(keyboard.textAfterBulkInsert, "the ")
            let undo = try XCTUnwrap(keyboard.autocorrect.displayed.firstIndex(of: "teh"))
            let deletes = keyboard.proxy.deleteCalls

            keyboard.proxy.caret = "keep the ".count
            keyboard.hostTextDidChange()
            XCTAssertEqual(keyboard.autocorrect.displayed.firstIndex(of: "teh"), undo)
            keyboard.applyCandidate(at: undo)

            XCTAssertEqual(keyboard.proxy.deleteCalls, deletes)
            XCTAssertEqual(keyboard.proxy.text, "keep the the ")
            XCTAssertEqual(keyboard.textAfterBulkInsert, "")
        }
    }

    func testBackspaceAtIdenticalDictatedSuffixCannotAuthorizeAutomaticCorrection() {
        let keyboard = TestKeyboard()
        keyboard.insertDictationText("keep tehx ")
        keyboard.type("tehx")
        let deletes = keyboard.proxy.deleteCalls

        keyboard.proxy.caret = "keep tehx".count
        keyboard.hostTextDidChange()
        keyboard.deleteFromKeyboard()
        keyboard.type(" ")

        XCTAssertEqual(keyboard.proxy.deleteCalls, deletes + 1)
        XCTAssertEqual(keyboard.proxy.text, "keep teh  tehx")
        XCTAssertEqual(keyboard.textAfterBulkInsert, " ")
    }

    func testReturningCaretToIdenticalContextDoesNotRestoreOwnership() throws {
        let keyboard = TestKeyboard()
        keyboard.insertDictationText("keep the ")
        keyboard.type("teh ")
        let undo = try XCTUnwrap(keyboard.autocorrect.displayed.firstIndex(of: "teh"))
        let deletes = keyboard.proxy.deleteCalls

        keyboard.proxy.caret = "keep the ".count
        keyboard.hostSelectionDidChange()
        keyboard.proxy.caret = keyboard.proxy.text.count
        keyboard.hostSelectionDidChange()
        XCTAssertEqual(keyboard.autocorrect.displayed.firstIndex(of: "teh"), undo)
        keyboard.applyCandidate(at: undo)

        XCTAssertEqual(keyboard.proxy.deleteCalls, deletes)
        XCTAssertEqual(keyboard.proxy.text, "keep the the ")
        XCTAssertEqual(keyboard.textAfterBulkInsert, "")
    }

    func testClearingSelectionDoesNotRestoreTypedSuffixOwnership() throws {
        let keyboard = TestKeyboard()
        keyboard.insertDictationText("keep the ")
        keyboard.type("teh ")
        let undo = try XCTUnwrap(keyboard.autocorrect.displayed.firstIndex(of: "teh"))
        let deletes = keyboard.proxy.deleteCalls

        keyboard.proxy.selection = 9..<12
        keyboard.hostSelectionDidChange()
        keyboard.proxy.selection = nil
        keyboard.hostSelectionDidChange()
        XCTAssertEqual(keyboard.autocorrect.displayed.firstIndex(of: "teh"), undo)
        keyboard.applyCandidate(at: undo)

        XCTAssertEqual(keyboard.proxy.deleteCalls, deletes)
        XCTAssertEqual(keyboard.proxy.text, "keep the the ")
        XCTAssertEqual(keyboard.textAfterBulkInsert, "")
    }

    func testBackspaceAtMovedCaretCannotAuthorizeCorrectionInsideDictation() {
        let keyboard = TestKeyboard()
        keyboard.insertDictationText("tehy ")
        keyboard.type("tehx")
        XCTAssertEqual(keyboard.textAfterBulkInsert, "tehx")
        keyboard.proxy.caret = 4

        keyboard.deleteFromKeyboard()

        XCTAssertEqual(keyboard.proxy.text, "teh tehx")
        XCTAssertEqual(keyboard.proxy.deleteCalls, 1)
        XCTAssertEqual(keyboard.textAfterBulkInsert, "")
        keyboard.type(" ")
        XCTAssertEqual(keyboard.proxy.text, "teh  tehx")
        XCTAssertEqual(keyboard.proxy.deleteCalls, 1)
    }

    func testOrdinaryAutocorrectionCanBeUndoneOnClumpingHost() throws {
        let keyboard = TestKeyboard()
        keyboard.proxy.clumpsBulkInserts = true
        keyboard.type("teh ")
        XCTAssertEqual(keyboard.proxy.text, "the ")

        try keyboard.choose("teh")

        XCTAssertEqual(keyboard.proxy.text, "teh ")
        XCTAssertEqual(keyboard.proxy.deleteCalls, 7)
        XCTAssertNil(keyboard.recentBulkInsertText())
    }

    func testBackspaceWithinTypedSuffixPreservesItsCorrectionPermission() {
        let keyboard = TestKeyboard()
        keyboard.insertDictationText("Dictated text ")
        keyboard.type("tehx")

        keyboard.deleteFromKeyboard()

        XCTAssertEqual(keyboard.proxy.text, "Dictated text teh")
        XCTAssertEqual(keyboard.proxy.deleteCalls, 1)
        XCTAssertEqual(keyboard.textAfterBulkInsert, "teh")
        keyboard.type(" ")
        XCTAssertEqual(keyboard.proxy.text, "Dictated text the ")
        XCTAssertEqual(keyboard.proxy.deleteCalls, 4)
    }

    func testSuccessiveSwipeAlternativesRemainReplaceableOnClumpingHost() throws {
        let keyboard = TestKeyboard()
        keyboard.proxy.clumpsBulkInserts = true
        keyboard.insertSwipe(["cat", "car"])
        try keyboard.choose("car")
        XCTAssertEqual(keyboard.proxy.text, "car ")

        try keyboard.choose("car.")

        XCTAssertEqual(keyboard.proxy.text, "car. ")
        XCTAssertEqual(keyboard.proxy.deleteCalls, 8)
        XCTAssertNil(keyboard.recentBulkInsertText())
    }

    func test01LiteralCandidateAfterDictationDoesNotPartiallyDeleteApostropheWord() throws {
        let keyboard = TestKeyboard()
        keyboard.insertDictationText("Dictated text ")
        keyboard.type("'hi")
        let before = keyboard.proxy.text
        try keyboard.choose("'hi")
        XCTAssertEqual(keyboard.proxy.text, before)
    }

    func test02BackspaceDeletesEarlierSelectionAfterDictation() {
        let keyboard = TestKeyboard(text: "Earlier words. ")
        keyboard.insertDictationText("Dictated text ")
        keyboard.proxy.selection = 0..<7
        keyboard.deleteFromKeyboard()
        XCTAssertEqual(keyboard.proxy.text, " words. Dictated text ")
        XCTAssertEqual(keyboard.proxy.deleteCalls, 1)
    }

    func test02BackspaceDeletesFreshDictationAndItsSelection() {
        for selected in [false, true] {
            let keyboard = TestKeyboard()
            keyboard.insertDictationText("Dictated text ")
            if selected { keyboard.proxy.selection = 0..<14 }
            keyboard.deleteFromKeyboard()
            XCTAssertEqual(keyboard.proxy.text, selected ? "" : "Dictated text")
            XCTAssertEqual(keyboard.proxy.deleteCalls, 1)
        }
    }

    func test02BackspaceWorksAfterMovingCaretIntoEarlierText() {
        let keyboard = TestKeyboard(text: "Earlier text. ")
        keyboard.insertDictationText("Dictated text ")
        keyboard.proxy.caret = 7
        keyboard.deleteFromKeyboard()
        XCTAssertEqual(keyboard.proxy.text, "Earlie text. Dictated text ")
        XCTAssertEqual(keyboard.proxy.deleteCalls, 1)
    }

    func test03SwipeAlternativeReplacesCommittedWord() throws {
        let keyboard = TestKeyboard()
        keyboard.proxy.clumpsBulkInserts = true
        keyboard.insertSwipe(["cat", "car"])
        try keyboard.choose("car")
        XCTAssertEqual(keyboard.proxy.text, "car ")
    }

    func test03SwipePeriodAlternativeAttachesPeriod() throws {
        let keyboard = TestKeyboard()
        keyboard.proxy.clumpsBulkInserts = true
        keyboard.insertSwipe(["cat", "car"])
        try keyboard.choose("cat.")
        XCTAssertEqual(keyboard.proxy.text, "cat. ")
    }

    func test04GIFInsertionDoesNotBecomeTypedSuffix() {
        let keyboard = TestKeyboard()
        keyboard.insertDictationText("Dictated text ")
        keyboard.proxy.clumpsBulkInserts = true
        let url = URL(string: "https://example.invalid/cat.gif")!
        keyboard.insertGIFURL(url)
        XCTAssertEqual(keyboard.textAfterBulkInsert, "")
        let before = keyboard.proxy.text
        XCTAssertFalse(keyboard.deleteCharacters(url.absoluteString.count + 1))
        XCTAssertEqual(keyboard.proxy.deleteCalls, 0)
        XCTAssertEqual(keyboard.proxy.text, before)
    }

    func test04CorrectionUndoOnlyReplacesTypedSuffixAfterDictation() throws {
        let keyboard = TestKeyboard()
        keyboard.insertDictationText("Dictated text ")
        keyboard.proxy.clumpsBulkInserts = true
        keyboard.type("teh ")
        XCTAssertEqual(keyboard.proxy.text, "Dictated text the ")
        let deletes = keyboard.proxy.deleteCalls
        try keyboard.choose("teh")
        XCTAssertEqual(keyboard.proxy.deleteCalls, deletes + 4)
        XCTAssertEqual(keyboard.proxy.text, "Dictated text teh ")
        XCTAssertEqual(keyboard.recentBulkInsertText(), "Dictated text ")
        XCTAssertEqual(keyboard.textAfterBulkInsert, "teh ")
        XCTAssertFalse(keyboard.deleteCharacters(5))
        XCTAssertEqual(keyboard.proxy.deleteCalls, deletes + 4)
        XCTAssertEqual(keyboard.proxy.text, "Dictated text teh ")
    }

    func test04ExplicitBackspaceStillReachesClumpingGIFHost() {
        let keyboard = TestKeyboard()
        keyboard.insertDictationText("Dictated text ")
        keyboard.proxy.clumpsBulkInserts = true
        keyboard.insertGIFURL(URL(string: "https://example.invalid/cat.gif")!)
        keyboard.deleteFromKeyboard()
        XCTAssertEqual(keyboard.proxy.deleteCalls, 1)
        XCTAssertEqual(keyboard.proxy.text, "Dictated text ")
    }

    func test05PeriodSuggestionRemovesOrdinaryTrailingSpace() throws {
        let keyboard = TestKeyboard()
        keyboard.type("hello ")
        try keyboard.choose(".")
        XCTAssertEqual(keyboard.proxy.text, "hello. ")
    }

    func test06EllipsisPreservesTrailingWordAutocorrection() {
        let keyboard = TestKeyboard()
        keyboard.type("Well...teh ")
        XCTAssertEqual(keyboard.proxy.text, "Well...the ")
    }
}

@MainActor
private final class TestKeyboard: KeyboardEditing {
    let proxy: EditingProxy
    var textDocumentProxy: UITextDocumentProxy { proxy }
    var phase: KeyboardEditingPhase { .idle }
    var allowsAutocorrection: Bool { true }
    let autocorrect = AutocorrectController(isLearnedWord: { _ in false })
    var lastSpaceTap: ContinuousClock.Instant?
    var lastBulkInsert: (text: String, at: ContinuousClock.Instant)?
    var textAfterBulkInsert = ""
    var insertOrigin: KeyboardInsertOrigin?

    init(text: String = "") { proxy = EditingProxy(text: text) }
    func type(_ text: String) {
        for character in text { insertFromKeyboard(String(character)) }
    }
    func choose(_ text: String) throws {
        let index = try XCTUnwrap(autocorrect.displayed.firstIndex(of: text))
        applyCandidate(at: index)
    }
    func hostTextDidChange() {
        invalidateTypedSuffixOwnership()
        refreshSuggestions()
    }
    func hostSelectionDidChange() {
        invalidateTypedSuffixOwnership()
        refreshSuggestions()
    }
    func handleGifTyping(_ text: String) -> Bool { false }
    func handleEmojiTyping(_ text: String) -> Bool { false }
    func handleGifDelete() -> Bool { false }
    func handleEmojiDelete() -> Bool { false }
    func playInputClick() {}
    func updateCapitalization() {}
    func showCandidates() {}
    func teachKeyboardWord(_ raw: String) {}
    func recordEditDiagnostic(_ event: String, detail: String) {}
    func refreshSuggestions() {
        let context = proxy.documentContextBeforeInput ?? ""
        let active = AutocorrectEngine.wordSpan(beforeInput: context)
        let committed = AutocorrectEngine.committedSpan(beforeInput: context)
        if let corrected = autocorrect.lastCorrected,
           active == corrected || (active.isEmpty && committed.word == corrected) { return }
        autocorrect.clearUndo()
        _ = autocorrect.suggestions(for: active, beforeInput: context)
    }
}

@MainActor
private final class EditingProxy: NSObject, UITextDocumentProxy {
    var text: String
    var caret: Int
    var selection: Range<Int>?
    var deleteCalls = 0
    var clumpsBulkInserts = false
    private var pendingBulk: Range<Int>?
    let documentIdentifier = UUID()
    var documentInputMode: UITextInputMode? { nil }
    var hasText: Bool { !text.isEmpty }
    var autocorrectionType: UITextAutocorrectionType = .yes
    var keyboardType: UIKeyboardType = .default
    var isSecureTextEntry = false
    var documentContextBeforeInput: String? { String(text.prefix(selection?.lowerBound ?? caret)) }
    var documentContextAfterInput: String? { String(text.dropFirst(selection?.upperBound ?? caret)) }
    var selectedText: String? {
        guard let selection else { return nil }
        return String(text.dropFirst(selection.lowerBound).prefix(selection.count))
    }
    init(text: String) { self.text = text; caret = text.count }
    func insertText(_ value: String) {
        let range = selection ?? caret..<caret
        replace(range, with: value)
        if clumpsBulkInserts && value.count > 1 {
            pendingBulk = range.lowerBound..<caret
        }
    }
    func deleteBackward() {
        deleteCalls += 1
        if let selection {
            replace(selection, with: "")
        } else if let pendingBulk, caret == pendingBulk.upperBound {
            replace(pendingBulk, with: "")
            self.pendingBulk = nil
        } else if caret > 0 {
            replace((caret - 1)..<caret, with: "")
        }
    }
    func adjustTextPosition(byCharacterOffset offset: Int) {
        caret = min(text.count, max(0, caret + offset))
        selection = nil
    }
    func setMarkedText(_ markedText: String, selectedRange: NSRange) {}
    func unmarkText() {}
    private func replace(_ range: Range<Int>, with value: String) {
        text = String(text.prefix(range.lowerBound)) + value + String(text.dropFirst(range.upperBound))
        caret = range.lowerBound + value.count
        selection = nil
    }
}
