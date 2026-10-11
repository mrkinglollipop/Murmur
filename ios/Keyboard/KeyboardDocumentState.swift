import UIKit

/// Only swipe words own a deletable committed span. Dictation never does.
enum KeyboardInsertOrigin: Equatable {
    case dictation
    case swipe(String)

    var swipeWord: String? {
        if case .swipe(let word) = self { return word }
        return nil
    }

    func trailingDeleteCount(beforeInserting text: String, context: String) -> Int {
        // Punctuation and whitespace never delete beside a bulk swipe insert.
        return 0
    }

    func backspaceCount(context: String) -> Int {
        guard let word = swipeWord else { return context.isEmpty ? 0 : 1 }
        return AutocorrectEngine.allowedDeleteCount(span: word, inBeforeInput: context)
    }
}

struct KeyboardDocumentFingerprint: Equatable {
    let documentIdentifier: UUID

    func allowsInsertion(into current: Self, isCancelled: Bool) -> Bool {
        !isCancelled && self == current
    }
}

struct KeyboardDictationRequest {
    let id: String
    let document: KeyboardDocumentFingerprint

    func accepts(id: String, document: KeyboardDocumentFingerprint) -> Bool {
        self.id == id && self.document == document
    }
}

enum KeyboardAutocorrectionPolicy {
    static func allowsReplacement(
        autocorrectionType: UITextAutocorrectionType?,
        keyboardType: UIKeyboardType?,
        isSecure: Bool
    ) -> Bool {
        guard !isSecure, autocorrectionType != .no else { return false }
        switch keyboardType ?? .default {
        case .URL, .emailAddress, .numberPad, .phonePad, .namePhonePad,
             .decimalPad, .numbersAndPunctuation, .asciiCapableNumberPad:
            return false
        default:
            return true
        }
    }
}

enum KeyboardBulkEditPolicy {
    static func allowsDeletion(
        count: Int, beforeInput: String, selected: String?,
        recentBulkInsert: String?, textAfterBulkInsert: String
    ) -> Bool {
        guard count > 0, !beforeInput.isEmpty,
              selected == nil || selected == "" else { return false }
        guard recentBulkInsert != nil else { return true }
        // A nil/empty selection is not proof that the host has released its
        // provisional bulk region. Only a matching, locally typed suffix is safe.
        // Spaces and punctuation alone do not establish a new typed token.
        return textAfterBulkInsert.contains { !$0.isWhitespace && !$0.isPunctuation }
            && count <= textAfterBulkInsert.count
            && beforeInput.hasSuffix(textAfterBulkInsert)
    }

    static func candidateSpan(
        beforeInput: String, recentBulkInsert: String?, textAfterBulkInsert: String
    ) -> (word: String, trailing: String)? {
        let active = AutocorrectEngine.wordSpan(beforeInput: beforeInput)
        let span = active.isEmpty
            ? AutocorrectEngine.committedSpan(beforeInput: beforeInput)
            : (word: active, trailing: "")
        let wordContext = String(beforeInput.dropLast(span.trailing.count))
        guard !span.word.isEmpty,
              AutocorrectEngine.autocorrectionSpan(beforeInput: wordContext) == span.word,
              allowsDeletion(
                count: span.word.count + span.trailing.count, beforeInput: beforeInput,
                selected: nil, recentBulkInsert: recentBulkInsert,
                textAfterBulkInsert: textAfterBulkInsert
              ) else { return nil }
        return span
    }

    static func punctuationDeleteCount(trailing: String, recentBulkInsert: String?) -> Int {
        recentBulkInsert == nil ? trailing.count : 0
    }
}

enum KeyboardEditingPhase {
    case idle, waiting, secure, setup
}

