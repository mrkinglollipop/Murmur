import AppKit
import CryptoKit
import XCTest
import Security
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
        store.flush()
        guard let metadata = try? Data(contentsOf: directory.appendingPathComponent("clipboard.json")) else {
            return XCTFail("no metadata written")
        }
        XCTAssertNil(metadata.range(of: Data("SUPERSECRETVALUE".utf8)), "previews must also be encrypted")
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
    func testOrphanedBlobIsDeletedOnLoad() throws {
        let directory = tempDirectory()
        try Data("[]".utf8).write(to: directory.appendingPathComponent("clipboard.json"))
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

    // MARK: - Keychain failures and preview migration

    private final class MemoryKeychain {
        var value: Data?
        var readStatuses: [OSStatus] = []
        var addCount = 0
        var updateCount = 0
        var addQueries: [[String: Any]] = []

        lazy var store = KeychainStore(
            service: ClipboardKeyStore.service,
            operations: KeychainOperations(
                read: { [unowned self] _ in
                    let status = self.readStatuses.isEmpty
                        ? (self.value == nil ? errSecItemNotFound : errSecSuccess)
                        : self.readStatuses.removeFirst()
                    return (status, status == errSecSuccess ? self.value : nil)
                },
                add: { [unowned self] query in
                    self.addCount += 1
                    self.addQueries.append(query)
                    guard self.value == nil else { return errSecDuplicateItem }
                    self.value = query[kSecValueData as String] as? Data
                    return errSecSuccess
                },
                update: { [unowned self] _, _ in
                    self.updateCount += 1
                    return errSecSuccess
                },
                delete: { _ in XCTFail("unexpected key deletion"); return errSecSuccess }
            )
        )
    }

    func testKeychainReadErrorsNeverMintOrReplaceExistingKey() throws {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable] {
            let memory = MemoryKeychain()
            let key = SymmetricKey(size: .bits256)
            let encoded = Data(key.withUnsafeBytes { Data($0) }.base64EncodedString().utf8)
            memory.value = encoded
            memory.readStatuses = [status]
            XCTAssertNil(ClipboardStore.resolveCrypto(keychain: memory.store))
            XCTAssertEqual(memory.addCount, 0)
            XCTAssertEqual(memory.updateCount, 0)
            XCTAssertEqual(memory.value, encoded)
        }
    }

    func testDefiniteNotFoundCreatesKeyOnceWithExistingFormatAndAttributes() throws {
        let memory = MemoryKeychain()
        let first = try XCTUnwrap(ClipboardStore.resolveCrypto(keychain: memory.store))
        let second = try XCTUnwrap(ClipboardStore.resolveCrypto(keychain: memory.store))
        let plaintext = Data("same key".utf8)
        XCTAssertEqual(try second.open(first.seal(plaintext)), plaintext)
        XCTAssertEqual(memory.addCount, 1)
        XCTAssertEqual(memory.updateCount, 0)
        let query = try XCTUnwrap(memory.addQueries.first)
        XCTAssertEqual(query[kSecAttrService as String] as? String, ClipboardKeyStore.service)
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, ClipboardKeyStore.account)
        XCTAssertEqual(query[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlock as String)
        XCTAssertNil(query[kSecUseDataProtectionKeychain as String])
        let encoded = try XCTUnwrap(String(data: XCTUnwrap(memory.value), encoding: .utf8))
        XCTAssertEqual(Data(base64Encoded: encoded)?.count, 32)
    }

    func testDuplicateOnAddUsesExistingKeyWithoutUpdate() throws {
        let memory = MemoryKeychain()
        let key = SymmetricKey(size: .bits256)
        let original = Data(key.withUnsafeBytes { Data($0) }.base64EncodedString().utf8)
        memory.value = original
        memory.readStatuses = [errSecItemNotFound]
        let resolved = try XCTUnwrap(ClipboardStore.resolveCrypto(keychain: memory.store))
        let data = Data("existing history".utf8)
        XCTAssertEqual(try resolved.open(ClipboardCrypto(key: key).seal(data)), data)
        XCTAssertEqual(memory.addCount, 1)
        XCTAssertEqual(memory.updateCount, 0)
        XCTAssertEqual(memory.value, original)
    }

    func testDuplicateFollowupReadFailurePreservesExistingKey() {
        let memory = MemoryKeychain()
        let original = Data(Data(repeating: 7, count: 32).base64EncodedString().utf8)
        memory.value = original
        memory.readStatuses = [errSecItemNotFound, errSecInteractionNotAllowed]
        XCTAssertNil(ClipboardStore.resolveCrypto(keychain: memory.store))
        XCTAssertEqual(memory.value, original)
        XCTAssertEqual(memory.updateCount, 0)
    }

    func testInvalidStoredKeyIsUnavailableWithoutReplacement() {
        for value in [Data("invalid base64!".utf8), Data(Data([1]).base64EncodedString().utf8), Data([0xFF])] {
            let memory = MemoryKeychain()
            memory.value = value
            XCTAssertNil(ClipboardStore.resolveCrypto(keychain: memory.store))
            XCTAssertEqual(memory.addCount, 0)
            XCTAssertEqual(memory.value, value)
        }
    }

    func testReadFailurePreservesHistoryAndCanRecoverOnLaterActivation() throws {
        let directory = tempDirectory()
        let key = SymmetricKey(size: .bits256)
        let original = activated(ClipboardStore(directory: directory, crypto: ClipboardCrypto(key: key)))
        original.record(snapshot: textSnapshot("existing secret"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(original, count: 1))
        original.flush()
        let entry = try XCTUnwrap(original.entries.first)
        let metadataURL = directory.appendingPathComponent("clipboard.json")
        let blobURL = directory.appendingPathComponent("blobs").appendingPathComponent(entry.id.uuidString)
        let metadata = try Data(contentsOf: metadataURL)
        let blob = try Data(contentsOf: blobURL)
        let memory = MemoryKeychain()
        memory.value = Data(key.withUnsafeBytes { Data($0) }.base64EncodedString().utf8)
        memory.readStatuses = [errSecInteractionNotAllowed]
        let store = activated(ClipboardStore(
            directory: directory,
            cryptoProvider: { ClipboardStore.resolveCrypto(keychain: memory.store) },
            maxEntries: 0
        ))
        XCTAssertTrue(store.isKeyUnavailable)
        XCTAssertTrue(store.isLockedOut)
        store.record(snapshot: textSnapshot("must not land"), sourceBundleID: nil)
        store.flush()
        settle()
        XCTAssertEqual(try Data(contentsOf: metadataURL), metadata)
        XCTAssertEqual(try Data(contentsOf: blobURL), blob)
        XCTAssertEqual(memory.addCount, 0)

        // Retention is permitted only after the original key has been recovered.
        store.activate()
        XCTAssertTrue(waitUntil { !store.isKeyUnavailable && store.canCapture })
        XCTAssertFalse(store.isLockedOut)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(memory.addCount, 0)
    }

    func testLegacyTextAndFilenamePreviewsAreMigratedOnce() throws {
        let directory = tempDirectory()
        let key = SymmetricKey(size: .bits256)
        let crypto = ClipboardCrypto(key: key)
        let original = activated(ClipboardStore(directory: directory, crypto: crypto))
        original.record(snapshot: textSnapshot("LEGACY_PRIVATE_TEXT"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(original, count: 1))
        original.record(snapshot: [[.fileURL: Data("file:///tmp/PRIVATE_FILENAME.pdf".utf8)]], sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(original, count: 2))
        original.flush()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = directory.appendingPathComponent("clipboard.json")
        try encoder.encode(original.entries).write(to: url)

        let migrated = activated(ClipboardStore(directory: directory, crypto: crypto))
        XCTAssertEqual(migrated.entries.map(\.preview), original.entries.map(\.preview))
        let sealed = try Data(contentsOf: url)
        for secret in ["LEGACY_PRIVATE_TEXT", "PRIVATE_FILENAME.pdf"] {
            XCTAssertNil(sealed.range(of: Data(secret.utf8)))
        }
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: sealed) as? [[String: Any]])
        XCTAssertTrue(rows.allSatisfy { $0["preview"] == nil && $0["sealedPreview"] != nil })
        let reopened = activated(ClipboardStore(directory: directory, crypto: crypto))
        XCTAssertEqual(reopened.entries.map(\.preview), migrated.entries.map(\.preview))
        XCTAssertEqual(try Data(contentsOf: url), sealed, "already migrated metadata must not be rewritten on load")
        XCTAssertNotNil(reopened.payload(for: try XCTUnwrap(reopened.entries.first)))
    }

    func testUnavailableKeyLeavesLegacyPreviewForLaterUnlockWithoutDeletingAnything() throws {
        let directory = tempDirectory()
        let crypto = ClipboardCrypto(key: SymmetricKey(size: .bits256))
        let original = activated(ClipboardStore(directory: directory, crypto: crypto))
        original.record(snapshot: textSnapshot("LEGACY_WAITING_FOR_UNLOCK"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(original, count: 1))
        original.flush()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = directory.appendingPathComponent("clipboard.json")
        let legacy = try encoder.encode(original.entries)
        try legacy.write(to: url)
        let blob = directory.appendingPathComponent("blobs").appendingPathComponent(try XCTUnwrap(original.entries.first).id.uuidString)
        let bytes = try Data(contentsOf: blob)
        var available = false
        let store = activated(ClipboardStore(directory: directory, cryptoProvider: { available ? crypto : nil }))
        store.flush()
        settle()
        XCTAssertEqual(try Data(contentsOf: url), legacy)
        XCTAssertEqual(try Data(contentsOf: blob), bytes)
        XCTAssertFalse(store.canCapture)
        available = true
        store.activate()
        XCTAssertTrue(waitUntil { store.canCapture })
        XCTAssertEqual(store.entries.first?.preview, "LEGACY_WAITING_FOR_UNLOCK")
        XCTAssertNil(try Data(contentsOf: url).range(of: Data("LEGACY_WAITING_FOR_UNLOCK".utf8)))
        XCTAssertEqual(try Data(contentsOf: blob), bytes)
    }

    func testLegacyMigrationWriteFailurePreservesOriginalMetadataAndBlob() throws {
        let directory = tempDirectory()
        let crypto = ClipboardCrypto(key: SymmetricKey(size: .bits256))
        let original = activated(ClipboardStore(directory: directory, crypto: crypto))
        original.record(snapshot: textSnapshot("LEGACY_MIGRATION_FAILURE"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(original, count: 1))
        original.flush()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = directory.appendingPathComponent("clipboard.json")
        let legacy = try encoder.encode(original.entries)
        try legacy.write(to: url)
        let blob = directory.appendingPathComponent("blobs").appendingPathComponent(try XCTUnwrap(original.entries.first).id.uuidString)
        var operations = ClipboardFileOperations()
        operations.write = { data, target in
            if target == url { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }
            try data.write(to: target, options: .atomic)
        }
        let reopened = activated(ClipboardStore(directory: directory, crypto: crypto, fileOperations: operations))
        XCTAssertTrue(reopened.isStorageUnavailable)
        XCTAssertFalse(reopened.canCapture)
        XCTAssertEqual(try Data(contentsOf: url), legacy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob.path))
    }

    // MARK: - I/O preservation and cancellation

    func testUnreadableMetadataDoesNotReconcileOrOverwriteHistory() throws {
        let directory = tempDirectory()
        let crypto = ClipboardCrypto(key: SymmetricKey(size: .bits256))
        let original = activated(ClipboardStore(directory: directory, crypto: crypto))
        original.record(snapshot: textSnapshot("unreadable but recoverable"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(original, count: 1))
        original.flush()
        let url = directory.appendingPathComponent("clipboard.json")
        let bytes = try Data(contentsOf: url)
        let blob = directory.appendingPathComponent("blobs").appendingPathComponent(try XCTUnwrap(original.entries.first).id.uuidString)
        var operations = ClipboardFileOperations()
        var enumerations = 0
        operations.read = { target in
            if target == url { throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError) }
            return try Data(contentsOf: target)
        }
        operations.contents = { target in
            enumerations += 1
            return try FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)
        }
        let reopened = activated(ClipboardStore(directory: directory, crypto: crypto, fileOperations: operations))
        reopened.flush()
        settle()
        XCTAssertTrue(reopened.isStorageUnavailable)
        XCTAssertFalse(reopened.canCapture)
        XCTAssertEqual(enumerations, 0)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob.path))
        reopened.record(snapshot: textSnapshot("must remain paused"), sourceBundleID: nil)
        reopened.flush()
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob.path))
    }

    func testFailedEnumerationPreservesEntriesAndAllOrphans() throws {
        for failingDirectory in ["blobs", "thumbs", "root"] {
            let directory = tempDirectory()
            let crypto = ClipboardCrypto(key: SymmetricKey(size: .bits256))
            let original = activated(ClipboardStore(directory: directory, crypto: crypto))
            original.record(snapshot: textSnapshot("known history"), sourceBundleID: nil)
            XCTAssertTrue(waitForEntries(original, count: 1))
            original.flush()
            let entry = try XCTUnwrap(original.entries.first)
            let orphan = directory.appendingPathComponent("blobs").appendingPathComponent(UUID().uuidString)
            try Data("recoverable orphan".utf8).write(to: orphan)
            let url = directory.appendingPathComponent("clipboard.json")
            let bytes = try Data(contentsOf: url)
            var operations = ClipboardFileOperations()
            operations.contents = { target in
                if (failingDirectory == "root" && target == directory) || target.lastPathComponent == failingDirectory {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
                }
                return try FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)
            }
            let reopened = activated(ClipboardStore(directory: directory, crypto: crypto, fileOperations: operations, maxEntries: 0))
            XCTAssertTrue(reopened.isStorageUnavailable)
            XCTAssertFalse(reopened.canCapture)
            reopened.flush()
            XCTAssertFalse(reopened.isStorageUnavailable)
            XCTAssertTrue(reopened.canCapture)
            XCTAssertEqual(reopened.entries.map(\.id), [entry.id])
            XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("blobs").appendingPathComponent(entry.id.uuidString).path))
            // A re-save may re-seal the preview under a fresh nonce, so compare
            // what a fresh launch reads rather than the ciphertext bytes.
            XCTAssertEqual(try Data(contentsOf: url).count, bytes.count)
            let relaunched = activated(ClipboardStore(directory: directory, crypto: crypto))
            XCTAssertEqual(relaunched.entries.map(\.id), [entry.id])
            XCTAssertEqual(relaunched.entries.first?.preview, entry.preview)
        }
    }

    func testFailedDeletionKeepsMetadataAndSurfacesFailure() throws {
        let directory = tempDirectory()
        var blocked: URL?
        var store: ClipboardStore!
        var metadataWasPresentDuringRemoval = false
        var operations = ClipboardFileOperations()
        operations.remove = { url in
            if url == blocked {
                metadataWasPresentDuringRemoval = store.entries.contains { $0.id.uuidString == url.lastPathComponent }
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            }
            try FileManager.default.removeItem(at: url)
        }
        let crypto = ClipboardCrypto(key: SymmetricKey(size: .bits256))
        store = activated(ClipboardStore(directory: directory, crypto: crypto, fileOperations: operations))
        store.record(snapshot: textSnapshot("deletion refused"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        store.flush()
        let entry = try XCTUnwrap(store.entries.first)
        blocked = directory.appendingPathComponent("blobs").appendingPathComponent(entry.id.uuidString)
        let url = directory.appendingPathComponent("clipboard.json")
        let metadata = try Data(contentsOf: url)
        store.delete(entry)
        XCTAssertTrue(store.isStorageUnavailable)
        XCTAssertFalse(store.canCapture)
        store.flush()
        XCTAssertTrue(metadataWasPresentDuringRemoval)
        XCTAssertEqual(store.entries.map(\.id), [entry.id])
        XCTAssertFalse(store.isStorageUnavailable)
        XCTAssertTrue(store.canCapture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(blocked).path))
        XCTAssertEqual(try Data(contentsOf: url).count, metadata.count)
        let relaunched = activated(ClipboardStore(directory: directory, crypto: crypto))
        XCTAssertEqual(relaunched.entries.map(\.id), [entry.id])
        XCTAssertEqual(relaunched.entries.first?.preview, entry.preview)
    }

    func testClearAllCancelsCaptureBeforeItsMetadataInsertion() throws {
        let directory = tempDirectory()
        let store = makeStore(directory: directory)
        store.record(snapshot: textSnapshot("pending before clear"), sourceBundleID: nil)
        store.clearAll()
        store.flush()
        settle()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("blobs").path).isEmpty)
        let reopened = activated(ClipboardStore(directory: directory, crypto: ClipboardCrypto(key: SymmetricKey(size: .bits256))))
        XCTAssertTrue(reopened.entries.isEmpty)
        XCTAssertFalse(reopened.isLockedOut)
    }

    func testClearAllKeepsEntryWhenFileDeletionFails() throws {
        let directory = tempDirectory()
        var blocked = false
        var operations = ClipboardFileOperations()
        operations.remove = { url in
            if blocked { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }
            try FileManager.default.removeItem(at: url)
        }
        let store = activated(ClipboardStore(directory: directory, crypto: ClipboardCrypto(key: SymmetricKey(size: .bits256)), fileOperations: operations))
        store.record(snapshot: textSnapshot("cannot clear"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        store.flush()
        let ids = store.entries.map(\.id)
        blocked = true
        store.clearAll()
        XCTAssertEqual(store.entries.map(\.id), ids)
        XCTAssertTrue(store.isStorageUnavailable)
        XCTAssertFalse(store.canCapture)
    }

    func testMetadataWriteFailureBlocksFurtherCaptureAndPreservesDiskHistory() throws {
        let directory = tempDirectory()
        var failWrite = false
        var operations = ClipboardFileOperations()
        operations.write = { data, url in
            if failWrite && url.lastPathComponent == "clipboard.json" {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            }
            try data.write(to: url, options: .atomic)
        }
        let crypto = ClipboardCrypto(key: SymmetricKey(size: .bits256))
        let store = activated(ClipboardStore(directory: directory, crypto: crypto, fileOperations: operations))
        store.record(snapshot: textSnapshot("saved history"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        store.flush()
        let url = directory.appendingPathComponent("clipboard.json")
        let saved = try Data(contentsOf: url)
        failWrite = true
        store.record(snapshot: textSnapshot("unsaved history"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 2))
        store.flush()
        XCTAssertTrue(store.isStorageUnavailable)
        XCTAssertFalse(store.canCapture)
        XCTAssertEqual(try Data(contentsOf: url), saved)
        store.record(snapshot: textSnapshot("still failing"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 3))
        store.flush()
        XCTAssertEqual(try Data(contentsOf: url), saved)
        XCTAssertTrue(store.isStorageUnavailable)
        failWrite = false
        store.record(snapshot: textSnapshot("safe retry"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 4))
        store.flush()
        XCTAssertFalse(store.isStorageUnavailable)
        let relaunched = activated(ClipboardStore(directory: directory, crypto: crypto))
        XCTAssertEqual(relaunched.entries.count, 4)
        XCTAssertFalse(relaunched.isLockedOut)
        XCTAssertTrue(relaunched.canCapture)
    }

    func testReadFailureOnFreshStoreCreatesNoClipboardFiles() throws {
        let directory = tempDirectory()
        let memory = MemoryKeychain()
        memory.readStatuses = [errSecInteractionNotAllowed]
        let store = activated(ClipboardStore(
            directory: directory,
            cryptoProvider: { ClipboardStore.resolveCrypto(keychain: memory.store) }
        ))
        store.record(snapshot: textSnapshot("must not be written"), sourceBundleID: nil)
        store.flush()
        XCTAssertTrue(store.isKeyUnavailable)
        XCTAssertEqual(memory.addCount, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testRetentionDeletionFailureKeepsAllMetadataAndBlobs() throws {
        let directory = tempDirectory()
        var blocked: URL?
        var operations = ClipboardFileOperations()
        operations.remove = { url in
            if url == blocked { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }
            try FileManager.default.removeItem(at: url)
        }
        let store = activated(ClipboardStore(
            directory: directory,
            crypto: ClipboardCrypto(key: SymmetricKey(size: .bits256)),
            fileOperations: operations,
            maxEntries: 1
        ))
        store.record(snapshot: textSnapshot("old entry"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        store.flush()
        let entry = try XCTUnwrap(store.entries.first)
        blocked = directory.appendingPathComponent("blobs").appendingPathComponent(entry.id.uuidString)
        store.record(snapshot: textSnapshot("new entry"), sourceBundleID: nil)
        XCTAssertTrue(waitUntil { store.isStorageUnavailable })
        XCTAssertEqual(store.entries.count, 2, "retention must not drop metadata before deleting its file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(blocked).path))
        XCTAssertFalse(store.canCapture)
    }

    func testClearAllCancelsCaptureWhoseBlobWriteIsAlreadyRunning() throws {
        let directory = tempDirectory()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var blockWrite = true
        var operations = ClipboardFileOperations()
        operations.write = { data, url in
            if blockWrite && url.deletingLastPathComponent().lastPathComponent == "blobs" {
                started.signal()
                guard release.wait(timeout: .now() + 2) == .success else {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
                }
            }
            try data.write(to: url, options: .atomic)
        }
        let store = activated(ClipboardStore(
            directory: directory,
            crypto: ClipboardCrypto(key: SymmetricKey(size: .bits256)),
            fileOperations: operations
        ))
        store.record(snapshot: textSnapshot("already writing"), sourceBundleID: nil)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { release.signal() }
        store.clearAll()
        store.flush()
        settle()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("blobs").path).isEmpty)
        blockWrite = false
        store.record(snapshot: textSnapshot("after clear"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        XCTAssertEqual(store.entries.first?.preview, "after clear")
    }

    func testTransientBlobWriteFailureDoesNotQuarantineExistingHistoryAcrossLaunch() throws {
        let directory = tempDirectory()
        let key = SymmetricKey(size: .bits256)
        let crypto = ClipboardCrypto(key: key)
        let original = activated(ClipboardStore(directory: directory, crypto: crypto))
        original.record(snapshot: textSnapshot("older history"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(original, count: 1))
        original.flush()

        var operations = ClipboardFileOperations()
        operations.write = { data, url in
            if url.deletingLastPathComponent().lastPathComponent == "blobs" {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
            }
            try data.write(to: url, options: .atomic)
        }
        let failing = activated(ClipboardStore(directory: directory, crypto: crypto, fileOperations: operations))
        failing.record(snapshot: textSnapshot("transient failure"), sourceBundleID: nil)
        XCTAssertTrue(waitUntil { failing.isStorageUnavailable })
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("clipboard.json.quarantine").path))

        let relaunched = activated(ClipboardStore(directory: directory, crypto: crypto))
        XCTAssertEqual(relaunched.entries.map(\.preview), ["older history"])
        relaunched.record(snapshot: textSnapshot("new capture"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(relaunched, count: 2))
    }

    func testMigrationCreatesWriteOnceOwnerOnlyBackup() throws {
        let directory = tempDirectory()
        let key = SymmetricKey(size: .bits256)
        let crypto = ClipboardCrypto(key: key)
        let original = activated(ClipboardStore(directory: directory, crypto: crypto))
        original.record(snapshot: textSnapshot("LEGACY_BACKUP"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(original, count: 1))
        original.flush()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let metadata = directory.appendingPathComponent("clipboard.json")
        let legacy = try encoder.encode(original.entries)
        try legacy.write(to: metadata)

        _ = activated(ClipboardStore(directory: directory, crypto: crypto))
        let backup = directory.appendingPathComponent("clipboard.json.pre-migration-backup")
        XCTAssertEqual(try Data(contentsOf: backup), legacy)
        let permissions = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let preserved = try Data(contentsOf: backup)
        var laterLegacy = original.entries
        laterLegacy[0].preview = "LATER_LEGACY_MIGRATION"
        try encoder.encode(laterLegacy).write(to: metadata)
        _ = activated(ClipboardStore(directory: directory, crypto: crypto))
        XCTAssertEqual(try Data(contentsOf: backup), preserved)
    }

    func testDowngradeMarkerClearsWhenCurrentMetadataStillExists() throws {
        let directory = tempDirectory()
        let crypto = ClipboardCrypto(key: SymmetricKey(size: .bits256))
        let original = activated(ClipboardStore(directory: directory, crypto: crypto))
        original.record(snapshot: textSnapshot("still current"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(original, count: 1))
        original.flush()
        let marker = directory.appendingPathComponent("clipboard.json.quarantine")
        try Data().write(to: marker)

        let recovered = activated(ClipboardStore(directory: directory, crypto: crypto))
        XCTAssertFalse(recovered.isMetadataCorrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(recovered.entries.first?.preview, "still current")
    }

    func testDowngradeMarkerAlsoRecoversLegacyMetadataForFirstMigration() throws {
        let directory = tempDirectory()
        let crypto = ClipboardCrypto(key: SymmetricKey(size: .bits256))
        let original = activated(ClipboardStore(directory: directory, crypto: crypto))
        original.record(snapshot: textSnapshot("legacy under marker"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(original, count: 1))
        original.flush()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(original.entries).write(to: directory.appendingPathComponent("clipboard.json"))
        try Data().write(to: directory.appendingPathComponent("clipboard.json.quarantine"))

        let recovered = activated(ClipboardStore(directory: directory, crypto: crypto))
        XCTAssertFalse(recovered.isMetadataCorrupt)
        XCTAssertEqual(recovered.entries.first?.preview, "legacy under marker")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("clipboard.json.pre-migration-backup").path))
    }

    func testDowngradeMarkerRestoresNewestCurrentFormatQuarantineWithoutOverwritingMetadata() throws {
        let directory = tempDirectory()
        let crypto = ClipboardCrypto(key: SymmetricKey(size: .bits256))
        let original = activated(ClipboardStore(directory: directory, crypto: crypto))
        original.record(snapshot: textSnapshot("downgrade roundtrip"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(original, count: 1))
        original.flush()
        let metadata = directory.appendingPathComponent("clipboard.json")
        let quarantined = directory.appendingPathComponent("clipboard.json.corrupt.9999999999")
        try FileManager.default.moveItem(at: metadata, to: quarantined)
        let marker = directory.appendingPathComponent("clipboard.json.quarantine")
        try Data().write(to: marker)

        let recovered = activated(ClipboardStore(directory: directory, crypto: crypto))
        XCTAssertFalse(recovered.isMetadataCorrupt)
        XCTAssertEqual(recovered.entries.first?.preview, "downgrade roundtrip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testDowngradeRecoveryDoesNotFallBackFromInvalidNewestQuarantine() throws {
        let directory = tempDirectory()
        let crypto = ClipboardCrypto(key: SymmetricKey(size: .bits256))
        let original = activated(ClipboardStore(directory: directory, crypto: crypto))
        original.record(snapshot: textSnapshot("older valid recovery"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(original, count: 1))
        original.flush()
        let metadata = directory.appendingPathComponent("clipboard.json")
        try FileManager.default.moveItem(at: metadata, to: directory.appendingPathComponent("clipboard.json.corrupt.1"))
        try Data("newest invalid".utf8).write(to: directory.appendingPathComponent("clipboard.json.corrupt.2"))
        let marker = directory.appendingPathComponent("clipboard.json.quarantine")
        try Data().write(to: marker)

        let reopened = activated(ClipboardStore(directory: directory, crypto: crypto))
        XCTAssertTrue(reopened.isMetadataCorrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testMissingMetadataOrCorruptSiblingNeverSweepsUnknownBlobs() throws {
        let directory = tempDirectory()
        let crypto = ClipboardCrypto(key: SymmetricKey(size: .bits256))
        let blobs = directory.appendingPathComponent("blobs", isDirectory: true)
        let thumbs = directory.appendingPathComponent("thumbs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        let unknown = blobs.appendingPathComponent(UUID().uuidString)
        try Data("unknown".utf8).write(to: unknown)
        _ = activated(ClipboardStore(directory: directory, crypto: crypto))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        let paused = activated(ClipboardStore(directory: directory, crypto: crypto))
        XCTAssertFalse(paused.canCapture)
        paused.flush()
        paused.record(snapshot: textSnapshot("must not replace unknown history"), sourceBundleID: nil)
        paused.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("clipboard.json").path))
        let relaunchedUnknown = activated(ClipboardStore(directory: directory, crypto: crypto))
        XCTAssertFalse(relaunchedUnknown.canCapture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))

        let siblingDirectory = tempDirectory()
        let store = activated(ClipboardStore(directory: siblingDirectory, crypto: crypto))
        store.record(snapshot: textSnapshot("known"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        store.flush()
        let sibling = siblingDirectory.appendingPathComponent("clipboard.json.corrupt.1")
        try Data("old metadata".utf8).write(to: sibling)
        let secondUnknown = siblingDirectory.appendingPathComponent("blobs").appendingPathComponent(UUID().uuidString)
        try Data("unknown too".utf8).write(to: secondUnknown)
        _ = activated(ClipboardStore(directory: siblingDirectory, crypto: crypto))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondUnknown.path))
    }

    func testSingleDamagedBlobUsesDecryptablePreviewAndKeepsCapturing() throws {
        let directory = tempDirectory()
        let crypto = ClipboardCrypto(key: SymmetricKey(size: .bits256))
        let original = activated(ClipboardStore(directory: directory, crypto: crypto))
        original.record(snapshot: textSnapshot("preview establishes key"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(original, count: 1))
        original.flush()
        let entry = try XCTUnwrap(original.entries.first)
        try Data("damaged blob".utf8).write(to: directory.appendingPathComponent("blobs").appendingPathComponent(entry.id.uuidString))

        let reopened = activated(ClipboardStore(directory: directory, crypto: crypto))
        XCTAssertFalse(reopened.isLockedOut)
        XCTAssertTrue(reopened.canCapture)
        XCTAssertNil(reopened.payload(for: try XCTUnwrap(reopened.entries.first)))
        XCTAssertTrue(waitUntil { reopened.entries.first?.preview == "Unavailable clipboard item" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("blobs").appendingPathComponent(entry.id.uuidString).path))
        reopened.record(snapshot: textSnapshot("still captures"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(reopened, count: 2))
    }

    func testDamagedPreviewRemainsPerItemAndIsNotResealedAsPlaceholder() throws {
        let directory = tempDirectory()
        let crypto = ClipboardCrypto(key: SymmetricKey(size: .bits256))
        let original = activated(ClipboardStore(directory: directory, crypto: crypto))
        original.record(snapshot: textSnapshot("bad preview"), sourceBundleID: nil)
        original.record(snapshot: textSnapshot("good preview"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(original, count: 2))
        original.flush()
        let metadata = directory.appendingPathComponent("clipboard.json")
        var rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [[String: Any]])
        let damaged = Data("damaged preview".utf8).base64EncodedString()
        rows[0]["sealedPreview"] = damaged
        try JSONSerialization.data(withJSONObject: rows).write(to: metadata)

        let reopened = activated(ClipboardStore(directory: directory, crypto: crypto))
        XCTAssertFalse(reopened.isLockedOut)
        XCTAssertTrue(reopened.canCapture)
        XCTAssertTrue(reopened.entries.contains(where: { $0.preview == "Unavailable clipboard item" }))
        reopened.flush()
        let savedRows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [[String: Any]])
        XCTAssertTrue(savedRows.contains(where: { $0["sealedPreview"] as? String == damaged }))
    }

    func testViewRetryActivatesAfterTransientKeyUnavailable() {
        let directory = tempDirectory()
        let crypto = ClipboardCrypto(key: SymmetricKey(size: .bits256))
        var available = false
        let store = activated(ClipboardStore(directory: directory, cryptoProvider: { available ? crypto : nil }))
        XCTAssertTrue(store.isKeyUnavailable)
        available = true
        store.retryKeyIfUnavailable()
        XCTAssertTrue(waitUntil { store.canCapture })
    }

    func testMissingMetadataIgnoresDotfilesAndAtomicTemporaryFiles() throws {
        let directory = tempDirectory()
        let blobs = directory.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        for name in [".DS_Store", ".atomic-write", "capture.tmp"] {
            try Data("temporary".utf8).write(to: blobs.appendingPathComponent(name))
        }
        let store = makeStore(directory: directory)
        XCTAssertFalse(store.isMetadataCorrupt)
        XCTAssertTrue(store.canCapture)
        store.record(snapshot: textSnapshot("ordinary copy"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
    }

    func testMissingMetadataUnknownHistoryRequiresExplicitDiscard() throws {
        for siblingOnly in [false, true] {
            let directory = tempDirectory()
            let blobs = directory.appendingPathComponent("blobs")
            try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
            let preserved = siblingOnly
                ? directory.appendingPathComponent("clipboard.json.corrupt.1")
                : blobs.appendingPathComponent(UUID().uuidString)
            let data = Data("unknown preserved history".utf8)
            try data.write(to: preserved)
            let backup = directory.appendingPathComponent("clipboard.json.pre-migration-backup")
            try Data("plaintext backup".utf8).write(to: backup)
            let store = makeStore(directory: directory)
            XCTAssertTrue(store.isMetadataCorrupt)
            XCTAssertFalse(store.canAttemptCapture)
            store.clearAll()
            store.flush()
            XCTAssertEqual(try Data(contentsOf: preserved), data)
            XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
            store.discardCorruptHistory()
            XCTAssertTrue(waitUntil { !store.isMetadataCorrupt && store.canCapture })
            XCTAssertFalse(FileManager.default.fileExists(atPath: preserved.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
            store.record(snapshot: textSnapshot("after explicit recovery"), sourceBundleID: nil)
            XCTAssertTrue(waitForEntries(store, count: 1))
        }
    }

    func testClearAllDeletesMigrationBackupWithoutRecreatingIt() throws {
        let directory = tempDirectory()
        let crypto = ClipboardCrypto(key: SymmetricKey(size: .bits256))
        let original = activated(ClipboardStore(directory: directory, crypto: crypto))
        original.record(snapshot: textSnapshot("legacy private preview"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(original, count: 1))
        original.flush()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(original.entries).write(to: directory.appendingPathComponent("clipboard.json"))
        var operations = ClipboardFileOperations()
        operations.write = { _, _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        }
        let migrating = activated(ClipboardStore(directory: directory, crypto: crypto, fileOperations: operations))
        let backup = directory.appendingPathComponent("clipboard.json.pre-migration-backup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        migrating.clearAll()
        migrating.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testDiscardCorruptMetadataDeletesMigrationBackupAndAllowsCleanup() throws {
        let directory = tempDirectory()
        let crypto = ClipboardCrypto(key: SymmetricKey(size: .bits256))
        let metadata = directory.appendingPathComponent("clipboard.json")
        let backup = directory.appendingPathComponent("clipboard.json.pre-migration-backup")
        try Data("broken".utf8).write(to: metadata)
        try Data("private plaintext".utf8).write(to: backup)
        let store = activated(ClipboardStore(directory: directory, crypto: crypto))
        XCTAssertTrue(store.isMetadataCorrupt)
        store.discardCorruptHistory()
        XCTAssertTrue(waitUntil { !store.isMetadataCorrupt })
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        let orphan = directory.appendingPathComponent("blobs").appendingPathComponent(UUID().uuidString)
        try Data("orphan".utf8).write(to: orphan)
        _ = activated(ClipboardStore(directory: directory, crypto: crypto))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testUnreadableLegacyPayloadDoesNotPersistPlaceholderAfterMigrationRetry() throws {
        let directory = tempDirectory()
        let crypto = ClipboardCrypto(key: SymmetricKey(size: .bits256))
        let original = activated(ClipboardStore(directory: directory, crypto: crypto))
        original.record(snapshot: textSnapshot("original legacy preview"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(original, count: 1))
        original.flush()
        let entry = try XCTUnwrap(original.entries.first)
        let metadata = directory.appendingPathComponent("clipboard.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(original.entries).write(to: metadata)
        var fail = true
        var operations = ClipboardFileOperations()
        operations.write = { data, url in
            if fail && url == metadata {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            }
            try data.write(to: url, options: .atomic)
        }
        let store = activated(ClipboardStore(directory: directory, crypto: crypto, fileOperations: operations))
        let blob = directory.appendingPathComponent("blobs").appendingPathComponent(entry.id.uuidString)
        let originalBlob = try Data(contentsOf: blob)
        try Data("damaged".utf8).write(to: blob)
        XCTAssertNil(store.payload(for: try XCTUnwrap(store.entries.first)))
        XCTAssertEqual(store.entries.first?.preview, "Unavailable clipboard item")
        fail = false
        store.flush()
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [[String: Any]])
        let sealed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(rows.first?["sealedPreview"] as? String)))
        XCTAssertEqual(String(data: try crypto.open(sealed), encoding: .utf8), "original legacy preview")
        try originalBlob.write(to: blob)
        let relaunched = activated(ClipboardStore(directory: directory, crypto: crypto))
        XCTAssertEqual(relaunched.entries.first?.preview, "original legacy preview")
    }

    func testRecoveredCurrentMetadataArchivesHandledSiblingAndCleansOrphans() throws {
        let directory = tempDirectory()
        let crypto = ClipboardCrypto(key: SymmetricKey(size: .bits256))
        let original = activated(ClipboardStore(directory: directory, crypto: crypto))
        original.record(snapshot: textSnapshot("current history"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(original, count: 1))
        original.flush()
        let metadata = directory.appendingPathComponent("clipboard.json")
        let sibling = directory.appendingPathComponent("clipboard.json.corrupt.1")
        let data = try Data(contentsOf: metadata)
        try data.write(to: sibling)
        try Data().write(to: directory.appendingPathComponent("clipboard.json.quarantine"))
        let orphan = directory.appendingPathComponent("blobs").appendingPathComponent(UUID().uuidString)
        try Data("orphan".utf8).write(to: orphan)
        let recovered = activated(ClipboardStore(directory: directory, crypto: crypto))
        XCTAssertFalse(recovered.isMetadataCorrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        let archives = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("clipboard.json.recovered.") }
        XCTAssertEqual(archives.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(archives.first)), data)
        let nextOrphan = directory.appendingPathComponent("blobs").appendingPathComponent(UUID().uuidString)
        try Data("later orphan".utf8).write(to: nextOrphan)
        _ = activated(ClipboardStore(directory: directory, crypto: crypto))
        XCTAssertFalse(FileManager.default.fileExists(atPath: nextOrphan.path))
        recovered.clearAll()
        recovered.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(archives.first).path))
    }

    func testUnreadableUnpersistedPayloadRetainsOriginalPreview() throws {
        let directory = tempDirectory()
        let crypto = ClipboardCrypto(key: SymmetricKey(size: .bits256))
        let store = activated(ClipboardStore(directory: directory, crypto: crypto))
        store.record(snapshot: textSnapshot("not saved yet"), sourceBundleID: nil)
        XCTAssertTrue(waitForEntries(store, count: 1))
        let entry = try XCTUnwrap(store.entries.first)
        try Data("damaged".utf8).write(to: directory.appendingPathComponent("blobs").appendingPathComponent(entry.id.uuidString))
        XCTAssertNil(store.payload(for: entry))
        XCTAssertNil(store.payload(for: try XCTUnwrap(store.entries.first)))
        store.flush()
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("clipboard.json"))) as? [[String: Any]])
        let sealed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(rows.first?["sealedPreview"] as? String)))
        XCTAssertEqual(String(data: try crypto.open(sealed), encoding: .utf8), "not saved yet")
    }

    func testRestoredDowngradeArchivesOnlyHandledSiblings() throws {
        for unreadableSibling in [false, true] {
            let directory = tempDirectory()
            let crypto = ClipboardCrypto(key: SymmetricKey(size: .bits256))
            let original = activated(ClipboardStore(directory: directory, crypto: crypto))
            original.record(snapshot: textSnapshot("restored history"), sourceBundleID: nil)
            XCTAssertTrue(waitForEntries(original, count: 1))
            original.flush()
            let metadata = directory.appendingPathComponent("clipboard.json")
            let sibling = directory.appendingPathComponent("clipboard.json.corrupt.1")
            let data = try Data(contentsOf: metadata)
            try (unreadableSibling ? Data("unknown".utf8) : data).write(to: sibling)
            try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: sibling.path)
            try FileManager.default.moveItem(at: metadata, to: directory.appendingPathComponent("clipboard.json.corrupt.2"))
            try Data().write(to: directory.appendingPathComponent("clipboard.json.quarantine"))
            let orphan = directory.appendingPathComponent("blobs").appendingPathComponent(UUID().uuidString)
            try Data("unknown blob".utf8).write(to: orphan)
            let recovered = activated(ClipboardStore(directory: directory, crypto: crypto))
            XCTAssertFalse(recovered.isMetadataCorrupt)
            XCTAssertEqual(recovered.entries.first?.preview, "restored history")
            XCTAssertEqual(FileManager.default.fileExists(atPath: sibling.path), unreadableSibling)
            XCTAssertEqual(FileManager.default.fileExists(atPath: orphan.path), unreadableSibling)
        }
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
