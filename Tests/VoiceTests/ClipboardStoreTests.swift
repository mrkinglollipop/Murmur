import AppKit
import CryptoKit
import XCTest
@testable import Voice

/// Clipboard manager capture, dedupe, encryption, and retention.
///
/// Every store here is built with an explicit temp directory AND an explicit
/// key. Neither may be defaulted: the default initializer resolves its key
/// from the real login Keychain, and a test suite that writes production
/// Keychain items destroyed the user's live xAI API key on 2026-07-09.
final class ClipboardStoreTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-clipboard-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDirectories.append(url)
        return url
    }

    private func makeStore(
        directory: URL? = nil,
        maxBytes: Int = 1_000_000_000,
        maxEntries: Int = 2000,
        maxItemBytes: Int = 50_000_000
    ) -> ClipboardStore {
        activated(ClipboardStore(
            directory: directory ?? tempDirectory(),
            crypto: ClipboardCrypto(key: SymmetricKey(size: .bits256)),
            maxBytes: maxBytes,
            maxEntries: maxEntries,
            maxItemBytes: maxItemBytes
        ))
    }

    /// Key resolution, the lockout probe, retention, and reconciliation all
    /// run in `activate()` rather than `init` — it does Keychain and disk work
    /// that must stay off the launch path. Nothing is captured until it lands.
    @discardableResult
    private func activated(_ store: ClipboardStore) -> ClipboardStore {
        store.activate()
        XCTAssertTrue(waitUntil { store.isActivated }, "store never activated")
        return store
    }

    private func textSnapshot(_ text: String) -> TextInjector.PasteboardSnapshot {
        [[.string: Data(text.utf8)]]
    }

    /// What `TextInjector` puts on the pasteboard for a dictation: the
    /// transcript plus the concealed marker.
    private func injectionSnapshot(_ text: String) -> TextInjector.PasteboardSnapshot {
        [[.string: Data(text.utf8), TextInjector.concealedPasteboardType: Data()]]
    }

    /// Spins the run loop until `store.entries.count == count`, or the timeout
    /// expires. `record` seals and writes its blob off the main thread, so the
    /// entry appears asynchronously.
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

    /// Spins the run loop until `condition` holds. Required wherever the entry
    /// count is unchanged by the record being awaited — at the retention cap an
    /// insert is immediately followed by a prune, so a count-based wait returns
    /// before the new entry exists and asserts against the previous state.
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 3.0,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// Lets any pending async work land when the assertion is that *nothing*
    /// was added — waiting for a count that never arrives would just stall.
    private func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - The TextInjector coexistence guard

    /// The load-bearing test for this whole feature.
    ///
    /// `TextInjector` finishes a dictation by restoring the pasteboard it
    /// snapshotted beforehand. That restore is a real `changeCount` bump
    /// carrying content the watcher already logged, so without dedupe against
    /// the newest entry the history would gain a duplicate on every dictation.
    func testPasteboardRestoreDoesNotDuplicateNewestEntry() {
        let store = makeStore()
        store.record(snapshot: textSnapshot("user copied this"), sourceBundleID: "com.apple.Safari")
        XCTAssertTrue(waitForEntries(store, count: 1))

        // TextInjector.restorePasteboardSnapshot rewrites the same content.
        store.record(snapshot: textSnapshot("user copied this"), sourceBundleID: nil)
        settle()

        XCTAssertEqual(store.entries.count, 1, "restore must not create a second entry")
    }

    /// Murmur's own transcript write carries `org.nspasteboard.ConcealedType`,
    /// so it is filtered before it can reach the history.
    func testConcealedInjectionWriteIsNotCaptured() {
        let store = makeStore()
        store.record(snapshot: injectionSnapshot("dictated sentence"), sourceBundleID: nil)
        settle()
        XCTAssertTrue(store.entries.isEmpty)
    }

    /// Re-copying older content is not a duplicate — it moves to the top. Only
    /// a repeat of the *newest* entry is suppressed.
    func testRecopyingOlderContentIsCaptured() {
        let store = makeStore()
        store.record(snapshot: textSnapshot("first"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        store.record(snapshot: textSnapshot("second"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 2))
        store.record(snapshot: textSnapshot("first"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 3))
        XCTAssertEqual(store.entries.first?.preview, "first")
    }

    // MARK: - Fingerprint

    /// Writing items back to the pasteboard can make macOS synthesize extra
    /// representations, so identity must key on the canonical payload only. If
    /// this regresses, the restore-dedupe above silently stops working.
    func testFingerprintIgnoresAdditionalRepresentations() {
        let plain: TextInjector.PasteboardSnapshot = [[.string: Data("hello".utf8)]]
        let promoted: TextInjector.PasteboardSnapshot = [[
            .string: Data("hello".utf8),
            .rtf: Data("{\\rtf1 hello}".utf8),
            NSPasteboard.PasteboardType("public.utf16-external-plain-text"): Data("hello".utf8)
        ]]
        XCTAssertEqual(
            ClipboardFingerprint.fingerprint(for: plain),
            ClipboardFingerprint.fingerprint(for: promoted)
        )
    }

    func testFingerprintDistinguishesDifferentContent() {
        XCTAssertNotEqual(
            ClipboardFingerprint.fingerprint(for: textSnapshot("a")),
            ClipboardFingerprint.fingerprint(for: textSnapshot("b"))
        )
    }

    func testFingerprintFramesCanonicalPayloadsPerItem() {
        let first: TextInjector.PasteboardSnapshot = [
            [.string: Data("ab".utf8)], [.string: Data("c".utf8)]
        ]
        let second: TextInjector.PasteboardSnapshot = [
            [.string: Data("a".utf8)], [.string: Data("bc".utf8)]
        ]
        XCTAssertNotEqual(
            ClipboardFingerprint.fingerprint(for: first),
            ClipboardFingerprint.fingerprint(for: second)
        )
    }

    // MARK: - Encryption and round-trip

    func testPayloadRoundTripPreservesEveryRepresentation() {
        let store = makeStore()
        let snapshot: TextInjector.PasteboardSnapshot = [[
            .string: Data("rich content".utf8),
            .rtf: Data("{\\rtf1 rich content}".utf8),
            .html: Data("<p>rich content</p>".utf8)
        ]]
        store.record(snapshot: snapshot, sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))

        guard let entry = store.entries.first,
              let restored = store.payload(for: entry) else {
            return XCTFail("payload missing")
        }
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0][.string], Data("rich content".utf8))
        XCTAssertEqual(restored[0][.rtf], Data("{\\rtf1 rich content}".utf8))
        XCTAssertEqual(restored[0][.html], Data("<p>rich content</p>".utf8))
    }

    func testBlobOnDiskIsNotPlaintext() {
        let directory = tempDirectory()
        let store = makeStore(directory: directory)
        store.record(snapshot: textSnapshot("SUPERSECRETVALUE"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))

        guard let entry = store.entries.first else { return XCTFail("no entry") }
        let blob = directory.appendingPathComponent("blobs").appendingPathComponent(entry.id.uuidString)
        guard let bytes = try? Data(contentsOf: blob) else { return XCTFail("no blob written") }
        XCTAssertFalse(
            bytes.range(of: Data("SUPERSECRETVALUE".utf8)) != nil,
            "clipboard payload must not be readable on disk"
        )
    }

    /// A store whose key does not open the existing blobs must report lockout,
    /// not present a history where every item silently fails to open.
    ///
    /// This is the regression guard for the defect that shipped green in the
    /// first pass: lockout was inferred from a missing Keychain item, but a
    /// missing item causes a *fresh key to be minted*, so the store always
    /// believed it was fine. Detection is now an actual decrypt attempt.
    func testWrongKeyReportsLockout() {
        let directory = tempDirectory()
        let store = makeStore(directory: directory)
        store.record(snapshot: textSnapshot("locked away"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        store.flush()

        let other = activated(ClipboardStore(
            directory: directory,
            crypto: ClipboardCrypto(key: SymmetricKey(size: .bits256))
        ))
        XCTAssertEqual(other.entries.count, 1, "metadata still loads")
        XCTAssertTrue(other.isLockedOut, "a key that cannot open the blobs must report lockout")
        guard let entry = other.entries.first else { return XCTFail("no entry") }
        XCTAssertNil(other.payload(for: entry), "a foreign key must not open the blob")
    }

    func testCorrectKeyDoesNotReportLockout() {
        let directory = tempDirectory()
        let key = SymmetricKey(size: .bits256)
        let store = activated(ClipboardStore(directory: directory, crypto: ClipboardCrypto(key: key)))
        store.record(snapshot: textSnapshot("readable"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        store.flush()

        let reopened = activated(ClipboardStore(directory: directory, crypto: ClipboardCrypto(key: key)))
        XCTAssertFalse(reopened.isLockedOut)
    }

    func testFreshStoreIsNotLockedOut() {
        XCTAssertFalse(makeStore().isLockedOut)
    }

    /// Nothing is captured before the key is resolved, so the wiring that
    /// starts the watcher has to wait on this.
    func testStoreDoesNotCaptureBeforeActivation() {
        let store = ClipboardStore(
            directory: tempDirectory(),
            crypto: ClipboardCrypto(key: SymmetricKey(size: .bits256))
        )
        XCTAssertFalse(store.isActivated)
        store.record(snapshot: textSnapshot("too early"), sourceBundleID: nil)
        settle()
        XCTAssertTrue(store.entries.isEmpty)

        activated(store)
        store.record(snapshot: textSnapshot("now fine"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
    }

    /// A Keychain that refuses to hand over or mint a key must be visible, not
    /// look identical to a working empty history while every copy is discarded.
    func testKeyUnavailableIsReportedAndBlocksCapture() {
        let store = ClipboardStore(
            directory: tempDirectory(),
            cryptoProvider: { nil }
        )
        activated(store)

        XCTAssertTrue(store.isKeyUnavailable)
        XCTAssertFalse(store.canCapture)
        XCTAssertFalse(store.isLockedOut, "no key is not the same as the wrong key")

        store.record(snapshot: textSnapshot("nowhere to go"), sourceBundleID: nil)
        settle()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testWorkingStoreCanCapture() {
        let store = makeStore()
        XCTAssertTrue(store.canCapture)
        XCTAssertFalse(store.isKeyUnavailable)
    }

    /// A second `activate()` would mean a second Keychain resolution and a
    /// second reconciliation pass.
    func testActivateIsIdempotent() {
        let store = makeStore()
        store.record(snapshot: textSnapshot("kept"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))

        store.activate()
        store.activate()
        settle()

        XCTAssertTrue(store.isActivated)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertFalse(store.isLockedOut)
    }

    func testClearAllResetsLockout() {
        let directory = tempDirectory()
        let store = makeStore(directory: directory)
        store.record(snapshot: textSnapshot("locked away"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        store.flush()

        let other = activated(ClipboardStore(
            directory: directory,
            crypto: ClipboardCrypto(key: SymmetricKey(size: .bits256))
        ))
        XCTAssertTrue(other.isLockedOut)
        other.clearAll()
        XCTAssertFalse(other.isLockedOut)
        XCTAssertTrue(other.entries.isEmpty)
    }

    // MARK: - Reconciliation

    /// A blob write lands immediately; its metadata save is debounced. A quit
    /// in between orphans the blob, and nothing else would ever collect it —
    /// the retention budget only counts bytes it has metadata for.
    func testOrphanedBlobIsDeletedOnLoad() {
        let directory = tempDirectory()
        let blobs = directory.appendingPathComponent("blobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let orphan = blobs.appendingPathComponent(UUID().uuidString)
        try? Data("orphaned bytes".utf8).write(to: orphan)

        // Must stay alive: reconciliation runs asynchronously and holds only a
        // weak reference, so a discarded store never collects anything.
        let store = makeStore(directory: directory)

        let deadline = Date().addingTimeInterval(2.0)
        while FileManager.default.fileExists(atPath: orphan.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphan.path),
            "a blob with no metadata row must be collected"
        )
        XCTAssertTrue(store.entries.isEmpty)
    }

    /// The other direction: metadata rows whose blob is gone are dead weight
    /// in the list and would fail to open if clicked.
    func testEntryWithMissingBlobIsDropped() {
        let directory = tempDirectory()
        let key = SymmetricKey(size: .bits256)
        let store = activated(ClipboardStore(directory: directory, crypto: ClipboardCrypto(key: key)))
        store.record(snapshot: textSnapshot("will lose its blob"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        store.flush()
        guard let entry = store.entries.first else { return XCTFail("no entry") }
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("blobs").appendingPathComponent(entry.id.uuidString)
        )

        let reopened = activated(ClipboardStore(directory: directory, crypto: ClipboardCrypto(key: key)))
        XCTAssertTrue(waitUntil { reopened.entries.isEmpty })
        XCTAssertFalse(reopened.isLockedOut, "a missing blob is not a key failure")
    }

    // MARK: - Dedupe across the async write

    /// `record` inserts only after the seal-and-write returns, so a second
    /// identical copy arriving before that would pass the newest-entry check.
    func testDuplicateWhileWriteInFlightIsSuppressed() {
        let store = makeStore()
        store.record(snapshot: textSnapshot("double tapped"), sourceBundleID: nil)
        // Same main-thread turn: the first blob write cannot have completed.
        store.record(snapshot: textSnapshot("double tapped"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        settle()
        XCTAssertEqual(store.entries.count, 1)
    }

    // MARK: - Images

    private func pngData(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }

    func testImageDimensionsComeFromMetadata() {
        let data = pngData(width: 320, height: 200)
        let size = ClipboardCapture.imageDimensions(from: data)
        XCTAssertEqual(size?.width, 320)
        XCTAssertEqual(size?.height, 200)
    }

    func testImageDimensionsReturnsNilForNonImage() {
        XCTAssertNil(ClipboardCapture.imageDimensions(from: Data("not an image".utf8)))
    }

    func testImageCaptureRoundTripsAndPreviewsDimensions() {
        let store = makeStore()
        let data = pngData(width: 64, height: 48)
        store.record(snapshot: [[.png: data]], sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))

        guard let entry = store.entries.first else { return XCTFail("no entry") }
        XCTAssertEqual(entry.kind, .image)
        XCTAssertEqual(entry.preview, "Image · 64×48")
        XCTAssertEqual(store.payload(for: entry)?.first?[.png], data)
    }

    // MARK: - Oversized copies

    /// A copy too large to store must be reported, not silently discarded —
    /// otherwise it reads to the user as lost data.
    func testOversizedCopyIsReported() {
        let store = makeStore(maxItemBytes: 1_000)
        XCTAssertNil(store.lastOversizedSkip)

        store.record(snapshot: [[.png: Data(repeating: 0x7, count: 5_000)]], sourceBundleID: nil)
        settle()

        XCTAssertTrue(store.entries.isEmpty, "it must still not be stored")
        XCTAssertEqual(store.lastOversizedSkip?.byteCount, 5_000)
        XCTAssertEqual(store.lastOversizedSkip?.limit, 1_000)
    }

    func testOversizedSkipCanBeDismissed() {
        let store = makeStore(maxItemBytes: 1_000)
        store.record(snapshot: [[.png: Data(repeating: 0x7, count: 5_000)]], sourceBundleID: nil)
        settle()
        XCTAssertNotNil(store.lastOversizedSkip)

        store.dismissOversizedSkip()
        XCTAssertNil(store.lastOversizedSkip)
    }

    /// The cap sums every representation, which is what makes screen grabs hit
    /// it: macOS puts TIFF and PNG on the pasteboard together.
    func testCapCountsEveryRepresentationTogether() {
        let store = makeStore(maxItemBytes: 1_000)
        store.record(
            snapshot: [[
                .tiff: Data(repeating: 0x1, count: 600),
                .png: Data(repeating: 0x2, count: 600)
            ]],
            sourceBundleID: nil
        )
        settle()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.lastOversizedSkip?.byteCount, 1_200)
    }

    func testNormalCopyLeavesNoSkipReport() {
        let store = makeStore()
        store.record(snapshot: textSnapshot("small enough"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        XCTAssertNil(store.lastOversizedSkip)
    }

    // MARK: - Thumbnails

    func testImageEntryGetsAThumbnail() {
        let store = makeStore()
        store.record(snapshot: [[.png: pngData(width: 900, height: 600)]], sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        guard let entry = store.entries.first else { return XCTFail("no entry") }

        XCTAssertTrue(waitUntil { store.thumbnail(for: entry) != nil }, "no thumbnail written")
        guard let data = store.thumbnail(for: entry), let image = NSImage(data: data) else {
            return XCTFail("thumbnail unreadable")
        }
        XCTAssertLessThanOrEqual(
            Int(max(image.size.width, image.size.height)),
            ClipboardCapture.thumbnailMaxPixelSize,
            "thumbnail must be downscaled, not a copy of the original"
        )
    }

    func testTextEntryHasNoThumbnail() {
        let store = makeStore()
        store.record(snapshot: textSnapshot("just words"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        guard let entry = store.entries.first else { return XCTFail("no entry") }
        XCTAssertNil(store.thumbnail(for: entry))
    }

    func testThumbnailIsEncryptedOnDisk() {
        let directory = tempDirectory()
        let store = makeStore(directory: directory)
        store.record(snapshot: [[.png: pngData(width: 200, height: 200)]], sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        guard let entry = store.entries.first else { return XCTFail("no entry") }

        let path = directory.appendingPathComponent("thumbs").appendingPathComponent(entry.id.uuidString)
        XCTAssertTrue(waitUntil { FileManager.default.fileExists(atPath: path.path) })
        guard let bytes = try? Data(contentsOf: path) else { return XCTFail("no thumb file") }
        // A stored PNG would start with the PNG signature; a sealed one cannot.
        XCTAssertNotEqual(bytes.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }

    func testDeletingAnEntryRemovesItsThumbnail() {
        let directory = tempDirectory()
        let store = makeStore(directory: directory)
        store.record(snapshot: [[.png: pngData(width: 200, height: 200)]], sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        guard let entry = store.entries.first else { return XCTFail("no entry") }
        let path = directory.appendingPathComponent("thumbs").appendingPathComponent(entry.id.uuidString)
        XCTAssertTrue(waitUntil { FileManager.default.fileExists(atPath: path.path) })

        store.delete(entry)
        XCTAssertTrue(
            waitUntil { !FileManager.default.fileExists(atPath: path.path) },
            "thumbnail must not outlive its entry"
        )
    }

    func testOrphanedThumbnailIsCollectedOnLoad() {
        let directory = tempDirectory()
        let thumbs = directory.appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        let orphan = thumbs.appendingPathComponent(UUID().uuidString)
        try? Data("orphan thumb".utf8).write(to: orphan)

        let store = makeStore(directory: directory)
        XCTAssertTrue(waitUntil { !FileManager.default.fileExists(atPath: orphan.path) })
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testMakeThumbnailReturnsNilForNonImage() {
        XCTAssertNil(ClipboardCapture.makeThumbnail(from: Data("not an image".utf8)))
    }

    // MARK: - Fingerprint determinism

    /// Ties must break on the type identifier. Dictionary iteration order is
    /// seeded per process, so a tie resolved by iteration order yields a
    /// different persisted fingerprint between launches.
    func testCanonicalPayloadBreaksTiesOnTypeIdentifier() {
        let item: [NSPasteboard.PasteboardType: Data] = [
            NSPasteboard.PasteboardType("zzz.type"): Data([0x01, 0x02, 0x03, 0x04]),
            NSPasteboard.PasteboardType("aaa.type"): Data([0x09, 0x09, 0x09, 0x09])
        ]
        // Equal sizes: the higher type identifier wins, every time.
        for _ in 0..<50 {
            XCTAssertEqual(
                ClipboardFingerprint.canonicalPayload(of: item),
                Data([0x01, 0x02, 0x03, 0x04])
            )
        }
    }

    func testCanonicalPayloadPrefersPlainText() {
        let item: [NSPasteboard.PasteboardType: Data] = [
            .string: Data("short".utf8),
            .rtf: Data(repeating: 0x20, count: 4096)
        ]
        XCTAssertEqual(ClipboardFingerprint.canonicalPayload(of: item), Data("short".utf8))
    }

    // MARK: - Putting an entry back on the pasteboard

    /// The feature's primary user action: click an entry, get it back exactly
    /// as it was copied — every representation, not just the plain text.
    func testCopyToPasteboardRestoresEveryRepresentation() {
        let store = makeStore()
        let snapshot: TextInjector.PasteboardSnapshot = [[
            .string: Data("styled text".utf8),
            .rtf: Data("{\\rtf1 styled text}".utf8)
        ]]
        store.record(snapshot: snapshot, sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        guard let entry = store.entries.first else { return XCTFail("no entry") }

        let target = NSPasteboard(name: NSPasteboard.Name("com.matt.voice-dictation.tests.\(UUID().uuidString)"))
        defer { target.releaseGlobally() }

        XCTAssertTrue(store.copyToPasteboard(entry, to: target))
        XCTAssertEqual(target.string(forType: .string), "styled text")
        XCTAssertEqual(target.data(forType: .rtf), Data("{\\rtf1 styled text}".utf8))
    }

    func testCopyToPasteboardRestoresImageBytes() {
        let store = makeStore()
        let data = pngData(width: 12, height: 9)
        store.record(snapshot: [[.png: data]], sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        guard let entry = store.entries.first else { return XCTFail("no entry") }

        let target = NSPasteboard(name: NSPasteboard.Name("com.matt.voice-dictation.tests.\(UUID().uuidString)"))
        defer { target.releaseGlobally() }

        XCTAssertTrue(store.copyToPasteboard(entry, to: target))
        XCTAssertEqual(target.data(forType: .png), data)
    }

    /// An entry whose blob is unreadable must report failure rather than
    /// silently clearing the user's clipboard.
    func testCopyToPasteboardFailsWhenBlobIsUnreadable() {
        let directory = tempDirectory()
        let store = makeStore(directory: directory)
        store.record(snapshot: textSnapshot("about to vanish"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        guard let entry = store.entries.first else { return XCTFail("no entry") }
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("blobs").appendingPathComponent(entry.id.uuidString)
        )

        let target = NSPasteboard(name: NSPasteboard.Name("com.matt.voice-dictation.tests.\(UUID().uuidString)"))
        defer { target.releaseGlobally() }
        target.clearContents()
        target.setString("existing clipboard", forType: .string)

        XCTAssertFalse(store.copyToPasteboard(entry, to: target))
        XCTAssertEqual(
            target.string(forType: .string),
            "existing clipboard",
            "a failed restore must leave the clipboard alone"
        )
    }

    // MARK: - Retention

    func testCountCapPrunesOldestAndDeletesItsBlob() {
        let directory = tempDirectory()
        let store = makeStore(directory: directory, maxEntries: 2)
        store.record(snapshot: textSnapshot("oldest"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        guard let oldest = store.entries.first else { return XCTFail("no entry") }
        let oldestBlob = directory.appendingPathComponent("blobs").appendingPathComponent(oldest.id.uuidString)

        store.record(snapshot: textSnapshot("middle"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 2))
        store.record(snapshot: textSnapshot("newest"), sourceBundleID: nil)
        XCTAssertTrue(waitUntil { store.entries.first?.preview == "newest" })

        XCTAssertEqual(store.entries.map(\.preview), ["newest", "middle"])

        let deadline = Date().addingTimeInterval(2.0)
        while FileManager.default.fileExists(atPath: oldestBlob.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: oldestBlob.path),
            "pruned entry's blob must be deleted, not orphaned"
        )
    }

    func testOversizedItemIsSkipped() {
        let store = makeStore(maxItemBytes: 1024)
        let big = Data(repeating: 0x41, count: 4096)
        store.record(snapshot: [[.string: big]], sourceBundleID: nil)
        settle()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testEmptySnapshotIsSkipped() {
        let store = makeStore()
        store.record(snapshot: [], sourceBundleID: nil)
        settle()
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - Persistence

    func testMetadataSurvivesReload() {
        let directory = tempDirectory()
        let key = SymmetricKey(size: .bits256)
        let store = activated(ClipboardStore(directory: directory, crypto: ClipboardCrypto(key: key)))
        store.record(snapshot: textSnapshot("persisted"), sourceBundleID: "com.apple.Safari")
        XCTAssertTrue(waitForEntries(store, count: 1))
        store.flush()

        let reloaded = activated(ClipboardStore(directory: directory, crypto: ClipboardCrypto(key: key)))
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.preview, "persisted")
        XCTAssertEqual(reloaded.entries.first?.sourceBundleID, "com.apple.Safari")
        guard let entry = reloaded.entries.first else { return XCTFail("no entry") }
        XCTAssertEqual(reloaded.payload(for: entry)?.first?[.string], Data("persisted".utf8))
    }

    func testFlushPersistsCompletedBlobWhoseMainInsertIsStillQueued() {
        let directory = tempDirectory()
        let key = SymmetricKey(size: .bits256)
        let store = activated(ClipboardStore(directory: directory, crypto: ClipboardCrypto(key: key)))
        store.record(snapshot: textSnapshot("must survive quit"), sourceBundleID: nil)
        store.flush()

        let reloaded = activated(ClipboardStore(directory: directory, crypto: ClipboardCrypto(key: key)))
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.preview, "must survive quit")
    }

    func testCorruptMetadataPreservesRecoverableBlobsWithoutReconciliation() throws {
        let directory = tempDirectory()
        let key = SymmetricKey(size: .bits256)
        let store = activated(ClipboardStore(directory: directory, crypto: ClipboardCrypto(key: key)))
        store.record(snapshot: textSnapshot("recoverable"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        let entry = try XCTUnwrap(store.entries.first)
        store.flush()
        let blob = directory.appendingPathComponent("blobs").appendingPathComponent(entry.id.uuidString)

        try Data("{ malformed".utf8).write(to: directory.appendingPathComponent("clipboard.json"))
        let reopened = activated(ClipboardStore(directory: directory, crypto: ClipboardCrypto(key: key)))
        settle()

        XCTAssertTrue(reopened.entries.isEmpty)
        XCTAssertTrue(reopened.isMetadataCorrupt)
        XCTAssertFalse(reopened.canCapture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob.path))
        reopened.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("clipboard.json").path))

        // The quarantine marker survives a second launch, preventing a later
        // clean-looking empty metadata load from deleting recoverable blobs.
        let relaunched = activated(ClipboardStore(directory: directory, crypto: ClipboardCrypto(key: key)))
        settle()
        XCTAssertTrue(relaunched.isMetadataCorrupt)
        XCTAssertFalse(relaunched.canCapture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob.path))
    }

    func testExplicitCorruptHistoryDiscardDeletesFilesAndRestoresCapture() throws {
        let directory = tempDirectory()
        let key = SymmetricKey(size: .bits256)
        let store = activated(ClipboardStore(directory: directory, crypto: ClipboardCrypto(key: key)))
        store.record(snapshot: textSnapshot("recover only after confirmation"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        let entry = try XCTUnwrap(store.entries.first)
        store.flush()
        let blob = directory.appendingPathComponent("blobs").appendingPathComponent(entry.id.uuidString)
        try Data("{ malformed".utf8).write(to: directory.appendingPathComponent("clipboard.json"))

        let reopened = activated(ClipboardStore(directory: directory, crypto: ClipboardCrypto(key: key)))
        XCTAssertTrue(reopened.isMetadataCorrupt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob.path))

        reopened.discardCorruptHistory()
        XCTAssertTrue(waitUntil { !reopened.isMetadataCorrupt })
        XCTAssertTrue(reopened.canCapture)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blob.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("clipboard.json").path))
    }

    func testCorruptHistoryDiscardRetainsQuarantineWhenBlobEnumerationFails() throws {
        let directory = tempDirectory()
        try Data("{ malformed".utf8).write(to: directory.appendingPathComponent("clipboard.json"))
        // An existing non-directory at this path makes enumeration fail. The
        // recovery must not translate that unknown result into "empty."
        try Data("not a directory".utf8).write(to: directory.appendingPathComponent("blobs"))
        let marker = directory.appendingPathComponent("clipboard.json.quarantine")
        let store = activated(ClipboardStore(
            directory: directory,
            crypto: ClipboardCrypto(key: SymmetricKey(size: .bits256))
        ))
        XCTAssertTrue(store.isMetadataCorrupt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        store.discardCorruptHistory()
        settle()

        XCTAssertTrue(store.isMetadataCorrupt)
        XCTAssertFalse(store.canCapture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testDeleteRemovesEntryAndBlob() {
        let directory = tempDirectory()
        let store = makeStore(directory: directory)
        store.record(snapshot: textSnapshot("doomed"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        guard let entry = store.entries.first else { return XCTFail("no entry") }
        let blob = directory.appendingPathComponent("blobs").appendingPathComponent(entry.id.uuidString)

        store.delete(entry)
        XCTAssertTrue(store.entries.isEmpty)

        let deadline = Date().addingTimeInterval(2.0)
        while FileManager.default.fileExists(atPath: blob.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: blob.path))
    }

    // MARK: - Classification

    func testKindClassification() {
        XCTAssertEqual(ClipboardCapture.kind(for: [NSPasteboard.PasteboardType.string.rawValue]), .text)
        XCTAssertEqual(ClipboardCapture.kind(for: [NSPasteboard.PasteboardType.png.rawValue]), .image)
        XCTAssertEqual(ClipboardCapture.kind(for: [NSPasteboard.PasteboardType.fileURL.rawValue]), .files)
        XCTAssertEqual(ClipboardCapture.kind(for: ["com.example.weird"]), .other)
    }

    /// File URLs win over the plain-text representation Finder also puts on the
    /// pasteboard, so a copied file reads as a file rather than as its path.
    func testFileURLBeatsAccompanyingText() {
        let types = [
            NSPasteboard.PasteboardType.fileURL.rawValue,
            NSPasteboard.PasteboardType.string.rawValue
        ]
        XCTAssertEqual(ClipboardCapture.kind(for: types), .files)
    }

    func testPreviewIsTruncated() {
        let long = String(repeating: "x", count: ClipboardCapture.previewLimit + 200)
        let preview = ClipboardCapture.preview(
            kind: .text,
            snapshot: textSnapshot(long),
            types: [NSPasteboard.PasteboardType.string.rawValue]
        )
        XCTAssertEqual(preview.count, ClipboardCapture.previewLimit + 1)
        XCTAssertTrue(preview.hasSuffix("…"))
    }

    // MARK: - Type filter

    func testTypeFilterCatchesPasswordManagerMarkers() {
        XCTAssertTrue(ClipboardTypeFilter.shouldIgnore(types: ["org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(ClipboardTypeFilter.shouldIgnore(types: ["org.nspasteboard.TransientType"]))
        XCTAssertTrue(ClipboardTypeFilter.shouldIgnore(types: ["com.agilebits.onepassword"]))
        XCTAssertFalse(ClipboardTypeFilter.shouldIgnore(types: ["public.utf8-plain-text"]))
    }
}