/// The controller and isolated document tests execute these same edit handlers.
/// UI feedback, diagnostics and learned-word persistence stay with the caller.
@MainActor
protocol KeyboardEditing: AnyObject {
    var textDocumentProxy: UITextDocumentProxy { get }
    var phase: KeyboardEditingPhase { get }
    var allowsAutocorrection: Bool { get }
    var autocorrect: AutocorrectController { get }
    var lastSpaceTap: ContinuousClock.Instant? { get set }
    var lastBulkInsert: (text: String, at: ContinuousClock.Instant)? { get set }
    var textAfterBulkInsert: String { get set }
    var insertOrigin: KeyboardInsertOrigin? { get set }
    func handleGifTyping(_ text: String) -> Bool
    func handleEmojiTyping(_ text: String) -> Bool
    func handleGifDelete() -> Bool
    func handleEmojiDelete() -> Bool
    func playInputClick()
    func updateCapitalization()
    func refreshSuggestions()
    func showCandidates()
    func teachKeyboardWord(_ raw: String)
    func recordEditDiagnostic(_ event: String, detail: String)
}

extension KeyboardEditing {
    /// Host text/selection notifications invalidate position-based ownership.
    /// Identical text at a different caret is not the keyboard's typed suffix.
    /// Keep the bulk-insert window armed; unknown ownership must deny deletion.
    func invalidateTypedSuffixOwnership() {
        textAfterBulkInsert = ""
    }

    func insertFromKeyboard(_ text: String) {
        if handleGifTyping(text) {
            playInputClick()
            return
        }
        if handleEmojiTyping(text) {
            playInputClick()
            return
        }
        // No insert may replace a 1-char selection. Space/return got this
        // guard first (double-tap "ate the last letter"); letters were left
        // able to overwrite, so the same phantom host selection could still
        // silently eat one character per keystroke. Collapse instead.
        guard canMutateDocument(allowSingleCharacterSelection: false) else { return }
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        let trailingDelete = insertOrigin?.trailingDeleteCount(beforeInserting: text, context: context) ?? 0
        if trailingDelete > 0, selectedTextIsEmpty {
            deleteCharacters(trailingDelete)
        }
        swipeCommittedWord = nil
        playInputClick()
        if !text.unicodeScalars.allSatisfy(\.isASCII) {
            insertPlain(text)
            lastSpaceTap = nil
            updateCapitalization()
            refreshSuggestions()
            return
        }
        if text == " ", shouldReplaceSecondSpaceWithPeriod() {
            let after = textDocumentProxy.documentContextBeforeInput ?? ""
            if let walk = AutocorrectEngine.doubleSpacePeriodWalk(beforeInput: after) {
                // NEVER delete here. Step the caret back over the trailing
                // space(s), drop the period in, step forward, and consume the
                // tap. A deleteBackward on this path erased whole dictated
                // sentences twice (2026-08-25) — hosts can treat a fresh bulk
                // insert as one deletable clump and lie about it afterward.
                // Re-check the selection at insert time: delete presses can
                // re-arm the host's phantom highlight after the entry guard
                // ran (2026-08-26 repro: period → backspace → double-space
                // wiped the sentence).
                guard canMutateDocument(allowSingleCharacterSelection: false) else { return }
                textDocumentProxy.adjustTextPosition(byCharacterOffset: -walk)
                textDocumentProxy.insertText(".")
                textDocumentProxy.adjustTextPosition(byCharacterOffset: walk)
                recordEditDiagnostic("keyboard.doubleSpace.period", detail: "walk=\(walk)")
                lastSpaceTap = nil
                updateCapitalization()
                refreshSuggestions()
                return
            }
        }
        autocorrect.noteIncomingText(text)
        applyAutocorrectIfNeeded(beforeInserting: text, context: context)
        if AutocorrectEngine.isCommitText(text) {
            let span = AutocorrectEngine.wordSpan(beforeInput: context)
            if autocorrect.undoOriginal?.lowercased() != span.lowercased() {
                teachKeyboardWord(span)
            }
        }
        let didInsert = insertPlain(text)
        lastSpaceTap = didInsert && text == " " && supportsDoubleSpacePeriod
            ? ContinuousClock().now
            : nil
        if autocorrect.suppressUntilWhitespace, AutocorrectEngine.isCommitText(text) {
            autocorrect.suppressUntilWhitespace = false
        }
        updateCapitalization()
        refreshSuggestions()
    }

