import UIKit
import UniformTypeIdentifiers

/// Custom keyboard. Hands dictation to the containing app (iOS blocks in-appex mic),
/// then inserts the App Group result. Opens murmur://dictate.
final class KeyboardViewController: UIInputViewController, UIInputViewAudioFeedback {
    private enum Phase {
        case idle
        case waiting
        case secure
        case setup
    }

    private let root = KeyboardChromeView()
    private var heightConstraint: NSLayoutConstraint?
    private var session: Phase = .idle
    private var waitingID: String?
    private var pollTask: Task<Void, Never>?
    private var startTimeoutTask: Task<Void, Never>?
    private var lastSpaceTap: ContinuousClock.Instant?
    private let autocorrect = AutocorrectController()
    private var lastBulkInsert: (text: String, at: ContinuousClock.Instant)?
    private var textAfterBulkInsert = ""
    private let dictionary = DictionaryStore()
    private var insertOrigin: KeyboardInsertOrigin?
    private var swipeCommittedWord: String? {
        get { insertOrigin?.swipeWord }
        set { insertOrigin = newValue.map(KeyboardInsertOrigin.swipe) }
    }
    private var dictationRequest: KeyboardDictationRequest?
    private var gifInsertionTask: Task<Void, Never>?
    private var observedDocument: KeyboardDocumentFingerprint?

    private var documentFingerprint: KeyboardDocumentFingerprint {
        KeyboardDocumentFingerprint(documentIdentifier: textDocumentProxy.documentIdentifier)
    }

    private var allowsAutocorrection: Bool {
        KeyboardAutocorrectionPolicy.allowsReplacement(
            autocorrectionType: textDocumentProxy.autocorrectionType,
            keyboardType: textDocumentProxy.keyboardType,
            isSecure: textDocumentProxy.isSecureTextEntry == true
        )
    }
    private var lexiconDocuments: [String] = []

    var enableInputClicksWhenVisible: Bool { true }

