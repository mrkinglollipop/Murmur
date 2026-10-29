import AppKit
import CryptoKit
import XCTest
@testable import Voice

/// `ClipboardWatcher` polling behavior, driven against a private pasteboard so
/// tests never read or disturb the user's real clipboard.
///
/// As in `ClipboardStoreTests`, every store is built with an explicit temp
/// directory and an explicit key — the default initializer resolves its key
/// from the real login Keychain.
final class ClipboardWatcherTests: XCTestCase {

    private var pasteboards: [NSPasteboard] = []
    private var tempDirectories: [URL] = []

    override func tearDown() {
        for pasteboard in pasteboards {
            pasteboard.releaseGlobally()
        }
        pasteboards.removeAll()
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.matt.voice-dictation.tests.\(UUID().uuidString)"))
        pasteboards.append(pasteboard)
        return pasteboard
    }

    private func makeStore(activate: Bool = true, fileOperations: ClipboardFileOperations = ClipboardFileOperations()) -> ClipboardStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-watcher-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = ClipboardStore(
            directory: directory,
            crypto: ClipboardCrypto(key: SymmetricKey(size: .bits256)),
            fileOperations: fileOperations
        )
        guard activate else { return store }
        // Capture needs a key, and `activate()` resolves it off the launch
        // path rather than in `init`.
        store.activate()
        XCTAssertTrue(waitUntil { store.isActivated }, "store never activated")
        return store
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 3.0, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    @discardableResult
    private func waitForEntries(
        _ store: ClipboardStore,
        count: Int,
        timeout: TimeInterval = 3.0
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if store.entries.count == count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return store.entries.count == count
    }

    private func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Polling