    func deleteFromKeyboard() {
        if handleGifDelete() {
            playInputClick()
            return
        }
        if handleEmojiDelete() {
            playInputClick()
            return
        }
        if let selected = textDocumentProxy.selectedText, !selected.isEmpty {
            playInputClick()
            lastSpaceTap = nil
            swipeCommittedWord = nil
            textAfterBulkInsert = ""
            // The explicit Backspace action authorizes the whole selection.
            textDocumentProxy.deleteBackward()
            autocorrect.clearUndo()
            updateCapitalization()
            refreshSuggestions()
            return
        }
        if let word = swipeCommittedWord, !word.isEmpty {
            let context = textDocumentProxy.documentContextBeforeInput ?? ""
            let allowed = insertOrigin?.backspaceCount(context: context) ?? 0
            if allowed > 0 {
                playInputClick()
                recordEditDiagnostic("keyboard.delete.swipeWord", detail: "count=\(allowed)")
                deleteCharacters(allowed, userInitiated: true)
                swipeCommittedWord = nil
                lastSpaceTap = nil
                autocorrect.clearUndo()
                autocorrect.suppressUntilWhitespace = false
                updateCapitalization()
                refreshSuggestions()
                return
            }
            swipeCommittedWord = nil
        }
        playInputClick()
        lastSpaceTap = nil
        deleteBackwardCheckingHostDrop()
        autocorrect.clearUndo()
        updateCapitalization()
        refreshSuggestions()
    }

    func insertSwipe(_ candidates: [String]) {
        guard phase != .waiting else { return }
        guard let first = candidates.first, !first.isEmpty else { return }
        if handleGifTyping(first) {
            playInputClick()
            return
        }
        playInputClick()
        guard canMutateDocument(allowSingleCharacterSelection: false) else { return }
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        let span = AutocorrectEngine.wordSpan(beforeInput: context)
        if !span.isEmpty {
            let allowed = AutocorrectEngine.allowedDeleteCount(span: span, inBeforeInput: context)
            guard allowed > 0, selectedTextIsEmpty else { return }
            guard deleteCharacters(allowed) else {
                recordEditDiagnostic("keyboard.swipe.abortedSpanEat", detail: "wanted=\(allowed)")
                return
            }
        }
        let afterSpan = textDocumentProxy.documentContextBeforeInput ?? ""
        if AutocorrectEngine.needsLeadingSpace(beforeInput: afterSpan) {
            insertPlain(" ")
        }
        let trailing = phase == .secure ? "" : " "
        // Alternatives must remain replaceable without deleting a fresh bulk
        // region. Commit swipe characters separately, like individual keys.
        for character in first + trailing {
            guard insertPlain(String(character)) else { return }
        }
        swipeCommittedWord = first + trailing
        lastSpaceTap = trailing == " " && supportsDoubleSpacePeriod ? ContinuousClock().now : nil
        autocorrect.suppressUntilWhitespace = true
        if phase != .secure {
            autocorrect.noteSwipe(committed: first, alternatives: candidates)
            showCandidates()
        }
        updateCapitalization()
    }