    private var phase: Phase {
        if textDocumentProxy.isSecureTextEntry == true { return .secure }
        if !hasFullAccess || AppGroupStore.selectedEngineAPIKey.isEmpty { return .setup }
        return session
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.insetsLayoutMarginsFromSafeArea = false
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        let height = view.heightAnchor.constraint(equalToConstant: KeyboardChromeTokens.portraitHeight)
        height.priority = UILayoutPriority(999)
        heightConstraint = height
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height
        ])
        root.onMic = { [weak self] in self?.toggleRecord() }
        root.onCancel = { [weak self] in self?.cancelHandoff() }
        root.onDelete = { [weak self] in self?.deleteFromKeyboard() }
        root.onInsert = { [weak self] text in self?.insertFromKeyboard(text) }
        root.onCandidate = { [weak self] index in self?.applyCandidate(at: index) }
        root.onGif = { [weak self] in self?.toggleGifTray() }
        root.onGifSelect = { [weak self] gif in self?.insertGif(gif) }
        root.onSwipe = { [weak self] words in self?.insertSwipe(words) }
        root.onNeedsHeightChange = { [weak self] in self?.updateKeyboardHeight() }
        AppGroupStore.consumeGiphySeedIfNeeded()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (vc: KeyboardViewController, _) in
            vc.applyDocumentState()
        }
        applyDocumentState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Build stamp: proves which binary is actually serving keys. An iOS
        // reinstall does not restart a live keyboard process, and the
        // 2026-08-25 sentence-wipe hunt burned an hour not knowing.
        HandoffDiagnostics.record(
            "keyboard.appeared",
            detail: "build=\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")"
        )
        AppGroupStore.consumeGiphySeedIfNeeded()
        root.swipeTypingEnabled = AppGroupStore.swipeTypingEnabled
        dictionary.reload()
        rebuildSwipeLexicon(uiLexicon: nil)
        if let host = HostAppProbe.probedBundleID(from: self) {
            HostAppProbe.remember(host)
            HandoffDiagnostics.record("keyboard.host.detected", detail: "probed=\(host)")
        } else {
            HandoffDiagnostics.record("keyboard.host.detected", detail: "empty=")
        }
        signalHostReadyIfGated()
        _ = adoptExistingSession()
        consumeHandoffIfReady()
        applyDocumentState()
        updateKeyboardHeight()
        autocorrect.seedLearnedSpellings()
        if session == .waiting { startPolling() }
        requestSupplementaryLexicon { [weak self] lexicon in
            guard let self else { return }
            self.autocorrect.setLexicon(lexicon)
            self.rebuildSwipeLexicon(uiLexicon: lexicon)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        gifInsertionTask?.cancel()
        gifInsertionTask = nil
        pollTask?.cancel()
        pollTask = nil
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
        if textDocumentProxy.isSecureTextEntry == true {
            waitingID = nil
            session = .idle
        }
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        applyDocumentState()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateKeyboardHeight()
    }

    private func updateKeyboardHeight() {
        let landscape = traitCollection.verticalSizeClass == .compact
        let width = view.bounds.width > 1 ? view.bounds.width : UIScreen.main.bounds.width
        let metrics = KeyboardChromeMetrics.metrics(width: width, isLandscape: landscape)
        root.applyMetrics(metrics)
        let next = metrics.keyboardHeight + root.gifSearchExtraHeight
        guard let heightConstraint else { return }
        if heightConstraint.constant != next {
            heightConstraint.constant = next
        }
        if !heightConstraint.isActive {
            heightConstraint.isActive = true
        }
    }

    /// Keep the input view clear so the chrome's top radius is the only fill.
    /// Do not round or paint system ancestors (that was the lip + flicker).
    private func applyHostChrome() {
        view.backgroundColor = .clear
        view.isOpaque = false
        view.layer.cornerRadius = 0
        view.layer.maskedCorners = []
        view.clipsToBounds = false
    }

    private func isDarkKeyboard() -> Bool {
        KeyboardAppearanceResolve.isDark(
            keyboardAppearance: textDocumentProxy.keyboardAppearance ?? .default,
            userInterfaceStyle: traitCollection.userInterfaceStyle
        )
    }

    private func applyDocumentState() {
        let document = documentFingerprint
        if let observedDocument, observedDocument != document {
            gifInsertionTask?.cancel()
            gifInsertionTask = nil
            insertOrigin = nil
            lastBulkInsert = nil
            textAfterBulkInsert = ""
            lastSpaceTap = nil
            autocorrect.clearUndo()
            autocorrect.suppressUntilWhitespace = false
        }
        observedDocument = document
        if textDocumentProxy.isSecureTextEntry == true {
            waitingID = nil
            session = .idle
            pollTask?.cancel()
            pollTask = nil
        }
        let dark = isDarkKeyboard()
        root.setAppearance(dark: dark)
        applyHostChrome()
        root.setReturnTitle(returnTitle)
        updateCapitalization()
        refreshChrome()
    }

    private func updateCapitalization() {
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        let shouldCapitalize: Bool
        let allCharacters: Bool
        switch textDocumentProxy.autocapitalizationType ?? .sentences {
        case .allCharacters:
            shouldCapitalize = true
            allCharacters = true
        case .words:
            shouldCapitalize = context.isEmpty || context.last?.isWhitespace == true
            allCharacters = false
        case .sentences:
            let afterSentence = AutocorrectEngine.shouldCapitalizeSentence(beforeInput: context)
            shouldCapitalize = afterSentence
            allCharacters = false
        case .none:
            shouldCapitalize = false
            allCharacters = false
        @unknown default:
            shouldCapitalize = false
            allCharacters = false
        }
        root.setAutomaticCapitalization(shouldCapitalize, allCharacters: allCharacters)
    }

    private func insertFromKeyboard(_ text: String) {
        if root.handleGifTyping(text) {
            UIDevice.current.playInputClick()
            return
        }
        if root.handleEmojiTyping(text) {
            UIDevice.current.playInputClick()
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
        UIDevice.current.playInputClick()
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
                HandoffDiagnostics.record("keyboard.doubleSpace.period", detail: "walk=\(walk)")
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

    private func deleteFromKeyboard() {
        if root.handleGifDelete() {
            UIDevice.current.playInputClick()
            return
        }
        if root.handleEmojiDelete() {
            UIDevice.current.playInputClick()
            return
        }
        if let bulk = recentBulkInsertText() {
            guard KeyboardBulkEditPolicy.allowsDeletion(
                count: 1, beforeInput: textDocumentProxy.documentContextBeforeInput ?? "",
                selected: textDocumentProxy.selectedText, recentBulkInsert: bulk,
                textAfterBulkInsert: textAfterBulkInsert
            ) else { return }
        }
        if let selected = textDocumentProxy.selectedText, selected.count > 1 {
            let context = textDocumentProxy.documentContextBeforeInput ?? ""
            UIDevice.current.playInputClick()
            lastSpaceTap = nil
            swipeCommittedWord = nil
            // A "highlight" whose text lives inside the recent dictation
            // insert is the HOST's phantom selection, not the user's — one
            // deleteBackward ate 40 such characters on 2026-08-26 while the
            // before-context stayed identical. Refuse and defuse instead.
            if AutocorrectEngine.isLikelyHostHighlight(
                selected: selected,
                recentBulkInsert: recentBulkInsertText()
            ) {
                HandoffDiagnostics.record("keyboard.delete.refusedHostHighlight", detail: "len=\(selected.count)")
                updateCapitalization()
                refreshSuggestions()
                return
            }
            if AutocorrectEngine.shouldAbortMultiCharDelete(selected: selected, before: context) {
                HandoffDiagnostics.record("keyboard.delete.multiSelectAborted", detail: "len=\(selected.count)")
                updateCapitalization()
                refreshSuggestions()
                return
            }
            HandoffDiagnostics.record("keyboard.delete.multiSelect", detail: "len=\(selected.count)")
            // UIKit deletes the highlight even when before is empty (caret at
            // document start). Host-drop compare needs a non-empty before;
            // the empty skip stays on the caret path below.
            if context.isEmpty {
                textDocumentProxy.deleteBackward()
            } else {
                deleteBackwardCheckingHostDrop()
            }
            autocorrect.clearUndo()
            updateCapitalization()
            refreshSuggestions()
            return
        }
        if let word = swipeCommittedWord, !word.isEmpty {
            let context = textDocumentProxy.documentContextBeforeInput ?? ""
            let allowed = insertOrigin?.backspaceCount(context: context) ?? 0
            if allowed > 0 {
                UIDevice.current.playInputClick()
                HandoffDiagnostics.record("keyboard.delete.swipeWord", detail: "count=\(allowed)")
                deleteCharacters(allowed)
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
        UIDevice.current.playInputClick()
        lastSpaceTap = nil
        deleteBackwardCheckingHostDrop()
        autocorrect.clearUndo()
        updateCapitalization()
        refreshSuggestions()
    }

    private func insertSwipe(_ candidates: [String]) {
        guard phase != .waiting else { return }
        guard let first = candidates.first, !first.isEmpty else { return }
        if root.handleGifTyping(first) {
            UIDevice.current.playInputClick()
            return
        }
        UIDevice.current.playInputClick()
        guard canMutateDocument(allowSingleCharacterSelection: false) else { return }
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        let span = AutocorrectEngine.wordSpan(beforeInput: context)
        if !span.isEmpty {
            let allowed = AutocorrectEngine.allowedDeleteCount(span: span, inBeforeInput: context)
            guard allowed > 0, selectedTextIsEmpty else { return }
            guard deleteCharacters(allowed) else {
                HandoffDiagnostics.record("keyboard.swipe.abortedSpanEat", detail: "wanted=\(allowed)")
                return
            }
        }
        let afterSpan = textDocumentProxy.documentContextBeforeInput ?? ""
        if AutocorrectEngine.needsLeadingSpace(beforeInput: afterSpan) {
            insertPlain(" ")
        }
        let trailing = phase == .secure ? "" : " "
        guard insertPlain(first + trailing) else { return }
        lastBulkInsert = (text: first + trailing, at: ContinuousClock().now)
        textAfterBulkInsert = ""
        swipeCommittedWord = first + trailing
        lastSpaceTap = trailing == " " && supportsDoubleSpacePeriod ? ContinuousClock().now : nil
        autocorrect.suppressUntilWhitespace = true
        if phase != .secure {
            autocorrect.noteSwipe(committed: first, alternatives: candidates)
            showCandidates()
        }
        updateCapitalization()
    }

    private func applyAutocorrectIfNeeded(beforeInserting text: String, context: String) {
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
            HandoffDiagnostics.record("keyboard.autocorrect.abortedDelete", detail: "wanted=\(allowed)")
            return
        }
        insertPlain(replacement.insert)
        autocorrect.noteAutocorrect(original: span, corrected: replacement.insert)
    }

    private func applyCandidate(at index: Int) {
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
                HandoffDiagnostics.record("keyboard.candidate.abortedDelete", detail: "trailing=\(committed.trailing.count)")
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
            HandoffDiagnostics.record("keyboard.candidate.abortedDelete", detail: "wanted=\(allowed)")
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
        insertPlain(inserted)
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

    private func showCandidates() {
        root.setCandidates(autocorrect.displayed, quoted: autocorrect.quoted)
    }

    private func teachKeyboardWord(_ raw: String) {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AutocorrectEngine.shouldTeach(word, known: FrequencyList.words) else { return }
        autocorrect.ignore(word)
        LearnedWordStore.learn(word)
        UITextChecker.learnWord(word)
        let exists = dictionary.entries.contains {
            $0.term.lowercased() == word.lowercased()
        }
        if !exists {
            dictionary.add(term: word, variants: [], isAutoLearned: true)
        }
        rebuildSwipeLexicon(uiLexicon: nil)
    }

    private func refreshSuggestions() {
        guard phase != .secure, phase != .waiting else { return }
        guard allowsAutocorrection else {
            autocorrect.clearUndo()
            root.setCandidates([], quoted: [])
            return
        }
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        let span = AutocorrectEngine.wordSpan(beforeInput: context)
        if let corrected = autocorrect.lastCorrected {
            if span == corrected {
                root.setCandidates(autocorrect.displayed, quoted: autocorrect.quoted)
                return
            }
            let committed = AutocorrectEngine.committedSpan(beforeInput: context)
            if span.isEmpty, committed.word == corrected {
                root.setCandidates(autocorrect.displayed, quoted: autocorrect.quoted)
                return
            }
            autocorrect.clearUndo()
        }
        root.setCandidates(autocorrect.suggestions(for: span, beforeInput: context), quoted: autocorrect.quoted)
    }

    private func rebuildSwipeLexicon(uiLexicon: UILexicon?) {
        if let uiLexicon {
            lexiconDocuments = uiLexicon.entries.map(\.documentText)
        }
        let frequency = Set(FrequencyList.words)
        var priority: [String] = []
        for entry in dictionary.entries {
            priority.append(entry.term)
            priority.append(contentsOf: entry.variants)
        }
        priority.append(contentsOf: lexiconDocuments.filter {
            AutocorrectEngine.allowLexiconInSwipe($0, frequency: frequency)
        })
        priority.append(contentsOf: LearnedWordStore.words())
        root.swipeLexicon = AutocorrectEngine.prioritizedLexicon(
            priority: priority,
            frequency: FrequencyList.words
        )
        root.swipeCasing = AutocorrectEngine.preferredCasing(priority)
        autocorrect.setUserWords(priority)
    }

    private func shouldReplaceSecondSpaceWithPeriod() -> Bool {
        // SIMPLIFIED 2026-08-26: no double-space magic near a bulk insert.
        // Messages discards its provisional region when anything touches it;
        // near a transcript or swipe a space is just a space. Failure mode: no period
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
    private var selectedTextIsEmpty: Bool {
        guard let selected = textDocumentProxy.selectedText else { return true }
        return selected.isEmpty
    }

    /// Collapse a 1-char selection by moving one unit, never by `insertText`.
    /// Do not jump by `selected.length` — a stale clause-sized `selectedText`
    /// would move or extend the real range, and the next `deleteBackward`
    /// wipes the sentence.
    private func canMutateDocument(allowSingleCharacterSelection: Bool = true) -> Bool {
        switch AutocorrectEngine.documentMutationDecision(
            selected: textDocumentProxy.selectedText,
            allowSingleCharacterSelection: allowSingleCharacterSelection
        ) {
        case .allow:
            return true
        case .deny:
            HandoffDiagnostics.record(
                "keyboard.mutate.denied",
                detail: "selectedLen=\(textDocumentProxy.selectedText?.count ?? 0)"
            )
            return false
        case .collapseOneCharacterSelection:
            textDocumentProxy.adjustTextPosition(byCharacterOffset: 1)
            if let still = textDocumentProxy.selectedText, !still.isEmpty {
                HandoffDiagnostics.record("keyboard.mutate.collapseFailed", detail: "selectedLen=\(still.count)")
                return false
            }
            HandoffDiagnostics.record("keyboard.mutate.collapsed", detail: "")
            return true
        }
    }

    @discardableResult
    private func insertPlain(_ text: String) -> Bool {
        // Never overwrite a 1-char selection — collapse it. A phantom host
        // selection plus insertText is a silently eaten character.
        guard canMutateDocument(allowSingleCharacterSelection: false) else { return false }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        textDocumentProxy.insertText(text)
        if recentBulkInsertText() != nil {
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
    private func deleteCharacters(_ requested: Int) -> Bool {
        guard requested != 0 else { return true }
        let count = min(max(0, requested), AutocorrectEngine.maxDeleteLoop)
        guard count > 0 else { return false }
        guard canMutateDocument(allowSingleCharacterSelection: false) else { return false }
        for remaining in (1...count).reversed() {
            let before = textDocumentProxy.documentContextBeforeInput ?? ""
            guard KeyboardBulkEditPolicy.allowsDeletion(
                count: remaining, beforeInput: before, selected: textDocumentProxy.selectedText,
                recentBulkInsert: recentBulkInsertText(), textAfterBulkInsert: textAfterBulkInsert
            ) else { return false }
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

    private func recentBulkInsertText() -> String? {
        guard let last = lastBulkInsert,
              ContinuousClock().now - last.at < .seconds(180) else { return nil }
        return last.text
    }

    /// A delete removed more than expected (host word-delete or hidden
    /// selection). SIMPLIFIED 2026-08-26: log only — every automatic
    /// reinsertion built during the sentence-wipe saga misfired somewhere;
    /// cleverness here must fail to "nothing happens".
    private func restoreHiddenSelectionLoss(before: String, after: String) {
        HandoffDiagnostics.record(
            "keyboard.delete.hostDrop",
            detail: "before=\(before.count) after=\(after.count)"
        )
    }

    /// One `deleteBackward` for Delete / nil-selection. Insert still treats
    /// nil `selectedText` as an empty caret. Empty `before` is a no-op
    /// (nothing to backspace). Multi-char selection at document start
    /// deletes once in `deleteFromKeyboard` instead. If the host ate a
    /// hidden range, stop — we cannot un-delete, but we must not loop.
    /// The first host word-delete cannot be undone.
    private func deleteBackwardCheckingHostDrop() {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        guard KeyboardBulkEditPolicy.allowsDeletion(
            count: 1, beforeInput: before, selected: nil,
            recentBulkInsert: recentBulkInsertText(), textAfterBulkInsert: textAfterBulkInsert
        ) else { return }
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

    private var supportsDoubleSpacePeriod: Bool {
        guard textDocumentProxy.isSecureTextEntry != true else { return false }
        switch textDocumentProxy.keyboardType {
        case .default, .asciiCapable, .twitter, .webSearch:
            return true
        default:
            return false
        }
    }

    private var returnTitle: String {
        switch textDocumentProxy.returnKeyType {
        case .go: return "go"
        case .google: return "Google"
        case .join: return "join"
        case .next: return "next"
        case .route: return "route"
        case .search: return "search"
        case .send: return "send"
        case .done: return "done"
        case .emergencyCall: return "call"
        case .continue: return "continue"
        default: return "return"
        }
    }

    private func toggleGifTray() {
        guard hasFullAccess, !AppGroupStore.giphyAPIKey.isEmpty else { return }
        guard phase != .secure, phase != .waiting else { return }
        root.setGifTrayVisible(!root.isGifTrayVisible)
        refreshChrome()
    }

    private func insertGif(_ gif: GiphyClient.GIF) {
        let document = documentFingerprint
        gifInsertionTask?.cancel()
        gifInsertionTask = Task {
            var pasted = false
            if hasFullAccess {
                pasted = await copyGIFToPasteboard(from: gif.sendURL)
            }
            await MainActor.run {
                guard document.allowsInsertion(into: self.documentFingerprint, isCancelled: Task.isCancelled),
                      self.textDocumentProxy.isSecureTextEntry != true else { return }
                self.insertPlain(gif.sendURL.absoluteString + " ")
                HandoffDiagnostics.record(
                    "keyboard.gif.inserted",
                    detail: "p2a url p2b=\(pasted)"
                )
                self.root.setGifTrayVisible(false)
                self.updateCapitalization()
                self.refreshSuggestions()
                self.refreshChrome()
            }
        }
    }

    private func copyGIFToPasteboard(from url: URL) async -> Bool {
        do {
            let data = try await GiphyClient.fetchData(from: url)
            guard !Task.isCancelled, data.count > 16 else { return false }
            await MainActor.run {
                UIPasteboard.general.setItems(
                    [[
                        UTType.gif.identifier: data,
                        UTType.url.identifier: url
                    ]],
                    options: [:]
                )
            }
            return true
        } catch {
            return false
        }
    }

    private func refreshChrome() {
        root.setSecure(phase == .secure)
        root.setFullAccess(hasFullAccess)
        root.setGiphyAPIKey(AppGroupStore.giphyAPIKey)
        let gifOK = hasFullAccess
            && !AppGroupStore.giphyAPIKey.isEmpty
            && phase != .secure
            && phase != .waiting
        let gifReason: String
        if phase == .secure {
            gifReason = "GIFs are off in secure fields"
        } else if !hasFullAccess {
            gifReason = "Turn on Full Access for GIFs."
        } else if AppGroupStore.giphyAPIKey.isEmpty {
            gifReason = "Add a Giphy key in Murmur."
        } else {
            gifReason = "GIFs"
        }
        root.setGifAvailable(gifOK, reason: gifReason)
        if root.isGifTrayVisible {
            root.setReturnTitle("search")
        } else {
            root.setReturnTitle(returnTitle)
        }
        switch phase {
        case .secure:
            break
        case .setup:
            root.setRecording(false)
            let span = AutocorrectEngine.wordSpan(
                beforeInput: textDocumentProxy.documentContextBeforeInput ?? ""
            )
            if span.isEmpty {
                if !hasFullAccess {
                    root.setStatus("Turn on Full Access in Settings")
                } else {
                    root.setStatus(
                        AppGroupStore.selectedCloudEngine == .gemini
                            ? "Add a Gemini key in Murmur"
                            : "Add an ElevenLabs key in Murmur"
                    )
                }
            } else {
                root.setStatus(" ")
                refreshSuggestions()
            }
        case .waiting:
            applyLiveStatus()
        case .idle:
            root.setRecording(false)
            root.setStatus(" ")
            refreshSuggestions()
        }
    }

    private func applyLiveStatus() {
        guard let payload = DictationHandoff.read(), payload.id == waitingID else {
            root.setRecording(true)
            root.setStatus("Starting…")
            return
        }
        switch payload.status {
        case .pending:
            root.setRecording(true)
            if !AppGroupStore.listenGateRequestID.isEmpty {
                root.setStatus("Murmur is on — swipe back to speak")
            } else {
                root.setStatus("Starting…")
            }
        case .recording:
            root.setRecording(true)
            root.setStatus("Listening… tap mic to send")
            root.setMeterLevel(AppGroupStore.microphoneLevel)
        case .paused:
            root.setRecording(true)
            root.setStatus("Paused")
        case .transcribing:
            root.setRecording(true)
            root.setStatus("Transcribing…")
        case .done, .failed, .cancelled:
            root.setMeterLevel(0)
            break
        }
    }

    private func toggleRecord() {
        switch phase {
        case .secure, .setup:
            return
        case .waiting:
            handleLiveMic()
        case .idle:
            if adoptExistingSession() {
                handleLiveMic()
            } else {
                startHandoff()
            }
        }
    }

    private func handleLiveMic() {
        switch DictationHandoff.read()?.status {
        case .paused:
            DictationBridge.post(.toggle)
        case .recording, .pending:
            // Second mic tap ends the take and inserts — talk happens in the host app.
            DictationBridge.post(.stop)
        case .transcribing:
            root.setStatus("Transcribing…")
        case .done, .failed, .cancelled, nil:
            break
        }
    }

    private func cancelHandoff() {
        guard let payload = DictationHandoff.read(), payload.id == waitingID else {
            finishWait()
            refreshChrome()
            return
        }
        HandoffDiagnostics.record("keyboard.cancel.requested", detail: payload.id)
        DictationBridge.post(.cancel)
        DictationHandoff.clearLease()
        DictationHandoff.write(.init(
            id: payload.id,
            status: .cancelled,
            text: "",
            error: "",
            hostBundleID: payload.hostBundleID
        ))
        consumeHandoffIfReady()
    }

    @discardableResult
    private func adoptExistingSession() -> Bool {
        guard let payload = DictationHandoff.read(),
              payload.id == waitingID,
              dictationRequest?.id == payload.id else { return false }
        switch payload.status {
        case .pending, .recording, .paused, .transcribing:
            waitingID = payload.id
            session = .waiting
            startPolling()
            refreshChrome()
            return true
        case .done, .failed, .cancelled:
            waitingID = payload.id
            consumeHandoffIfReady()
            return false
        }
    }

    private func startHandoff() {
        root.dismissError()
        let id = UUID().uuidString
        let probed = HostAppProbe.probedBundleID(from: self)
        let hostPID = HostAppProbe.discoveredPIDs(from: self).first.map { Int($0) }
        if let probed {
            HostAppProbe.remember(probed)
            HandoffDiagnostics.record(
                "keyboard.host.handoff",
                detail: "probed=\(probed) pid=\(hostPID ?? 0) return=\(textDocumentProxy.returnKeyType?.rawValue ?? -1)"
            )
        } else {
            HostAppProbe.forget()
            HandoffDiagnostics.record(
                "keyboard.host.handoff",
                detail: "empty= pid=\(hostPID ?? 0) return=\(textDocumentProxy.returnKeyType?.rawValue ?? -1)"
            )
        }
        let host = probed ?? ""
        let lease = DictationHandoff.readLease()
        DictationHandoff.write(.init(
            id: id,
            status: .pending,
            text: "",
            error: "",
            hostBundleID: host,
            hostPID: hostPID
        ))
        waitingID = id
        dictationRequest = KeyboardDictationRequest(id: id, document: documentFingerprint)
        session = .waiting
        HandoffDiagnostics.record(
            "keyboard.request.created",
            detail: "\(id) host=\(host.isEmpty ? "empty" : host) pid=\(hostPID ?? 0)"
        )
        refreshChrome()
        let url = DictationHandoff.dictateURL(
            id: id,
            hostBundleID: host.isEmpty ? nil : host,
            hostPID: hostPID,
            keyboardStack: true
        )
        if let lease {
            HandoffDiagnostics.record(
                "keyboard.lease.reusing",
                detail: "\(lease.sessionID) expires=\(lease.expiresAt.timeIntervalSince1970)"
            )
            DictationBridge.post(.start)
            startReuseTimeout(for: id, url: url)
        } else {
            openContainingApp(url)
            startSubmissionTimeout(for: id)
        }
        startPolling()
    }

    /// Tell the host the originating keyboard is on screen so listen-gate can open the segment.
    private func signalHostReadyIfGated() {
        let gatedID = AppGroupStore.listenGateRequestID
        guard !gatedID.isEmpty else { return }
        guard let payload = DictationHandoff.read(),
              payload.id == gatedID,
              payload.id == waitingID,
              dictationRequest?.accepts(id: payload.id, document: documentFingerprint) == true,
              payload.status == .pending else { return }
        HandoffDiagnostics.record("keyboard.hostReady", detail: gatedID)
        DictationBridge.post(.hostReady)
    }

    private func startReuseTimeout(for id: String, url: URL) {
        startTimeoutTask?.cancel()
        startTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.waitingID == id,
                      DictationHandoff.read()?.status == .pending else { return }
                HandoffDiagnostics.record("keyboard.lease.unresponsive", detail: id)
                DictationHandoff.clearLease()
                self?.openContainingApp(url)
                self?.startSubmissionTimeout(for: id)
            }
        }
    }

    private func startSubmissionTimeout(for id: String) {
        startTimeoutTask?.cancel()
        startTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.waitingID == id,
                      DictationHandoff.read()?.status == .pending else { return }
                HandoffDiagnostics.record("keyboard.launch.timeout", detail: id)
                self?.failHandoff("The recording app did not start. Try again.")
            }
        }
    }

    private func failHandoff(_: String) {
        guard let id = waitingID else { return }
        DictationHandoff.write(.init(
            id: id,
            status: .failed,
            text: "",
            error: "Couldn’t start dictation. Try again.",
            hostBundleID: DictationHandoff.read()?.hostBundleID ?? ""
        ))
        consumeHandoffIfReady()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run { self?.consumeHandoffIfReady() }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func consumeHandoffIfReady() {
        guard let payload = DictationHandoff.read(),
              payload.id == waitingID,
              let request = dictationRequest,
              request.id == payload.id else { return }
        switch payload.status {
        case .pending, .recording, .paused, .transcribing:
            applyLiveStatus()
            return
        case .done:
            HandoffDiagnostics.record("keyboard.result.received", detail: payload.id)
            let sameDocument = request.accepts(id: payload.id, document: documentFingerprint)
            finishWait()
            guard sameDocument, textDocumentProxy.isSecureTextEntry != true else {
                if !payload.text.isEmpty { UIPasteboard.general.string = payload.text }
                refreshChrome()
                root.showError("Dictation copied to clipboard. The text field changed.")
                return
            }
            let text = AutocorrectEngine.preparedDictationInsert(
                transcript: payload.text,
                beforeInput: textDocumentProxy.documentContextBeforeInput ?? "",
                trailingSpace: true
            )
            if !text.isEmpty {
                // Messages holds (part of) a fresh bulk insert as a selection
                // the user never made — proven 2026-08-26: a 40-char reported
                // highlight matching the last chunk, eaten by one delete tap
                // with before-context unchanged. Insert in word-boundary
                // chunks, remember the take for the highlight guard, and
                // DEFUSE any selection the host reports afterward by walking
                // the caret to its end (over-walks clamp at document end).
                // No caret nudge here — an adjust against an anchored pending
                // region is a suspect for creating that selection.
                guard canMutateDocument(allowSingleCharacterSelection: false) else { return }
                let chunks = AutocorrectEngine.bulkInsertChunks(text)
                for chunk in chunks {
                    textDocumentProxy.insertText(chunk)
                }
                lastBulkInsert = (text: text, at: ContinuousClock().now)
                textAfterBulkInsert = ""
                insertOrigin = .dictation
                autocorrect.suppressUntilWhitespace = true
                autocorrect.clearUndo()
                HandoffDiagnostics.record(
                    "keyboard.insertion.acknowledged",
                    detail: "\(payload.id) characters=\(text.count) chunks=\(chunks.count)"
                )
            }
            DictationHandoff.clear()
            refreshChrome()
        case .failed:
            finishWait()
            let message = payload.error.isEmpty
                ? "Couldn't start audio capture. Tap the mic to try again, or quit and reopen Murmur if it keeps happening."
                : payload.error
            root.showError(message)
            DictationHandoff.clear()
            refreshChrome()
        case .cancelled:
            finishWait()
            DictationHandoff.clear()
            refreshChrome()
        }
    }

    private func openContainingApp(_ url: URL) {
        HandoffDiagnostics.record("keyboard.launch.requested", detail: url.absoluteString)
        guard let extensionContext else {
            openViaResponderChain(url)
            return
        }
        extensionContext.open(url) { [weak self] opened in
            HandoffDiagnostics.record("keyboard.launch.extensionContext", detail: String(opened))
            guard !opened else { return }
            Task { @MainActor in self?.openViaResponderChain(url) }
        }
    }

    /// Keyboard extensions have no public containing-app launcher. Reaching UIApplication
    /// through the responder chain is intentionally confined to the sideload build.
    private func openViaResponderChain(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                HandoffDiagnostics.record(
                    "keyboard.launch.uiapplication",
                    detail: "state=\(application.applicationState.rawValue) canOpen=\(application.canOpenURL(url)) selector=open:options:completionHandler:"
                )
                application.open(url, options: [:]) { opened in
                    HandoffDiagnostics.record("keyboard.launch.uiapplication.completed", detail: String(opened))
                }
                return
            }
            responder = current.next
        }
        HandoffDiagnostics.record("keyboard.launch.failed", detail: "No openURL responder")
        failHandoff("Containing app launch was unavailable")
    }

    private func finishWait() {
        waitingID = nil
        dictationRequest = nil
        session = .idle
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
        pollTask?.cancel()
        pollTask = nil
        root.setRecording(false)
        root.setMeterLevel(0)
    }

}
