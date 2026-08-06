import AppKit
import SwiftUI
import Sparkle

/// `@MainActor`: every callback on `NSApplicationDelegate` fires on main, and
/// this type now constructs/holds `@MainActor`-isolated stores
/// (`SettingsStore`, `ModelManager`) as stored properties — annotating the
/// whole delegate keeps that consistent instead of sprinkling `MainActor.run`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var activationController: ActivationController?
    private var hotkeyController: HotkeyController?
    private var updaterController: SPUStandardUpdaterController?
    private var onboardingWindow: NSWindow?

    /// True while the menu-bar error badge (`mic.badge.xmark`) is showing —
    /// guards `resetMenuBarIconToIdle()` from clobbering it early.
    private var isShowingMenuBarErrorBadge = false

    // MARK: - Main window + UI stores

    private let historyStore = HistoryStore()
    private let dictionaryStore = DictionaryStore()
    private let correctionsLog = CorrectionsLog()
    private let snippetsStore = SnippetsStore()
    private let styleStore = StyleStore()
    private let transformsStore = TransformsStore()
    private let scratchpadStore = ScratchpadStore()
    private let settingsStore = SettingsStore()
    private let correctionWatcher = CorrectionWatcher()
    private let learnToast = LearnToastHUD()
    private var learnEventsCoordinator: LearnEventsCoordinator?

    /// Owns per-model download/storage state. `@MainActor`-isolated, so it's
    /// constructed lazily from `applicationDidFinishLaunching` (guaranteed
    /// main-thread) rather than as a stored-property initializer.
    private var modelManager: ModelManager!

    /// Lazily constructed so the window (and its SwiftUI hierarchy) is only
    /// built once, on first need — not at every Dock-icon click. First
    /// accessed from `openMainWindow()`, which runs after `modelManager` is
    /// assigned in `applicationDidFinishLaunching`, so the force-unwrap here
    /// is safe.
    private lazy var mainWindowController = MainWindowController(
        historyStore: historyStore,
        dictionaryStore: dictionaryStore,
        snippetsStore: snippetsStore,
        styleStore: styleStore,
        transformsStore: transformsStore,
        scratchpadStore: scratchpadStore,
        settingsStore: settingsStore,
        modelManager: modelManager,
        openAIKeyProvider: { [weak settingsStore] in settingsStore?.cleanupKeyValue() },
        asrEngineSelector: { [weak self] in self?.activationController?.audioRecorder.asrSelector },
        onReplayOnboarding: { [weak self] in self?.replayOnboarding() }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontRegistrar.registerBundledFonts()
        VoicePaths.prepareApplicationSupportVoiceDirectory()
        CorrectionsLog.liveInstance = correctionsLog

        if SparkleSupport.isEnabled {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        }

        setupMainMenu()
        // Broken seal silently greys Sparkle and breaks AX/injection — scream once.
        if SparkleSupport.status == .brokenSignature {
            presentBrokenSignatureAlert()
        }
        setupMenuBar()
        // ModelManager init runs WhisperKit Documents→App Support migration
        // before the activation tap starts accepting dictation.
        modelManager = ModelManager()

        activationController = ActivationController()
        activationController?.useToggleLockProvider = { [weak self] in
            self?.settingsStore.useToggleLock ?? false
        }
        activationController?.start()

        hotkeyController = HotkeyController()
        hotkeyController?.transformProvider = { [weak self] in
            guard let self else { return nil }
            if let id = self.transformsStore.autoRunTransformID {
                return self.transformsStore.transform(withID: id)
            }
            return self.transformsStore.transforms.first
        }
        hotkeyController?.lastDictationProvider = { [weak self] in
            self?.historyStore.entries.first?.text
        }
        hotkeyController?.openAIKeyProvider = { [weak self] in
            self?.settingsStore.cleanupKeyValue()
        }
        hotkeyController?.start()

        // Wire the settings store to the live activation/ASR components so
        // Settings changes apply immediately, then push any persisted
        // settings onto them (they otherwise start with hardcoded defaults).
        // This single `asrEngineSelector` wire-up covers BOTH the local model
        // (selectedModel) and the cloud engine hooks (cloudModel +
        // apiKeyProvider, applied via SettingsStore.applyCloudSettings()) —
        // applyOnLaunch() below pushes all of it onto the live selector in
        // one pass, so cloud state (Keychain-backed key lookup + persisted
        // Local/Cloud toggle) is live from first launch, not just after a
        // Settings change.
        settingsStore.activationController = activationController
        settingsStore.asrEngineSelector = activationController?.audioRecorder.asrSelector
        settingsStore.audioRecorder = activationController?.audioRecorder
        settingsStore.modelManager = modelManager
        // History must be wired before applyOnLaunch so budget prune can
        // protect failed-retry audio paths (empty keep list = data loss).
        settingsStore.historyStore = historyStore

        // Keep failed-history audio when pruning the retention ring.
        // Snapshot only — never mutate HistoryStore from the audio IO queue.
        activationController?.audioRecorder.protectedAudioPathsProvider = { [weak self] in
            self?.historyStore.protectedAudioPathsSnapshot() ?? []
        }
        activationController?.audioRecorder.recordingBudgetBytesProvider = { [weak self] in
            self?.settingsStore.recordingBudgetBytes
                ?? Int64(RecordingRetention.defaultBudgetMB) * 1024 * 1024
        }

        settingsStore.applyOnLaunch()

        // Style profile is pushed the same way as the cleanup settings above —
        // it's an instruction the cleanup LLM consumes, not a separate pass,
        // so it rides the same `asrEngineSelector` wire.
        styleStore.asrEngineSelector = activationController?.audioRecorder.asrSelector
        styleStore.applyOnLaunch()

        transformsStore.asrEngineSelector = activationController?.audioRecorder.asrSelector
        transformsStore.applyOnLaunch()

        activationController?.audioRecorder.asrSelector.openAIKeyProvider = { [weak settingsStore] in
            settingsStore?.cleanupKeyValue()
        }

        activationController?.audioRecorder.asrSelector.onRecordingStart = { [weak self] in
            self?.styleStore.applyStyleForFrontmostApp()
            self?.correctionWatcher.endWatchForNewRecording()
        }

        activationController?.audioRecorder.asrSelector.onInterimTranscript = { [weak self] text in
            self?.activationController?.audioRecorder.hud.showInterimText(text)
        }

        // Wire transcription completion into History + Dictionary so every
        // transcript is captured (and corrected) before/regardless of
        // injection outcome. See ASREngineSelector.onTranscription.
        activationController?.audioRecorder.asrSelector.onTranscription = { [weak self] text, engineID in
            guard let self = self else { return (text, []) }
            return self.dictionaryStore.correct(text)
        }
        activationController?.audioRecorder.asrSelector.onCorrectionsRecorded = { [weak self] records in
            guard let self = self else { return }
            self.correctionsLog.append(records)
            self.activationController?.audioRecorder.hud.setPendingCorrectionCount(records.count)
        }
        activationController?.audioRecorder.asrSelector.onSnippetExpand = { [weak self] text in
            guard let self = self else { return text }
            return self.snippetsStore.expand(text)
        }
        activationController?.audioRecorder.asrSelector.onTextInserted = { [weak self] delivered in
            self?.correctionWatcher.beginWatch(deliveredText: delivered)
        }

        correctionWatcher.onLearn = { [weak self] oldText, newText in
            _ = self?.dictionaryStore.learn(from: oldText, to: newText, userInitiated: false)
        }
        settingsStore.correctionWatcher = correctionWatcher
        correctionWatcher.isEnabled = settingsStore.learnFromInlineCorrections

        wireLearnToast()

        // Feeds the learned dictionary's canonical terms into ElevenLabs'
        // `keyterms` vocabulary bias (plan 014) — read fresh on every
        // streaming-session build so newly-learned terms apply immediately,
        // with no separate cache/invalidation to keep in sync.
        activationController?.audioRecorder.asrSelector.keytermsProvider = { [weak self] in
            guard let self = self else { return [] }
            return ElevenLabsRealtimeTranscriber.selectKeyterms(from: self.dictionaryStore.entries)
        }
        activationController?.audioRecorder.asrSelector.capitalizedDictionaryTermsProvider = { [weak self] in
            guard let self = self else { return [] }
            return Set(
                self.dictionaryStore.entries
                    .map(\.term)
                    .filter { term in
                        guard let first = term.first else { return false }
                        return first.isLetter && first.isUppercase
                    }
            )
        }
        activationController?.audioRecorder.asrSelector.onTranscriptionLogged = { [weak self] text, engineID, injected, audioPath, failed, replaceEntryID in
            self?.historyStore.append(
                text: text,
                engine: engineID,
                injected: injected,
                audioPath: audioPath,
                failed: failed,
                replaceEntryID: replaceEntryID
            )
        }

        wireFailureReporting()
        wireHUDMenuBarSync()

        // Subtle start/stop feedback sound, gated on the persisted Settings
        // toggle — read fresh on every call rather than pushed once, so a
        // live Settings change takes effect on the very next recording.
        activationController?.audioRecorder.playDictationSoundProvider = { [weak self] in
            self?.settingsStore.playDictationSound ?? false
        }

        activationController?.audioRecorder.activationKeyLabelProvider = { [weak self] in
            self?.settingsStore.activationKeyOption.hudLabel ?? "fn"
        }

        // Pre-warm the selected local model in the background so the first
        // dictation after launch isn't blocked on a ~3s cold CoreML load.
        // No-op in cloud mode. Runs after applyOnLaunch (cloudModel/selectedModel
        // are set) so it warms the model that will actually be used.
        activationController?.audioRecorder.asrSelector.prewarmSelectedModelIfLocal()

        if !OnboardingStore.isComplete {
            showOnboarding()
        } else {
            openMainWindow()
        }
    }

    /// Orphan files under Contents/ (e.g. merge-install `*.bak`) invalidate the
    /// sealed signature. Updates stay grey and Accessibility often stops
    /// trusting the binary until a clean reinstall.
    private func presentBrokenSignatureAlert() {
        let alert = NSAlert()
        alert.messageText = "Murmur’s app signature is broken"
        alert.informativeText = """
            Extra files were left inside the app bundle (usually from a merge \
            install). Until you reinstall cleanly, Check for Updates stays \
            disabled and text injection can fail.

            Fix: quit Murmur, then run:
            bash scripts/install-local.sh
            """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Window management

    /// Shows (or refocuses) the main window. Called on launch, on Dock icon
    /// click (via `applicationShouldHandleReopen`), and from the "Open Murmur"
    /// menu-bar item.
    private func openMainWindow() {
        mainWindowController.showAndFocus()
    }

    /// Clicking the Dock icon (app running, no visible windows) reopens the
    /// main window instead of doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openMainWindow()
        }
        return true
    }

    /// Closing the window (red button) just hides it — the app keeps running
    /// for global dictation via the menu-bar item / fn tap. Reopen via Dock
    /// click. Cmd-Q / Dock → Quit still fully quit (unaffected by this).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        historyStore.flush()
        dictionaryStore.flush()
        correctionsLog.flush()
        snippetsStore.flush()
        transformsStore.flush()
        scratchpadStore.flush()
    }

    // MARK: - Main Menu

    /// A nib-less AppKit app has no main menu by default, so standard shortcuts
    /// like Cmd-Q don't work. Build a minimal application menu with a Quit item
    /// so the app behaves like a normal Dock app: Cmd-Q (and Dock → Quit) fully
    /// exit it.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About Murmur",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(
            withTitle: "Settings…",
            action: #selector(openSettingsMenuItemClicked),
            keyEquivalent: ","
        ).target = self
        appMenu.addItem(NSMenuItem.separator())
        let updatesEnabled = SparkleSupport.isEnabled && updaterController != nil
        let updateTitle =
            SparkleSupport.status == .brokenSignature
            ? "Check for Updates… (signature broken)"
            : "Check for Updates…"
        let updateItem = appMenu.addItem(
            withTitle: updateTitle,
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = updaterController
        updateItem.isEnabled = updatesEnabled
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Quit Murmur",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        // Standard Edit menu. A nib-less AppKit app has NO Edit menu by
        // default, and the Cut/Copy/Paste/Select-All keyboard shortcuts are
        // dispatched THROUGH those menu items (nil-target actions routed to the
        // first responder). Without them, Cmd-C/V/X/A do nothing in any text
        // field — e.g. pasting an API key into Settings.
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(
                systemSymbolName: "mic",
                accessibilityDescription: "Murmur"
            )
            button.image?.isTemplate = true  // adapts to dark/light menu bar
        }

        let menu = NSMenu()
        menu.addItem(
            withTitle: "Murmur v0.1",
            action: nil,
            keyEquivalent: ""
        ).isEnabled = false
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            withTitle: "Open Murmur",
            action: #selector(openVoiceMenuItemClicked),
            keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: "Settings…",
            action: #selector(openSettingsMenuItemClicked),
            keyEquivalent: ""
        ).target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            withTitle: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        statusItem?.menu = menu
    }

    @objc private func openVoiceMenuItemClicked() {
        openMainWindow()
    }

    @objc private func openSettingsMenuItemClicked() {
        mainWindowController.showSettingsTab()
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        let hosting = NSHostingController(rootView: OnboardingView(onComplete: { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
            self?.openMainWindow()
        }))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Murmur"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 480, height: 340))
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Failure reporting

    private func wireFailureReporting() {
        guard let recorder = activationController?.audioRecorder else { return }
        recorder.asrSelector.onFailure = { [weak self] failure in
            self?.handleDictationFailure(failure)
        }
    }

    private func handleDictationFailure(_ failure: DictationFailure) {
        switch failure {
        case .injectionFailed:
            activationController?.audioRecorder.hud.showClipboardFlashThenHide()
        default:
            activationController?.audioRecorder.hud.showError(failure.message)
            activationController?.audioRecorder.playFailureSound()
            isShowingMenuBarErrorBadge = true
            setMenuBarErrorBadge(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.isShowingMenuBarErrorBadge = false
                self?.setMenuBarErrorBadge(false)
            }
        }
    }

    private func wireHUDMenuBarSync() {
        activationController?.audioRecorder.hud.onStateChange = { [weak self] state in
            self?.updateMenuBarIcon(for: state)
        }
        // hide() is the only reliable "back to idle" signal — reachable from
        // every terminal path (silence, early failures, post-flash) without
        // necessarily passing through a state onStateChange already handles.
        // onHide fires at hide() start (menu-bar idle); LearnToast re-stacks
        // from onLayoutChange after the fade clears isVisible.
        activationController?.audioRecorder.hud.onHide = { [weak self] in
            self?.resetMenuBarIconToIdle()
        }
    }

    private func wireLearnToast() {
        let hud = activationController?.audioRecorder.hud
        learnToast.recordingHUD = hud
        hud?.onLayoutChange = { [weak self] in
            self?.learnToast.reposition()
        }

        let coordinator = LearnEventsCoordinator(
            correctionsLog: correctionsLog,
            dictionaryStore: dictionaryStore,
            learnToast: learnToast
        )
        coordinator.bind()
        learnEventsCoordinator = coordinator
    }

    private func resetMenuBarIconToIdle() {
        // Don't stamp over a live error badge (e.g. H7's click-to-dismiss
        // firing hide() well before the badge's own independent 3s clear) —
        // let setMenuBarErrorBadge(false) own that transition, unchanged.
        guard !isShowingMenuBarErrorBadge, let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Murmur")
        button.image?.isTemplate = true
    }

    private func updateMenuBarIcon(for state: RecordingHUD.State) {
        guard let button = statusItem?.button else { return }
        let imageName: String
        switch state {
        case .listening:
            imageName = "mic.fill"
        case .processing:
            imageName = NSImage(systemSymbolName: "mic.badge.ellipsis", accessibilityDescription: nil) != nil
                ? "mic.badge.ellipsis"
                : "ellipsis.circle"
        case .success, .clipboardFlash:
            imageName = "mic"
        case .error:
            return
        }
        button.image = NSImage(systemSymbolName: imageName, accessibilityDescription: "Murmur")
        button.image?.isTemplate = true
    }

    func replayOnboarding() {
        UserDefaults.standard.set(false, forKey: OnboardingStore.completeKey)
        showOnboarding()
    }

    /// Shows a red badge on the menu-bar mic icon when `show` is true.
    func setMenuBarErrorBadge(_ show: Bool) {
        guard let button = statusItem?.button else { return }
        if show {
            button.image = NSImage(
                systemSymbolName: "mic.badge.xmark",
                accessibilityDescription: "Murmur — error"
            )
            button.image?.isTemplate = true
        } else {
            button.image = NSImage(
                systemSymbolName: "mic",
                accessibilityDescription: "Murmur"
            )
            button.image?.isTemplate = true
        }
    }
}