    func applyAutocorrectIfNeeded(beforeInserting text: String, context: String) {
        guard phase != .secure, phase != .waiting, allowsAutocorrection else { return }
        guard AutocorrectEngine.isCommitText(text) else { return }
        // Suppress is for the swipe/dictation token on its own trailing space,
        // not the next typed word. `noteIncomingText` already cleared it if
        // this commit follows a new letter span (`i` + space after a swipe).
        guard !autocorrect.suppressUntilWhitespace else { return }
        let span = AutocorrectEngine.autocorrectionSpan(beforeInput: context)
        let allowed = AutocorrectEngine.allowedDeleteCount(span: span, inBeforeInput: context)
        guard allowed > 0 else { return }
        guard selectedTextIsEmpty else { return }
        guard let correction = autocorrect.correction(for: span), correction != span else { return }
        let replacement = AutocorrectEngine.replacement(span: span, correction: correction)
        guard replacement.deleteCount == allowed else { return }
        guard deleteCharacters(allowed) else {
            recordEditDiagnostic("keyboard.autocorrect.abortedDelete", detail: "wanted=\(allowed)")
            return
        }
        for character in replacement.insert {
            guard insertPlain(String(character)) else { return }
        }
        autocorrect.noteAutocorrect(original: span, corrected: replacement.insert)
    }

    func applyCandidate(at index: Int) {
        guard phase != .secure, phase != .waiting, allowsAutocorrection else { return }
        let choices = autocorrect.displayed
        guard index >= 0, index < choices.count else { return }
        let chosen = choices[index]
        guard canMutateDocument(allowSingleCharacterSelection: false) else { return }
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        if AutocorrectEngine.isPunctuationSuggestion(chosen) {
            let committed = AutocorrectEngine.committedSpan(beforeInput: context)
            let deleteCount = KeyboardBulkEditPolicy.punctuationDeleteCount(
                trailing: committed.trailing, recentBulkInsert: recentBulkInsertText()
            )
            guard deleteCharacters(deleteCount) else {
                recordEditDiagnostic("keyboard.candidate.abortedDelete", detail: "trailing=\(committed.trailing.count)")
                return
            }
            insertPlain(chosen + " ")
            swipeCommittedWord = nil
            lastSpaceTap = supportsDoubleSpacePeriod ? ContinuousClock().now : nil
            autocorrect.clearUndo()
            autocorrect.suppressUntilWhitespace = false
            updateCapitalization()
            refreshSuggestions()
            return
        }
        guard let span = KeyboardBulkEditPolicy.candidateSpan(
            beforeInput: context, recentBulkInsert: recentBulkInsertText(),
            textAfterBulkInsert: textAfterBulkInsert
        ) else { return }
        let target = span.word
        let trailing = span.trailing
        guard !target.isEmpty else { return }
        let removable = target + trailing
        let allowed = AutocorrectEngine.allowedDeleteCount(span: removable, inBeforeInput: context)
        guard allowed > 0, selectedTextIsEmpty else { return }
        guard deleteCharacters(allowed) else {
            recordEditDiagnostic("keyboard.candidate.abortedDelete", detail: "wanted=\(allowed)")
            return
        }
        let inserted: String
        if AutocorrectEngine.periodAttachedWord(chosen) != nil {
            inserted = chosen + (trailing.isEmpty && phase != .secure ? " " : trailing)
        } else if swipeCommittedWord != nil, trailing.isEmpty, phase != .secure {
            inserted = chosen + " "
        } else {
            inserted = chosen + trailing
        }
        for character in inserted {
            guard insertPlain(String(character)) else { return }
        }
        if swipeCommittedWord != nil {
            swipeCommittedWord = inserted
            var remaining = choices.filter { $0.lowercased() != chosen.lowercased() }
            remaining.insert(chosen, at: 0)
            autocorrect.noteSwipe(committed: AutocorrectEngine.periodAttachedWord(chosen) ?? chosen, alternatives: remaining)
            lastSpaceTap = inserted.hasSuffix(" ") && supportsDoubleSpacePeriod ? ContinuousClock().now : nil
            updateCapitalization()
            showCandidates()
            teachKeyboardWord(AutocorrectEngine.periodAttachedWord(chosen) ?? chosen)
            return
        }
        if let original = autocorrect.undoOriginal, chosen.lowercased() == original.lowercased() {
            teachKeyboardWord(original)
        } else if chosen.lowercased() == target.lowercased() {
            teachKeyboardWord(chosen)
        }
        autocorrect.clearUndo()
        updateCapitalization()
        refreshSuggestions()
    }

