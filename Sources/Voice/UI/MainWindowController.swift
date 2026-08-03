import AppKit
import SwiftUI

/// Owns the single main application window, hosting the SwiftUI `RootView`
/// via `NSHostingController`. The app's lifecycle, menu bar, and HUD stay
/// AppKit — this controller is purely the window layer.
final class MainWindowController: NSWindowController {

    private static let autosaveName = "VoiceMainWindow"

    convenience init(
        historyStore: HistoryStore,
        dictionaryStore: DictionaryStore,
        snippetsStore: SnippetsStore,
        styleStore: StyleStore,
        transformsStore: TransformsStore,
        scratchpadStore: ScratchpadStore,
        settingsStore: SettingsStore,
        modelManager: ModelManager,
        openAIKeyProvider: @escaping () -> String?,
        asrEngineSelector: @escaping () -> ASREngineSelector?,
        onReplayOnboarding: @escaping () -> Void
    ) {
        let rootView = RootView(
            historyStore: historyStore,
            dictionaryStore: dictionaryStore,
            snippetsStore: snippetsStore,
            styleStore: styleStore,
            transformsStore: transformsStore,
            scratchpadStore: scratchpadStore,
            settingsStore: settingsStore,
            modelManager: modelManager,
            openAIKeyProvider: openAIKeyProvider,
            asrEngineSelector: asrEngineSelector,
            onReplayOnboarding: onReplayOnboarding
        )
        let hosting = NSHostingController(rootView: rootView)

        let window = NSWindow(contentViewController: hosting)
        // title stays set (Mission Control / accessibility still need it)
        // even though titleVisibility hides it from the chrome itself.
        window.title = "Murmur"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 760, height: 540))
        window.minSize = NSSize(width: 640, height: 460)
        window.setFrameAutosaveName(MainWindowController.autosaveName)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        // The window uses a fixed dark Liquid Glass palette (dark-first by
        // design, not auto-switching — see plans/015-briefs/mockup-v3.html),
        // so pin it to the darkAqua appearance. Otherwise, on a Mac in light
        // mode, system-default controls (e.g. radio-group picker labels
        // using Color.primary) render dark-on-dark against the fixed
        // near-black background and become illegible.
        window.appearance = NSAppearance(named: .darkAqua)

        self.init(window: window)
    }

    /// Shows the window and brings it (and the app) to the front. Used both
    /// on launch and when reopening via Dock click / menu item.
    func showAndFocus() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Opens the main window on the Settings tab.
    func showSettingsTab() {
        showAndFocus()
        NotificationCenter.default.post(
            name: .murmurSelectTab,
            object: nil,
            userInfo: ["tab": RootTab.settings.rawValue]
        )
    }
}