    func testTickCapturesNewContent() {
        let pasteboard = makePasteboard()
        let store = makeStore()
        let watcher = ClipboardWatcher(store: store, pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("copied text", forType: .string)
        watcher.tick()

        XCTAssertTrue(waitForEntries(store, count: 1))
        XCTAssertEqual(store.entries.first?.preview, "copied text")
        XCTAssertEqual(store.entries.first?.kind, .text)
    }

    func testWatcherRetriesTransientBlobWriteOnNextChange() {
        var writes = 0
        var operations = ClipboardFileOperations()
        operations.write = { data, url in
            if url.deletingLastPathComponent().lastPathComponent == "blobs" {
                writes += 1
                if writes == 1 {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
                }
            }
            try data.write(to: url, options: .atomic)
        }
        let store = makeStore(fileOperations: operations)
        let pasteboard = makePasteboard()
        let watcher = ClipboardWatcher(store: store, pasteboard: pasteboard, secureInputEnabled: { false })
        pasteboard.clearContents()
        pasteboard.setString("failed copy", forType: .string)
        watcher.tick()
        XCTAssertTrue(waitUntil { store.isStorageUnavailable })
        XCTAssertTrue(store.entries.isEmpty)
        watcher.tick()
        settle()
        XCTAssertEqual(writes, 1, "unchanged clipboard must not poll storage retries")
        pasteboard.clearContents()
        pasteboard.setString("successful copy", forType: .string)
        watcher.tick()
        XCTAssertTrue(waitForEntries(store, count: 1))
        store.flush()
        XCTAssertFalse(store.isStorageUnavailable)
        XCTAssertEqual(store.entries.first?.preview, "successful copy")
        XCTAssertEqual(writes, 2)
    }

    func testWatcherRetriesTransientMetadataWriteOnNextChange() {
        var fail = false
        var operations = ClipboardFileOperations()
        operations.write = { data, url in
            if fail && url.lastPathComponent == "clipboard.json" {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            }
            try data.write(to: url, options: .atomic)
        }
        let store = makeStore(fileOperations: operations)
        let pasteboard = makePasteboard()
        let watcher = ClipboardWatcher(store: store, pasteboard: pasteboard, secureInputEnabled: { false })
        pasteboard.clearContents()
        pasteboard.setString("saved copy", forType: .string)
        watcher.tick()
        XCTAssertTrue(waitForEntries(store, count: 1))
        store.flush()
        fail = true
        pasteboard.clearContents()
        pasteboard.setString("unsaved metadata", forType: .string)
        watcher.tick()
        XCTAssertTrue(waitForEntries(store, count: 2))
        store.flush()
        XCTAssertTrue(store.isStorageUnavailable)
        fail = false
        pasteboard.clearContents()
        pasteboard.setString("recovery copy", forType: .string)
        watcher.tick()
        XCTAssertTrue(waitForEntries(store, count: 3))
        store.flush()
        XCTAssertFalse(store.isStorageUnavailable)
        XCTAssertEqual(store.entries.first?.preview, "recovery copy")
    }

    func testWatcherNeverRetriesWhenMetadataCouldNotBeRead() {
        var operations = ClipboardFileOperations()
        operations.read = { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        }
        var writes = 0
        operations.write = { _, _ in writes += 1 }
        let store = makeStore(fileOperations: operations)
        XCTAssertTrue(store.isStorageUnavailable)
        XCTAssertFalse(store.canAttemptCapture)
        let pasteboard = makePasteboard()
        let watcher = ClipboardWatcher(store: store, pasteboard: pasteboard, secureInputEnabled: { false })
        for text in ["first", "second"] {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            watcher.tick()
        }
        settle()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(store.isStorageUnavailable)
    }

    /// The `changeCount` guard is what keeps the steady-state poll to a single
    /// integer read; without it every tick would re-read the whole pasteboard.
    func testUnchangedPasteboardIsNotCapturedTwice() {
        let pasteboard = makePasteboard()
        let store = makeStore()
        let watcher = ClipboardWatcher(store: store, pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("copied once", forType: .string)
        watcher.tick()
        XCTAssertTrue(waitForEntries(store, count: 1))

        watcher.tick()
        watcher.tick()
        settle()
        XCTAssertEqual(store.entries.count, 1)
    }

    func testSubsequentChangeIsCaptured() {
        let pasteboard = makePasteboard()
        let store = makeStore()
        let watcher = ClipboardWatcher(store: store, pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("first", forType: .string)
        watcher.tick()
        XCTAssertTrue(waitForEntries(store, count: 1))

        pasteboard.clearContents()
        pasteboard.setString("second", forType: .string)
        watcher.tick()
        XCTAssertTrue(waitForEntries(store, count: 2))
        XCTAssertEqual(store.entries.first?.preview, "second")
    }

    /// Content already sitting on the pasteboard at launch is real user
    /// content and is captured on the first tick.
    func testFirstTickCapturesPreexistingContent() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("was already there", forType: .string)

        let store = makeStore()
        let watcher = ClipboardWatcher(store: store, pasteboard: pasteboard)
        watcher.tick()

        XCTAssertTrue(waitForEntries(store, count: 1))
        XCTAssertEqual(store.entries.first?.preview, "was already there")
    }

    /// End-to-end version of the store-level filter: what `TextInjector` puts
    /// on the pasteboard for a dictation never reaches the history.
    func testConcealedInjectionWriteIsNotCaptured() {
        let pasteboard = makePasteboard()
        let store = makeStore()
        let watcher = ClipboardWatcher(store: store, pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("dictated sentence", forType: .string)
        pasteboard.setData(Data(), forType: TextInjector.concealedPasteboardType)
        watcher.tick()

        settle()
        XCTAssertTrue(store.entries.isEmpty)
    }

    /// The dictation sequence end to end: user copy, Murmur's concealed
    /// transcript write, then Murmur restoring what the user had copied. Only
    /// the user's own copy may appear, exactly once.
    func testFullDictationCycleLeavesOneEntry() {
        let pasteboard = makePasteboard()
        let store = makeStore()
        let watcher = ClipboardWatcher(store: store, pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("user content", forType: .string)
        watcher.tick()
        XCTAssertTrue(waitForEntries(store, count: 1))

        let saved = TextInjector.pasteboardSnapshot(from: pasteboard)
        TextInjector.preparePasteboardForPaste("dictated sentence", on: pasteboard)
        watcher.tick()
        settle()

        TextInjector.restorePasteboardSnapshot(saved, on: pasteboard)
        watcher.tick()
        settle()

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.preview, "user content")
    }

    /// Content copied while the store is still resolving its key must not be
    /// lost. The tick returns before consuming `changeCount`, so the same
    /// content is picked up on the next tick once activation lands.
    func testContentCopiedBeforeActivationIsNotLost() {
        let pasteboard = makePasteboard()
        let store = makeStore(activate: false)
        let watcher = ClipboardWatcher(store: store, pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("copied during startup", forType: .string)
        watcher.tick()
        settle(0.1)
        XCTAssertTrue(store.entries.isEmpty, "nothing can be captured before activation")

        store.activate()
        XCTAssertTrue(waitUntil { store.isActivated })
        watcher.tick()

        XCTAssertTrue(waitForEntries(store, count: 1), "the copy must survive activation")
        XCTAssertEqual(store.entries.first?.preview, "copied during startup")
    }

    /// With no key the watcher must not consume `changeCount` either — doing so
    /// would discard every copy in silence for the whole session.
    func testWatcherDoesNotConsumeChangeCountWithoutAKey() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-watcher-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = ClipboardStore(directory: directory, cryptoProvider: { nil })
        store.activate()
        XCTAssertTrue(waitUntil { store.isActivated })

        let pasteboard = makePasteboard()
        let watcher = ClipboardWatcher(store: store, pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("no key for this", forType: .string)
        watcher.tick()

        settle()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(store.canCapture)
    }

    func testEmptyPasteboardProducesNoEntry() {
        let pasteboard = makePasteboard()
        let store = makeStore()
        let watcher = ClipboardWatcher(store: store, pasteboard: pasteboard)

        pasteboard.clearContents()
        watcher.tick()

        settle()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testSecureInputCopyIsSkippedEvenAfterSecureInputEnds() {
        let pasteboard = makePasteboard()
        let store = makeStore()
        var secure = true
        let watcher = ClipboardWatcher(store: store, pasteboard: pasteboard, secureInputEnabled: { secure })
        pasteboard.clearContents()
        pasteboard.setString("protected secret", forType: .string)
        watcher.tick()
        settle()
        XCTAssertTrue(store.entries.isEmpty)
        secure = false
        watcher.tick()
        settle()
        XCTAssertTrue(store.entries.isEmpty, "protected content must not be captured on the next unlocked tick")
        pasteboard.clearContents()
        pasteboard.setString("ordinary copy", forType: .string)
        watcher.tick()
        XCTAssertTrue(waitForEntries(store, count: 1))
        XCTAssertEqual(store.entries.first?.preview, "ordinary copy")
    }

    func testSecureInputCopyDuringActivationIsNotCapturedAfterUnlock() {
        let pasteboard = makePasteboard()
        let store = makeStore(activate: false)
        var secure = true
        let watcher = ClipboardWatcher(store: store, pasteboard: pasteboard, secureInputEnabled: { secure })
        pasteboard.clearContents()
        pasteboard.setString("startup secret", forType: .string)
        watcher.tick()
        secure = false
        store.activate()
        XCTAssertTrue(waitUntil { store.isActivated })
        watcher.tick()
        settle()
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - Lifecycle

    func testStartAndStopToggleRunningState() {
        let store = makeStore()
        let watcher = ClipboardWatcher(store: store, pasteboard: makePasteboard())
        XCTAssertFalse(watcher.isRunning)
        watcher.start()
        XCTAssertTrue(watcher.isRunning)
        watcher.stop()
        XCTAssertFalse(watcher.isRunning)
    }

    func testStartIsIdempotent() {
        let store = makeStore()
        let watcher = ClipboardWatcher(store: store, pasteboard: makePasteboard())
        watcher.start()
        watcher.start()
        XCTAssertTrue(watcher.isRunning)
        watcher.stop()
        XCTAssertFalse(watcher.isRunning)
    }

    /// The timer must actually fire — a watcher that only works when `tick` is
    /// called by hand would pass every other test in this file.
    func testTimerCapturesWithoutManualTick() {
        let pasteboard = makePasteboard()
        let store = makeStore()
        let watcher = ClipboardWatcher(store: store, pasteboard: pasteboard, interval: 0.05)
        watcher.start()
        defer { watcher.stop() }

        pasteboard.clearContents()
        pasteboard.setString("polled automatically", forType: .string)

        XCTAssertTrue(waitForEntries(store, count: 1))
        XCTAssertEqual(store.entries.first?.preview, "polled automatically")
    }

    func testSecureInputStateIsSurfacedAndClears() {
        let pasteboard = makePasteboard()
        let store = makeStore()
        var secure = true
        let watcher = ClipboardWatcher(store: store, pasteboard: pasteboard, secureInputEnabled: { secure })
        pasteboard.clearContents()
        pasteboard.setString("hidden", forType: .string)
        watcher.tick()
        XCTAssertTrue(store.isSecureInputActive)
        XCTAssertTrue(store.entries.isEmpty)
        secure = false
        watcher.tick()
        XCTAssertFalse(store.isSecureInputActive)
    }

    // MARK: - Opt-in setting

    @MainActor
    func testClipboardHistoryDefaultsOffAndPersists() throws {
        let suite = "murmur.clipboard.optin.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = KeychainStore(service: "com.matt.voice-dictation.apikeys.TESTS.\(UUID().uuidString)")
        let settings = SettingsStore(defaults: defaults, keychain: keychain, apiKeyLookup: { _ in nil })
        XCTAssertFalse(settings.clipboardHistoryEnabled)

        settings.clipboardHistoryEnabled = true
        let reloaded = SettingsStore(defaults: defaults, keychain: keychain, apiKeyLookup: { _ in nil })
        XCTAssertTrue(reloaded.clipboardHistoryEnabled)
    }

    func testDisabledDoesNotStartActivateOrCapture() {
        let pasteboard = makePasteboard()
        let store = makeStore(activate: false)
        let watcher = ClipboardWatcher(store: store, pasteboard: pasteboard, interval: 0.05)
        watcher.setCaptureEnabled(false)
        pasteboard.clearContents()
        pasteboard.setString("must not be saved", forType: .string)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(watcher.isRunning)
        XCTAssertFalse(store.isActivated, "off must not do Keychain/disk activation")
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testTogglingStartsAndStopsCaptureImmediately() {
        let pasteboard = makePasteboard()
        let store = makeStore(activate: false)
        let watcher = ClipboardWatcher(store: store, pasteboard: pasteboard, interval: 0.05)

        // Copied before opting in: never saved.
        pasteboard.clearContents()
        pasteboard.setString("before opt-in", forType: .string)

        watcher.setCaptureEnabled(true)
        XCTAssertTrue(watcher.isRunning)
        XCTAssertTrue(waitUntil { store.isActivated }, "on activates the store")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(store.entries.isEmpty, "pre-opt-in clipboard content is not captured")

        pasteboard.clearContents()
        pasteboard.setString("after opt-in", forType: .string)
        XCTAssertTrue(waitForEntries(store, count: 1))

        watcher.setCaptureEnabled(false)
        XCTAssertFalse(watcher.isRunning)
        pasteboard.clearContents()
        pasteboard.setString("while off", forType: .string)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(store.entries.count, 1, "off stops capture; saved history is untouched")
    }
}