    func shouldReplaceSecondSpaceWithPeriod() -> Bool {
        // SIMPLIFIED 2026-08-26: no double-space magic near a bulk insert.
        // Messages discards its provisional region when anything touches it;
        // near a bulk insert a space is just a space. Failure mode: no period
        // appears — never a wipe, never a paste. "Near" = the 180-second
        // recentBulkInsertText window; generous on purpose, since the cost
        // of suppression is only a missing period.
        guard recentBulkInsertText() == nil else { return false }
        guard supportsDoubleSpacePeriod,
              let lastSpaceTap,
              ContinuousClock().now - lastSpaceTap < .milliseconds(700) else { return false }
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        // Walk-based: also matches "sentence  " (dictation's auto trailing
        // space + the first tap), which the single-space check never could.
        return AutocorrectEngine.doubleSpacePeriodWalk(beforeInput: context) != nil
    }

    /// `deleteBackward` / `insertText` replace the *selection*, not one character.
    /// A selected clause plus a keystroke wipes the sentence.
    var selectedTextIsEmpty: Bool {
        guard let selected = textDocumentProxy.selectedText else { return true }
        return selected.isEmpty
    }

    /// Collapse a 1-char selection by moving one unit, never by `insertText`.
    /// Do not jump by `selected.length` — a stale clause-sized `selectedText`
    /// would move or extend the real range, and the next `deleteBackward`
    /// wipes the sentence.
    func canMutateDocument(allowSingleCharacterSelection: Bool = true) -> Bool {
        switch AutocorrectEngine.documentMutationDecision(
            selected: textDocumentProxy.selectedText,
            allowSingleCharacterSelection: allowSingleCharacterSelection
        ) {
        case .allow:
            return true
        case .deny:
            recordEditDiagnostic(
                "keyboard.mutate.denied",
                detail: "selectedLen=\(textDocumentProxy.selectedText?.count ?? 0)"
            )
            return false
        case .collapseOneCharacterSelection:
            textDocumentProxy.adjustTextPosition(byCharacterOffset: 1)
            if let still = textDocumentProxy.selectedText, !still.isEmpty {
                recordEditDiagnostic("keyboard.mutate.collapseFailed", detail: "selectedLen=\(still.count)")
                return false
            }
            recordEditDiagnostic("keyboard.mutate.collapsed", detail: "")
            return true
        }
    }

    @discardableResult
    func insertPlain(_ text: String) -> Bool {
        // Never overwrite a 1-char selection — collapse it. A phantom host
        // selection plus insertText is a silently eaten character.
        guard canMutateDocument(allowSingleCharacterSelection: false) else { return false }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        textDocumentProxy.insertText(text)
        if text.count > 1 {
            lastBulkInsert = (text: text, at: ContinuousClock().now)
            textAfterBulkInsert = ""
        } else if recentBulkInsertText() != nil {
            if !before.hasSuffix(textAfterBulkInsert) { textAfterBulkInsert = "" }
            textAfterBulkInsert += text
        }
        return true
    }

