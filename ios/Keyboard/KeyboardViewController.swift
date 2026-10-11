import UIKit
import UniformTypeIdentifiers

/// Custom keyboard. Hands dictation to the containing app (iOS blocks in-appex mic),
/// then inserts the App Group result. Opens murmur://dictate.
final class KeyboardViewController: UIInputViewController, UIInputViewAudioFeedback, KeyboardEditing {
    typealias Phase = KeyboardEditingPhase

    private let root = KeyboardChromeView()
    private var heightConstraint: NSLayoutConstraint?
    private var session: Phase = .idle
    private var waitingID: String?
    private var pollTask: Task<Void, Never>?
    private var startTimeoutTask: Task<Void, Never>?
    var lastSpaceTap: ContinuousClock.Instant?
    let autocorrect = AutocorrectController()
    var lastBulkInsert: (text: String, at: ContinuousClock.Instant)?
    var textAfterBulkInsert = ""
    private let dictionary = DictionaryStore()
    var insertOrigin: KeyboardInsertOrigin?
    private var dictationRequest: KeyboardDictationRequest?
    private var gifInsertionTask: Task<Void, Never>?
    private var observedDocument: KeyboardDocumentFingerprint?

    private var documentFingerprint: KeyboardDocumentFingerprint {
        KeyboardDocumentFingerprint(documentIdentifier: textDocumentProxy.documentIdentifier)
    }

    var allowsAutocorrection: Bool {
        KeyboardAutocorrectionPolicy.allowsReplacement(
            autocorrectionType: textDocumentProxy.autocorrectionType,
            keyboardType: textDocumentProxy.keyboardType,
            isSecure: textDocumentProxy.isSecureTextEntry == true
        )
    }
    private var lexiconDocuments: [String] = []

    var enableInputClicksWhenVisible: Bool { true }

    var phase: Phase {
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
        invalidateTypedSuffixOwnership()
        applyDocumentState()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        invalidateTypedSuffixOwnership()
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

    func updateCapitalization() {
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

    func showCandidates() {
        root.setCandidates(autocorrect.displayed, quoted: autocorrect.quoted)
    }

    func teachKeyboardWord(_ raw: String) {
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

    func refreshSuggestions() {
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


    func handleGifTyping(_ text: String) -> Bool { root.handleGifTyping(text) }
    func handleEmojiTyping(_ text: String) -> Bool { root.handleEmojiTyping(text) }
    func handleGifDelete() -> Bool { root.handleGifDelete() }
    func handleEmojiDelete() -> Bool { root.handleEmojiDelete() }
    func playInputClick() { UIDevice.current.playInputClick() }
    func recordEditDiagnostic(_ event: String, detail: String) {
        HandoffDiagnostics.record(event, detail: detail)
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
                self.insertGIFURL(gif.sendURL)
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
                // Dictation owns a protected bulk region. Automatic edits
                // cannot delete it; explicit Backspace remains the user's choice.
                guard insertDictationText(text) else { return }
                HandoffDiagnostics.record(
                    "keyboard.insertion.acknowledged",
                    detail: "\(payload.id) characters=\(text.count) chunks=\(AutocorrectEngine.bulkInsertChunks(text).count)"
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
