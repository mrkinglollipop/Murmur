// PRO ONLY — this file is part of the paid clipboard manager and must never
// merge into `main`. Its target is the `pro` branch, gated behind a Pro
// entitlement check. See the "Clipboard manager" section of CLAUDE.md.

import AppKit
import Carbon
import Foundation
import os.log

/// Watches the general pasteboard and hands new content to `ClipboardStore`.
///
/// macOS publishes no change notification for `NSPasteboard`, so detection is
/// a `changeCount` poll — the same approach every clipboard manager on the
/// platform uses. The steady-state cost is one integer read per tick.
///
/// **This class only ever reads the pasteboard.** That is a deliberate
/// constraint, not an incidental one: `TextInjector` drives dictation through
/// the pasteboard (snapshot → write transcript → ⌘V → restore), and any writer
/// racing it would corrupt an injection. Because the watcher never writes and
/// `TextInjector` never learns the watcher exists, a failure here cannot reach
/// the injection path.
final class ClipboardWatcher {

    private let store: ClipboardStore
    private let pasteboard: NSPasteboard
    private let interval: TimeInterval
    private let secureInputEnabled: () -> Bool
    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "clipboard-watcher")

    private var timer: Timer?
    /// Seeded below any real `changeCount` so the first tick captures whatever
    /// is already on the pasteboard at launch. If that content is unchanged
    /// since last quit it dedupes against the existing top entry.
    private var lastChangeCount = -1

    init(
        store: ClipboardStore,
        pasteboard: NSPasteboard = .general,
        interval: TimeInterval = 0.5,
        secureInputEnabled: @escaping () -> Bool = { IsSecureEventInputEnabled() }
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.interval = interval
        self.secureInputEnabled = secureInputEnabled
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // Common mode so polling continues while a menu is open or a window is
        // being resized — the exact moments a user is likely to be copying.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        logger.info("Clipboard watcher started (interval \(self.interval, format: .fixed(precision: 2))s)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        logger.info("Clipboard watcher stopped")
    }

    /// One poll. Cheap when nothing changed, which is the overwhelming majority
    /// of ticks.
    func tick() {
        // Unprotected copies remain eligible while activation is pending.
        let current = pasteboard.changeCount
        // Consume protected copies so they cannot be captured after unlock.
        let secure = secureInputEnabled()
        store.noteSecureInput(secure)
        guard !secure else {
            lastChangeCount = current
            return
        }
        guard store.canAttemptCapture else { return }
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        let snapshot = TextInjector.pasteboardSnapshot(from: pasteboard)
        guard !snapshot.isEmpty else { return }

        store.record(snapshot: snapshot, sourceBundleID: frontmostBundleID())
    }

    /// Best-effort attribution. Murmur itself is reported as `nil` rather than
    /// as the source: when the user copies an entry out of the clipboard tab,
    /// the frontmost app is us, and labelling their own content "from Murmur"
    /// is noise.
    private func frontmostBundleID() -> String? {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return nil
        }
        return bundleID == Bundle.main.bundleIdentifier ? nil : bundleID
    }

    deinit {
        stop()
    }
}
