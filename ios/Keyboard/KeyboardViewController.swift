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
    private let dictionary = DictionaryStore()
    private var swipeCommittedWord: String?
    private var lexiconDocuments: [String] = []

    var enableInputClicksWhenVisible: Bool { true }

    private var phase: Phase {
        if textDocumentProxy.isSecureTextEntry == true { return .secure }
        if !hasFullAccess || AppGroupStore.apiKey.isEmpty { return .setup }
        return session
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        let height = view.heightAnchor.constraint(equalToConstant: KeyboardChromeTokens.portraitHeight)
        height.priority = .defaultHigh
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
        root.onGlobe = { [weak self] in self?.advanceToNextInputMode() }
        root.onInsert = { [weak self] text in self?.insertFromKeyboard(text) }
        root.onSpaceDrag = { [weak self] delta in
            self?.textDocumentProxy.adjustTextPosition(byCharacterOffset: delta)
        }
        root.onCandidate = { [weak self] index in self?.applyCandidate(at: index) }
        root.onGif = { [weak self] in self?.toggleGifTray() }
        root.onGifSelect = { [weak self] gif in self?.insertGif(gif) }
        root.onSwipe = { [weak self] words in self?.insertSwipe(words) }
        root.setShowsGlobe(needsInputModeSwitchKey)
        AppGroupStore.consumeGiphySeedIfNeeded()
        applyDocumentState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        AppGroupStore.consumeGiphySeedIfNeeded()
        root.swipeTypingEnabled = AppGroupStore.swipeTypingEnabled
        dictionary.reload()
        rebuildSwipeLexicon(uiLexicon: nil)
        root.setShowsGlobe(needsInputModeSwitchKey)
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

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateKeyboardHeight()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateKeyboardHeight()
    }

    private func updateKeyboardHeight() {
        let landscape = traitCollection.verticalSizeClass == .compact
        let next = landscape ? KeyboardChromeTokens.landscapeHeight : KeyboardChromeTokens.portraitHeight
        guard heightConstraint?.constant != next else { return }
        heightConstraint?.constant = next
    }

    private func applyDocumentState() {
        if textDocumentProxy.isSecureTextEntry == true {
            waitingID = nil
            session = .idle
            pollTask?.cancel()
            pollTask = nil
        }
        let appearance = textDocumentProxy.keyboardAppearance
        let dark = appearance == .dark
            || (appearance == .default && traitCollection.userInterfaceStyle == .dark)
        root.setAppearance(dark: dark)
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
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        if AutocorrectEngine.shouldEatTrailingSwipeSpace(beforeInserting: text),
           swipeCommittedWord != nil,
           context.last == " " {
            textDocumentProxy.deleteBackward()
        }
        swipeCommittedWord = nil
        UIDevice.current.playInputClick()
        if text == " ", shouldReplaceSecondSpaceWithPeriod() {
            textDocumentProxy.deleteBackward()
            textDocumentProxy.insertText(". ")
            lastSpaceTap = nil
            updateCapitalization()
            refreshSuggestions()
            return
        }
        autocorrect.noteIncomingText(text)
        applyAutocorrectIfNeeded(beforeInserting: text)
        if AutocorrectEngine.isCommitText(text) {
            let span = AutocorrectEngine.wordSpan(beforeInput: context)
            if autocorrect.undoOriginal?.lowercased() != span.lowercased() {
                teachKeyboardWord(span)
            }
        }
        textDocumentProxy.insertText(text)
        lastSpaceTap = text == " " && supportsDoubleSpacePeriod ? ContinuousClock().now : nil
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
        if let word = swipeCommittedWord, !word.isEmpty {
            let context = textDocumentProxy.documentContextBeforeInput ?? ""
            if context.hasSuffix(word) {
                UIDevice.current.playInputClick()
                for _ in 0..<word.count {
                    textDocumentProxy.deleteBackward()
                }
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
        textDocumentProxy.deleteBackward()
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
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        let span = AutocorrectEngine.wordSpan(beforeInput: context)
        for _ in 0..<span.count {
            textDocumentProxy.deleteBackward()
        }
        let afterSpan = textDocumentProxy.documentContextBeforeInput ?? ""
        if AutocorrectEngine.needsLeadingSpace(beforeInput: afterSpan) {
            textDocumentProxy.insertText(" ")
        }
        let trailing = phase == .secure ? "" : " "
        textDocumentProxy.insertText(first + trailing)
        swipeCommittedWord = first + trailing
        lastSpaceTap = trailing == " " && supportsDoubleSpacePeriod ? ContinuousClock().now : nil
        autocorrect.suppressUntilWhitespace = true
        if phase != .secure {
            autocorrect.noteSwipe(committed: first, alternatives: candidates)
            showCandidates()
        }
        updateCapitalization()
    }

    private func applyAutocorrectIfNeeded(beforeInserting text: String) {
        guard phase != .secure, phase != .waiting else { return }
        guard AutocorrectEngine.isCommitText(text) else { return }
        // Suppress is for the swipe/dictation token on its own trailing space,
        // not the next typed word. `noteIncomingText` already cleared it if
        // this commit follows a new letter span (`i` + space after a swipe).
        guard !autocorrect.suppressUntilWhitespace else { return }
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        let span = AutocorrectEngine.wordSpan(beforeInput: context)
        guard let correction = autocorrect.correction(for: span), correction != span else { return }
        let replacement = AutocorrectEngine.replacement(span: span, correction: correction)
        for _ in 0..<replacement.deleteCount {
            textDocumentProxy.deleteBackward()
        }
        textDocumentProxy.insertText(replacement.insert)
        autocorrect.noteAutocorrect(original: span, corrected: replacement.insert)
    }

    private func applyCandidate(at index: Int) {
        guard phase != .secure, phase != .waiting else { return }
        let choices = autocorrect.displayed
        guard index >= 0, index < choices.count else { return }
        let chosen = choices[index]
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        if AutocorrectEngine.isPunctuationSuggestion(chosen) {
            let committed = AutocorrectEngine.committedSpan(beforeInput: context)
            for _ in 0..<committed.trailing.count {
                textDocumentProxy.deleteBackward()
            }
            textDocumentProxy.insertText(chosen + " ")
            swipeCommittedWord = nil
            lastSpaceTap = supportsDoubleSpacePeriod ? ContinuousClock().now : nil
            autocorrect.clearUndo()
            autocorrect.suppressUntilWhitespace = false
            updateCapitalization()
            refreshSuggestions()
            return
        }
        let active = AutocorrectEngine.wordSpan(beforeInput: context)
        let target: String
        let trailing: String
        if !active.isEmpty {
            target = active
            trailing = ""
        } else {
            let committed = AutocorrectEngine.committedSpan(beforeInput: context)
            target = committed.word
            trailing = committed.trailing
        }
        guard !target.isEmpty else { return }
        for _ in 0..<(trailing.count + target.count) {
            textDocumentProxy.deleteBackward()
        }
        let inserted: String
        if AutocorrectEngine.periodAttachedWord(chosen) != nil {
            inserted = chosen + (trailing.isEmpty && phase != .secure ? " " : trailing)
        } else if swipeCommittedWord != nil, trailing.isEmpty, phase != .secure {
            inserted = chosen + " "
        } else {
            inserted = chosen + trailing
        }
        textDocumentProxy.insertText(inserted)
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
        guard supportsDoubleSpacePeriod,
              let lastSpaceTap,
              ContinuousClock().now - lastSpaceTap < .milliseconds(700),
              let context = textDocumentProxy.documentContextBeforeInput,
              context.last == " ",
              let preceding = context.dropLast().last else { return false }
        return String(preceding).rangeOfCharacter(from: .alphanumerics) != nil
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
        Task {
            var pasted = false
            if hasFullAccess {
                pasted = await copyGIFToPasteboard(from: gif.sendURL)
            }
            await MainActor.run {
                self.textDocumentProxy.insertText(gif.sendURL.absoluteString + " ")
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
            guard data.count > 16 else { return false }
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
                    root.setStatus("Add an ElevenLabs key in Murmur")
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
        guard let payload = DictationHandoff.read() else { return false }
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
        guard let payload = DictationHandoff.read() else { return }
        if waitingID == nil {
            waitingID = payload.id
        }
        guard payload.id == waitingID else { return }
        switch payload.status {
        case .pending, .recording, .paused, .transcribing:
            applyLiveStatus()
            return
        case .done:
            HandoffDiagnostics.record("keyboard.result.received", detail: payload.id)
            finishWait()
            if textDocumentProxy.isSecureTextEntry == true { return }
            let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                textDocumentProxy.insertText(text)
                autocorrect.suppressUntilWhitespace = true
                autocorrect.clearUndo()
                HandoffDiagnostics.record(
                    "keyboard.insertion.acknowledged",
                    detail: "\(payload.id) characters=\(text.count)"
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
        session = .idle
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
        pollTask?.cancel()
        pollTask = nil
        root.setRecording(false)
        root.setMeterLevel(0)
    }

}