    /// True when exactly `requested` characters were removed with no host
    /// anomaly. False → the document is NOT in the expected state; callers
    /// must skip any replacement insert (deleting fewer characters and then
    /// inserting a correction garbles the word).
    @discardableResult
    func deleteCharacters(_ requested: Int, userInitiated: Bool = false) -> Bool {
        guard requested != 0 else { return true }
        let count = min(max(0, requested), AutocorrectEngine.maxDeleteLoop)
        guard count > 0 else { return false }
        guard canMutateDocument(allowSingleCharacterSelection: false) else { return false }
        let initial = textDocumentProxy.documentContextBeforeInput ?? ""
        guard userInitiated || KeyboardBulkEditPolicy.allowsDeletion(
            count: count, beforeInput: initial, selected: textDocumentProxy.selectedText,
            recentBulkInsert: recentBulkInsertText(), textAfterBulkInsert: textAfterBulkInsert
        ) else { return false }
        for remaining in (1...count).reversed() {
            let before = textDocumentProxy.documentContextBeforeInput ?? ""
            guard selectedTextIsEmpty else { return false }
            // Eligibility belongs to the original token. Its shrinking suffix
            // may be punctuation-only; it still owns the approved characters.
            if !userInitiated, recentBulkInsertText() != nil {
                guard remaining <= textAfterBulkInsert.count,
                      before.hasSuffix(textAfterBulkInsert) else { return false }
            }
            textDocumentProxy.deleteBackward()
            let after = textDocumentProxy.documentContextBeforeInput ?? ""
            if AutocorrectEngine.shouldAbortDeleteLoop(beforeCount: before.count, afterCount: after.count)
                || (recentBulkInsertText() != nil && before.count - after.count != 1) {
                textAfterBulkInsert = ""
                restoreHiddenSelectionLoss(before: before, after: after)
                return false
            }
            if !textAfterBulkInsert.isEmpty { textAfterBulkInsert.removeLast() }
        }
        return true
    }

    func recentBulkInsertText() -> String? {
        guard let last = lastBulkInsert,
              ContinuousClock().now - last.at < .seconds(180) else { return nil }
        return last.text
    }

    /// A delete removed more than expected (host word-delete or hidden
    /// selection). SIMPLIFIED 2026-08-26: log only — every automatic
    /// reinsertion built during the sentence-wipe saga misfired somewhere;
    /// cleverness here must fail to "nothing happens".
    func restoreHiddenSelectionLoss(before: String, after: String) {
        recordEditDiagnostic(
            "keyboard.delete.hostDrop",
            detail: "before=\(before.count) after=\(after.count)"
        )
    }

    /// An explicit Backspace always reaches the host, even with unavailable
    /// context. Diagnostics never block or undo a user-authorized deletion.
    func deleteBackwardCheckingHostDrop() {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        // A moved caret must not turn an unrelated typed suffix into permission
        // to automatically edit the fresh bulk region after this Backspace.
        if !before.hasSuffix(textAfterBulkInsert) { textAfterBulkInsert = "" }
        textDocumentProxy.deleteBackward()
        let after = textDocumentProxy.documentContextBeforeInput ?? ""
        if AutocorrectEngine.shouldAbortDeleteLoop(beforeCount: before.count, afterCount: after.count)
            || (recentBulkInsertText() != nil && before.count - after.count != 1) {
            textAfterBulkInsert = ""
            restoreHiddenSelectionLoss(before: before, after: after)
            return
        }
        if !textAfterBulkInsert.isEmpty { textAfterBulkInsert.removeLast() }
    }

    var supportsDoubleSpacePeriod: Bool {
        guard textDocumentProxy.isSecureTextEntry != true else { return false }
        switch textDocumentProxy.keyboardType {
        case .default, .asciiCapable, .twitter, .webSearch:
            return true
        default:
            return false
        }
    }

    var swipeCommittedWord: String? {
        get { insertOrigin?.swipeWord }
        set { insertOrigin = newValue.map(KeyboardInsertOrigin.swipe) }
    }

    @discardableResult
    func insertDictationText(_ text: String) -> Bool {
        guard canMutateDocument(allowSingleCharacterSelection: false) else { return false }
        let chunks = AutocorrectEngine.bulkInsertChunks(text)
        for chunk in chunks {
            textDocumentProxy.insertText(chunk)
        }
        lastBulkInsert = (text: text, at: ContinuousClock().now)
        textAfterBulkInsert = ""
        insertOrigin = .dictation
        autocorrect.suppressUntilWhitespace = true
        autocorrect.clearUndo()
        return true
    }

    @discardableResult
    func insertGIFURL(_ url: URL) -> Bool {
        insertPlain(url.absoluteString + " ")
    }
}
