// PRO ONLY — this file is part of the paid clipboard manager and must never
// merge into `main`. Its target is the `pro` branch, gated behind a Pro
// entitlement check. See the "Clipboard manager" section of CLAUDE.md.

import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO
import os.log

/// What a captured pasteboard item mostly *is*, for rendering and filtering.
enum ClipboardKind: String, Codable, Equatable {
    case text
    case image
    case files
    case other
}

/// Metadata for one captured pasteboard item.
///
/// The payload — every representation the pasteboard carried — lives in a
/// separate encrypted blob file keyed by `id`. Only this record is held in
/// memory, so a history full of screenshots costs kilobytes of RAM.
///
/// PRIVACY: `preview` is the only user content here and it is truncated. As
/// with `HistoryStore`, nothing in this struct may be passed to `vlog`,
/// `os_log`, `print`, or any /tmp path.
struct ClipboardEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    var kind: ClipboardKind
    /// Truncated plain-text summary: the text itself, the file names, or a
    /// dimension line for images. Never the full payload.
    var preview: String
    /// Bundle identifier of the frontmost app when the copy was observed.
    ///
    /// Best-effort only: copies are detected by polling, so an app switch
    /// between ⌘C and the next poll misattributes the source.
    var sourceBundleID: String?
    /// Pasteboard type identifiers present in the stored blob.
    var types: [String]
    /// Size of the encrypted blob on disk, for the retention byte budget.
    var byteCount: Int
    /// Hex SHA-256 over the canonical payload — see `ClipboardFingerprint`.
    var fingerprint: String
}

/// The disk record accepts the old preview only for migration; writes seal it.
private struct StoredClipboardEntry: Codable {
    let id: UUID
    let date: Date
    let kind: ClipboardKind
    let preview: String?
    let sealedPreview: Data?
    let sourceBundleID: String?
    let types: [String]
    let byteCount: Int
    let fingerprint: String

    var entry: ClipboardEntry {
        ClipboardEntry(
            id: id, date: date, kind: kind, preview: preview ?? "",
            sourceBundleID: sourceBundleID, types: types,
            byteCount: byteCount, fingerprint: fingerprint
        )
    }

    init(entry: ClipboardEntry, crypto: ClipboardCrypto) throws {
        id = entry.id
        date = entry.date
        kind = entry.kind
        preview = nil
        sealedPreview = try crypto.seal(Data(entry.preview.utf8))
        sourceBundleID = entry.sourceBundleID
        types = entry.types
        byteCount = entry.byteCount
        fingerprint = entry.fingerprint
    }

    /// Keeps an already-sealed preview byte-for-byte. This matters when one
    /// row is damaged: saving another row must not replace its ciphertext with
    /// the placeholder we show in memory.
    init(entry: ClipboardEntry, sealedPreview: Data) {
        id = entry.id
        date = entry.date
        kind = entry.kind
        preview = nil
        self.sealedPreview = sealedPreview
        sourceBundleID = entry.sourceBundleID
        types = entry.types
        byteCount = entry.byteCount
        fingerprint = entry.fingerprint
    }
}

struct ClipboardFileOperations {
    var read: (URL) throws -> Data = { try Data(contentsOf: $0) }
    var write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    var contents: (URL) throws -> [URL] = {
        try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
    }
    var remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
}

/// Content identity for dedupe, computed over a *canonical* payload rather
/// than the full type map.
///
/// This distinction is load-bearing. `TextInjector` restores the pre-dictation
/// pasteboard by rewriting captured items (`restorePasteboardSnapshot`), and
/// macOS may synthesize extra representations on write — so the same content
/// can come back with a different set of types. A fingerprint over every type
/// would see that restore as brand-new content and log a duplicate entry on
/// every single dictation.
enum ClipboardFingerprint {

    /// The representation that identifies the item: its plain text when it has
    /// any, otherwise its largest data blob.
    ///
    /// Ties break on the type identifier, never on dictionary order. Swift
    /// seeds its hashing per process, so `max(by:)` over equal-sized values
    /// picks a different winner between launches — and because the resulting
    /// fingerprint is persisted, that would let a reload compute a value that
    /// no longer matches the stored one and silently miss the dedupe.
    static func canonicalPayload(
        of item: [NSPasteboard.PasteboardType: Data]
    ) -> Data? {
        if let text = item[.string] { return text }
        return item.max { lhs, rhs in
            (lhs.value.count, lhs.key.rawValue) < (rhs.value.count, rhs.key.rawValue)
        }?.value
    }

    /// Hex SHA-256 over each item's canonical payload, in item order.
    static func fingerprint(for snapshot: TextInjector.PasteboardSnapshot) -> String {
        var hasher = SHA256()
        for item in snapshot {
            let payload = canonicalPayload(of: item) ?? Data()
            var length = UInt64(payload.count).bigEndian
            hasher.update(data: Data(bytes: &length, count: MemoryLayout<UInt64>.size))
            hasher.update(data: payload)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Pasteboard types that mark content as not-for-history. Honoring these is
/// what keeps password managers' clipboard writes — and Murmur's own injection
/// writes, which carry `ConcealedType` — out of the history.
enum ClipboardTypeFilter {

    static let ignored: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
        "de.petermaurer.TransientPasteboardType"
    ]

    static func shouldIgnore(types: [String]) -> Bool {
        types.contains { ignored.contains($0) }
    }
}

/// Classifies a captured snapshot and builds its human-readable preview.
enum ClipboardCapture {

    /// Longest preview retained. Enough to identify an entry in a list without
    /// keeping a second copy of a large document in the metadata file.
    static let previewLimit = 500

    static func kind(for types: [String]) -> ClipboardKind {
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) { return .files }
        if types.contains(NSPasteboard.PasteboardType.tiff.rawValue)
            || types.contains(NSPasteboard.PasteboardType.png.rawValue) {
            return .image
        }
        if types.contains(NSPasteboard.PasteboardType.string.rawValue) { return .text }
        return .other
    }

    /// Longest edge of a stored row thumbnail, in pixels.
    static let thumbnailMaxPixelSize = 128

    /// A small PNG for list display, built without decoding the full image.
    ///
    /// Rows cannot render from the stored payload directly: entries run to
    /// `maxItemBytes`, and decrypting several megabytes per visible row while
    /// scrolling would make the list unusable. `kCGImageSourceCreateThumbnail`
    /// decodes at the requested size rather than at full resolution.
    static func makeThumbnail(
        from data: Data,
        maxPixel: Int = thumbnailMaxPixelSize
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: thumb)
        return rep.representation(using: .png, properties: [:])
    }

    /// Pixel dimensions read from image metadata, without decoding the image.
    ///
    /// `NSImage(data:)` rasterizes the whole thing just to answer `.size`,
    /// which is far too expensive for a preview line — a large screenshot
    /// costs tens of milliseconds and this runs on every image copy.
    static func imageDimensions(from data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

    static func preview(
        kind: ClipboardKind,
        snapshot: TextInjector.PasteboardSnapshot,
        types: [String]
    ) -> String {
        switch kind {
        case .text:
            let joined = snapshot.compactMap { item in
                item[.string].flatMap { String(data: $0, encoding: .utf8) }
            }.joined(separator: "\n")
            return truncate(joined.trimmingCharacters(in: .whitespacesAndNewlines))
        case .files:
            let names = snapshot.compactMap { item -> String? in
                guard let data = item[.fileURL],
                      let string = String(data: data, encoding: .utf8),
                      let url = URL(string: string) else { return nil }
                return url.lastPathComponent
            }
            return truncate(names.joined(separator: ", "))
        case .image:
            let candidate = snapshot.first?[.png] ?? snapshot.first?[.tiff]
            if let data = candidate, let size = imageDimensions(from: data) {
                return "Image · \(size.width)×\(size.height)"
            }
            let bytes = snapshot.first?.values.map(\.count).max() ?? 0
            let formatted = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            return "Image · \(formatted)"
        case .other:
            return truncate(types.joined(separator: ", "))
        }
    }

    static func truncate(_ text: String, limit: Int = previewLimit) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}

/// Persists captured pasteboard items: metadata in a flat JSON file, payloads
/// as individually AES-GCM-sealed blob files under `Clipboard/blobs/`.
///
/// Blobs are kept out of the JSON deliberately. The other stores in this app
/// load their entire file into memory at launch, which is fine for text and
/// ruinous for a history of screenshots — one 5 MB image would be re-read on
/// every launch and inflated by a third if base64'd into JSON.
final class ClipboardStore: ObservableObject {

    @Published private(set) var entries: [ClipboardEntry] = []

    /// Set when the key on hand cannot open the stored history.
    @Published private(set) var isLockedOut = false

    /// Total encrypted bytes retained before the oldest entries are dropped.
    private let maxBytes: Int
    /// Hard cap on entry count, independent of the byte budget.
    private let maxEntries: Int
    /// Items larger than this are not captured at all.
    private let maxItemBytes: Int

    /// True once an activation attempt has finished, including failures.
    /// `canCapture` also requires a usable key and healthy storage.
    @Published private(set) var isActivated = false

    /// Set when activation could not obtain a key at all — the Keychain
    /// refused a read or a first-use write. Distinct from `isLockedOut`, which
    /// means a key exists but does not open what is stored.
    ///
    /// Without this the two failure modes are indistinguishable from success
    /// on a fresh install: no key, no entries, no error, and every copy
    /// silently discarded forever.
    @Published private(set) var isKeyUnavailable = false

    /// Whether a capture can actually be sealed and stored right now.
    var canCapture: Bool {
        isActivated && !isActivating && !isKeyUnavailable && !isLockedOut
            && !isMetadataCorrupt && !isStorageUnavailable
    }

    /// Transient writes may be retried only after history was read or proven empty.
    var canAttemptCapture: Bool {
        isActivated && !isActivating && !isKeyUnavailable && !isLockedOut
            && !isMetadataCorrupt && (!isStorageUnavailable || loadedMetadata)
    }

    /// The most recent copy that was too large to store, until dismissed.
    ///
    /// A clipboard manager that silently drops a copy is worse than one that
    /// refuses loudly — "I copied it and it isn't there" with no explanation
    /// reads as data loss. Screen grabs are the realistic trigger: macOS puts
    /// both TIFF and PNG on the pasteboard, and uncompressed TIFF alone is
    /// ~59 MB at 5K and ~81 MB at 6K.
    @Published private(set) var lastOversizedSkip: OversizedSkip?

    struct OversizedSkip: Equatable {
        let date: Date
        let byteCount: Int
        let limit: Int
    }

    func dismissOversizedSkip() {
        lastOversizedSkip = nil
    }

    private let fileOperations: ClipboardFileOperations
    private var storedEntries: [StoredClipboardEntry] = []
    private var unreadablePreviews: [UUID: String] = [:]
    private var captureWorkItems: [UUID: DispatchWorkItem] = [:]
    private let directory: URL
    private let metadataURL: URL
    private let metadataQuarantineMarkerURL: URL
    private let migrationBackupURL: URL
    private let blobsDirectory: URL
    private let thumbsDirectory: URL
    /// Main-thread owned. Resolved by `activate()`, off the launch path.
    private var crypto: ClipboardCrypto?
    /// A key supplied by the caller (tests). Present means `activate()` must
    /// not go near the Keychain.
    private let injectedCrypto: ClipboardCrypto?
    /// Overrides key resolution entirely, including the ability to return nil.
    /// The only way to exercise the no-key path without touching the real
    /// login Keychain, which tests must never do.
    private let cryptoProvider: (() -> ClipboardCrypto?)?

    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "clipboard-store")
    private let blobQueue = DispatchQueue(label: "com.matt.voice-dictation.clipboard-blobs")
    private var saveWorkItem: DispatchWorkItem?
    /// Completed blob writes awaiting their main-thread metadata insert. This
    /// is owned by `blobQueue` so `flush()` can include them before exit.
    private var completedInsertions: [(ClipboardEntry, String)] = []
    /// A corrupt metadata file cannot distinguish orphaned blobs from
    /// recoverable history. Preserve files and refuse automatic writes.
    @Published private(set) var isMetadataCorrupt = false
    /// A non-decode disk failure pauses this instance without leaving a
    /// persistent quarantine marker behind. A later successful save or launch
    /// clears it.
    @Published private(set) var isStorageUnavailable = false

    /// Secure Input (a password field, or Terminal's Secure Keyboard Entry)
    /// hides copies from every clipboard manager. Shown so a silent gap in
    /// history has a visible cause.
    @Published private(set) var isSecureInputActive = false

    func noteSecureInput(_ active: Bool) {
        let apply = { if self.isSecureInputActive != active { self.isSecureInputActive = active } }
        Thread.isMainThread ? apply() : DispatchQueue.main.async(execute: apply)
    }
    private var loadedMetadata = false

    /// Guards `activate()` against re-entry while its Keychain resolution is
    /// still in flight, when `isActivated` is not yet true.
    private var isActivating = false

    /// Fingerprints whose blob write is in flight. `shouldSkip` consults this
    /// alongside the newest entry: the insert only happens after the seal and
    /// write return, so without it two identical copies arriving inside one
    /// write — plausible for a large image against a 0.5s poll — both pass the
    /// newest-entry check and both land.
    private var inFlightFingerprints: Set<String> = []

    init(
        directory: URL? = nil,
        crypto: ClipboardCrypto? = nil,
        cryptoProvider: (() -> ClipboardCrypto?)? = nil,
        fileOperations: ClipboardFileOperations = ClipboardFileOperations(),
        maxBytes: Int = 1_000_000_000,
        maxEntries: Int = 2000,
        // 128 MB: a full-screen 6K grab carries ~81 MB of uncompressed TIFF
        // plus a PNG alongside it, and the cap counts every representation
        // together. One item can still only eat an eighth of `maxBytes`.
        maxItemBytes: Int = 128_000_000
    ) {
        self.cryptoProvider = cryptoProvider
        self.fileOperations = fileOperations
        let root = directory ?? ClipboardStore.defaultDirectory()
        self.directory = root
        self.metadataURL = root.appendingPathComponent("clipboard.json")
        self.metadataQuarantineMarkerURL = root.appendingPathComponent("clipboard.json.quarantine")
        self.migrationBackupURL = root.appendingPathComponent("clipboard.json.pre-migration-backup")
        self.blobsDirectory = root.appendingPathComponent("blobs", isDirectory: true)
        self.thumbsDirectory = root.appendingPathComponent("thumbs", isDirectory: true)
        self.maxBytes = maxBytes
        self.maxEntries = maxEntries
        self.maxItemBytes = maxItemBytes
        self.injectedCrypto = crypto

        load()
    }

    /// Resolves the blob key, checks it against what is already stored, and
    /// runs the retention and reconciliation passes. Returns immediately; the
    /// work happens off the calling thread.
    ///
    /// This is deliberately not part of `init`. Resolving the key is a
    /// synchronous Keychain call, and this app has already shipped one launch
    /// hang caused by doing Keychain work on the main thread at startup — a
    /// locked login keychain can block on a system prompt. Probing a blob adds
    /// a disk read and a decrypt on top of that.
    /// Call on the main thread. Successful activation is idempotent; an
    /// unavailable key can be retried later, without concurrent resolutions.
    func activate() {
        guard (!isActivated || isKeyUnavailable), !isActivating else { return }
        isActivating = true
        let probeOrder = entries.sorted { $0.byteCount < $1.byteCount }.map(\.id)
        let injected = injectedCrypto
        let provider = cryptoProvider
        // Deliberately NOT `blobQueue`: `flush()` drains that queue with a
        // blocking `sync`, and resolving a key can stall on a locked login
        // keychain. Sharing the queue would let a quit during activation hang
        // the main thread. Probing reads only existing blob ids, which no
        // concurrent write touches.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // Not `provider?() ?? injected ?? resolve()`: optional chaining
            // flattens "no provider" and "provider returned nil" into the same
            // nil, so an override that deliberately returns no key would fall
            // through to the real Keychain — which tests must never touch.
            let resolved: ClipboardCrypto?
            if let provider {
                resolved = provider()
            } else {
                resolved = injected ?? ClipboardStore.resolveCrypto()
            }
            let locked = (!probeOrder.isEmpty || resolved != nil)
                && !self.canOpenStoredBlob(probeOrder: probeOrder, using: resolved)
            DispatchQueue.main.async {
                self.crypto = resolved
                self.isKeyUnavailable = resolved == nil
                self.isLockedOut = locked
                guard let resolved, !locked, !self.isMetadataCorrupt else {
                    self.isActivating = false
                    self.isActivated = true
                    return
                }
                do {
                    try FileManager.default.createDirectory(at: self.blobsDirectory, withIntermediateDirectories: true)
                    try FileManager.default.createDirectory(at: self.thumbsDirectory, withIntermediateDirectories: true)
                } catch {
                    self.storageFailure(error)
                    self.isActivating = false
                    self.isActivated = true
                    return
                }
                let needsMigration = self.storedEntries.contains { $0.preview != nil }
                self.entries = self.storedEntries.map { stored in
                    var entry = stored.entry
                    if let sealed = stored.sealedPreview {
                        if let data = try? resolved.open(sealed),
                           let preview = String(data: data, encoding: .utf8) {
                            entry.preview = preview
                        } else {
                            // A damaged row must not turn an otherwise usable
                            // history into a whole-store lockout.
                            entry.preview = "Unavailable clipboard item"
                        }
                    }
                    return entry
                }
                if needsMigration { self.save() }
                guard !self.isLockedOut, !self.isMetadataCorrupt else {
                    self.isActivating = false
                    self.isActivated = true
                    return
                }
                self.reconcileBlobsWithMetadata {
                    self.pruneToBudget()
                    self.isActivating = false
                    self.isActivated = true
                }
            }
        }
    }

    /// The Clipboard view gets one user-driven retry after a transient
    /// Keychain denial. It never polls, enumerates, or retries a wrong key.
    func retryKeyIfUnavailable() {
        guard isKeyUnavailable else { return }
        activate()
    }

    // MARK: - Paths and key

    private static func defaultDirectory() -> URL {
        VoicePaths.prepareApplicationSupportVoiceDirectory()
        return VoicePaths.applicationSupportVoiceDirectory
            .appendingPathComponent("Clipboard", isDirectory: true)
    }

    /// Loads the blob key, minting one on first use. Returns `nil` only when
    /// the Keychain refuses to hand over or store a key — the store then
    /// captures nothing rather than falling back to plaintext on disk.
    private static func resolveCrypto() -> ClipboardCrypto? {
        // Hard stop under XCTest. Tests must inject a key or a provider; a test
        // process reaching the real login Keychain is how this app lost the
        // user's live xAI API key once already, and a bug in this very method's
        // optional handling silently did it again while it was being written.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            assertionFailure("ClipboardStore must not resolve a real Keychain key under test")
            return nil
        }
        return resolveCrypto(keychain: KeychainStore(service: ClipboardKeyStore.service))
    }

    static func resolveCrypto(keychain: KeychainStore) -> ClipboardCrypto? {
        do {
            let key = try ClipboardKeyStore.loadKey(keychain: keychain)
                ?? ClipboardKeyStore.createKey(keychain: keychain)
            return ClipboardCrypto(key: key)
        } catch {
            return nil
        }
    }

    /// Ground-truth check that `candidate` opens what is already stored.
    ///
    /// `probeOrder` is smallest-blob-first so a history of large screenshots
    /// does not turn this into a stall. It walks past ids whose blob is missing
    /// rather than stopping at the first one: a missing blob is a reconcile
    /// problem, and treating it as a key failure would tell the user their
    /// history is encrypted shut when it is merely incomplete.
    private func canOpenStoredBlob(probeOrder: [UUID], using candidate: ClipboardCrypto?) -> Bool {
        guard let candidate else { return false }
        var hasEncryptedComponent = false
        for stored in storedEntries {
            guard let sealed = stored.sealedPreview else { continue }
            hasEncryptedComponent = true
            if (try? candidate.open(sealed)) != nil { return true }
        }
        for id in probeOrder {
            let url = blobURL(for: id)
            guard let sealed = try? Data(contentsOf: url) else { continue }
            hasEncryptedComponent = true
            if (try? candidate.open(sealed)) != nil { return true }
        }
        // Every blob may be gone; only an encrypted component that could not
        // be opened establishes a wrong/missing key.
        return !hasEncryptedComponent
    }

    // MARK: - Load / save

    private func load() {
        if FileManager.default.fileExists(atPath: metadataQuarantineMarkerURL.path) {
            if recoverDowngradeQuarantine() { return }
            isMetadataCorrupt = true
            return
        }
        let data: Data
        do {
            data = try fileOperations.read(metadataURL)
        } catch {
            if !Self.isMissingFile(error) { storageFailure(error) }
            return
        }
        do {
            storedEntries = try decodeStoredEntries(data)
            entries = storedEntries.map(\.entry)
            loadedMetadata = true
        } catch {
            quarantineCorruptFile(error: error)
        }
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
    }

    private func decodeStoredEntries(_ data: Data) throws -> [StoredClipboardEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([StoredClipboardEntry].self, from: data)
        guard decoded.allSatisfy({ $0.preview != nil || $0.sealedPreview != nil }) else {
            throw ClipboardCryptoError.keyUnavailable
        }
        return decoded
    }

    /// Older builds quarantine the encrypted-preview schema because their
    /// nonoptional plaintext `preview` cannot decode `null`. Prefer a current
    /// metadata file, then only restore the newest quarantined current-format
    /// generation while no metadata exists, so stale recovery never overwrites
    /// a newer file.
    private func recoverDowngradeQuarantine() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: metadataURL.path) {
            guard let data = try? fileOperations.read(metadataURL),
                  let decoded = try? decodeStoredEntries(data) else { return false }
            do {
                try archiveSupersededQuarantines(by: decoded)
                try fm.removeItem(at: metadataQuarantineMarkerURL)
                storedEntries = decoded
                entries = decoded.map(\.entry)
                loadedMetadata = true
                return true
            } catch {
                storageFailure(error)
                return false
            }
        }

        let prefix = metadataURL.lastPathComponent + ".corrupt."
        guard let candidates = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ).filter({ $0.lastPathComponent.hasPrefix(prefix) }) else { return false }
        let newestFirst = candidates.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhs > rhs
        }
        guard let candidate = newestFirst.first,
              let data = try? fileOperations.read(candidate),
              let decoded = try? decodeStoredEntries(data) else { return false }
        do {
            try fm.moveItem(at: candidate, to: metadataURL)
            try archiveSupersededQuarantines(by: decoded)
            try fm.removeItem(at: metadataQuarantineMarkerURL)
            storedEntries = decoded
            entries = decoded.map(\.entry)
            loadedMetadata = true
            return true
        } catch {
            storageFailure(error)
            return false
        }
    }

    /// Archive only readable generations whose rows remain in recovered metadata.
    /// Unknown siblings still protect history from orphan cleanup.
    private func archiveSupersededQuarantines(by decoded: [StoredClipboardEntry]) throws {
        let prefix = metadataURL.lastPathComponent + ".corrupt."
        let known = Set(decoded.map(\.id))
        for url in try fileOperations.contents(directory) where url.lastPathComponent.hasPrefix(prefix) {
            guard let data = try? fileOperations.read(url),
                  let rows = try? decodeStoredEntries(data),
                  Set(rows.map(\.id)).isSubset(of: known) else { continue }
            let archived = directory.appendingPathComponent("clipboard.json.recovered.\(UUID().uuidString)")
            try FileManager.default.moveItem(at: url, to: archived)
        }
    }

    /// The fixed backup filename is write-once and owner-only from creation.
    private func preserveMigrationBackup() throws {
        let data = try fileOperations.read(metadataURL)
        let descriptor = Darwin.open(migrationBackupURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            if errno == EEXIST { return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: migrationBackupURL)
            throw error
        }
    }

    private func storageFailure(_ error: Error) {
        isStorageUnavailable = true
        logger.error("Clipboard storage unavailable: \(error.localizedDescription)")
    }

    private func quarantineCorruptFile(error decodeError: Error) {
        let bak = URL(fileURLWithPath: metadataURL.path + ".corrupt.\(Int(Date().timeIntervalSince1970))")
        do {
            try FileManager.default.moveItem(at: metadataURL, to: bak)
            try fileOperations.write(Data(), metadataQuarantineMarkerURL)
            logger.error("Quarantined corrupt clipboard.json → \(bak.lastPathComponent): \(decodeError.localizedDescription)")
        } catch {
            logger.error("Failed to quarantine corrupt clipboard.json: \(error.localizedDescription); original decode error: \(decodeError.localizedDescription)")
        }
        entries = []
        isMetadataCorrupt = true
    }

    private func save() {
        guard !isMetadataCorrupt, !isLockedOut,
              !(isStorageUnavailable && !loadedMetadata), let crypto else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            if storedEntries.contains(where: { $0.preview != nil }) {
                try preserveMigrationBackup()
            }
            var previous: [UUID: StoredClipboardEntry] = [:]
            for entry in storedEntries { previous[entry.id] = entry }
            let stored = try entries.map { entry -> StoredClipboardEntry in
                if let sealed = previous[entry.id]?.sealedPreview,
                   previous[entry.id]?.preview == nil {
                    return StoredClipboardEntry(entry: entry, sealedPreview: sealed)
                }
                var original = entry
                if let preview = unreadablePreviews[entry.id] { original.preview = preview }
                return try StoredClipboardEntry(entry: original, crypto: crypto)
            }
            try fileOperations.write(try encoder.encode(stored), metadataURL)
            storedEntries = stored
            loadedMetadata = true
            isStorageUnavailable = false
        } catch {
            storageFailure(error)
        }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Persists metadata immediately, after letting in-flight blob writes
    /// finish so the file describes what is actually on disk.
    ///
    /// Completed blob writes are committed synchronously before the save, so
    /// a quit cannot turn a just-written capture into an orphan.
    func flush() {
        blobQueue.sync {}
        commitCompletedInsertions()
        saveWorkItem?.cancel()
        saveWorkItem = nil
        save()
    }

    /// Moves completed blob writes into the published metadata on the main
    /// thread. `flush()` calls this after draining `blobQueue`, before saving.
    private func commitCompletedInsertions() {
        let completed = blobQueue.sync {
            let completed = completedInsertions
            completedInsertions.removeAll()
            return completed
        }
        guard !completed.isEmpty else { return }
        for (entry, fingerprint) in completed {
            inFlightFingerprints.remove(fingerprint)
            captureWorkItems.removeValue(forKey: entry.id)
        }
        entries.insert(contentsOf: completed.map { $0.0 }.reversed(), at: 0)
        pruneToBudget()
        scheduleSave()
    }

    // MARK: - Reconciliation

    /// Reconciles both directions between the blobs directory and the metadata:
    /// blob files with no entry are deleted, entries with no blob are dropped.
    ///
    /// Blob writes and metadata saves cannot be made atomic with respect to
    /// each other — the write lands immediately and the save is debounced — so
    /// a quit or crash in between leaves an orphan. Nothing else ever collects
    /// those, and because the retention budget only counts bytes it knows
    /// about, they would accumulate invisibly and forever.
    private func reconcileBlobsWithMetadata(completion: @escaping () -> Void) {
        guard !isMetadataCorrupt, !isStorageUnavailable, !isKeyUnavailable, !isLockedOut else {
            completion()
            return
        }
        let known = Set(entries.map(\.id.uuidString))
        blobQueue.async { [weak self] in
            guard let self else { return }
            do {
                // Both enumerations must succeed before deleting anything.
                let files = try self.fileOperations.contents(self.blobsDirectory).filter {
                    !$0.lastPathComponent.hasPrefix(".") && !$0.lastPathComponent.hasSuffix(".tmp")
                }
                let thumbs = try self.fileOperations.contents(self.thumbsDirectory)
                let hasCorruptSibling = try self.fileOperations.contents(self.directory).contains {
                    $0.lastPathComponent.hasPrefix(self.metadataURL.lastPathComponent + ".corrupt.")
                }
                // With no readable metadata, blobs and corrupt siblings are
                // unknown history, not proven orphans. Pause capture rather
                // than write fresh metadata that would make a later launch
                // sweep the preserved files.
                guard self.loadedMetadata || (files.isEmpty && !hasCorruptSibling) else {
                    DispatchQueue.main.async {
                        if !self.loadedMetadata { self.isMetadataCorrupt = true }
                        completion()
                    }
                    return
                }
                guard !hasCorruptSibling else {
                    DispatchQueue.main.async { completion() }
                    return
                }
                let present = Set(files.map(\.lastPathComponent)).intersection(known)
                for url in files + thumbs where !known.contains(url.lastPathComponent) {
                    try self.fileOperations.remove(url)
                }
                let missing = known.subtracting(present)
                DispatchQueue.main.async {
                    self.loadedMetadata = true
                    if !missing.isEmpty {
                        self.entries.removeAll { missing.contains($0.id.uuidString) }
                        self.scheduleSave()
                    }
                    completion()
                }
            } catch {
                DispatchQueue.main.async {
                    self.storageFailure(error)
                    completion()
                }
            }
        }
    }

    // MARK: - Capture

    private func blobURL(for id: UUID) -> URL {
        blobsDirectory.appendingPathComponent(id.uuidString)
    }

    private func thumbURL(for id: UUID) -> URL {
        thumbsDirectory.appendingPathComponent(id.uuidString)
    }

    /// The sealed row thumbnail for `entry`, or `nil` when it has none (any
    /// non-image kind) or it cannot be opened.
    func thumbnail(for entry: ClipboardEntry) -> Data? {
        guard entry.kind == .image, let crypto else { return nil }
        guard let sealed = try? Data(contentsOf: thumbURL(for: entry.id)) else { return nil }
        return try? crypto.open(sealed)
    }

    /// True when `snapshot` is content this store should skip: filtered types,
    /// empty payloads, oversized items, or a repeat of content already newest
    /// or already being written.
    ///
    /// The repeat check is what absorbs `TextInjector`'s pasteboard restore:
    /// the content it puts back was on the pasteboard before the dictation, so
    /// it is already this store's top entry.
    /// The fingerprint to record `snapshot` under, or `nil` when it should be
    /// skipped.
    ///
    /// Returning the fingerprint rather than a bare Bool is deliberate: it
    /// hashes the entire payload, this runs on the main thread, and computing
    /// it once for the skip check and again for the entry doubled that cost on
    /// payloads as large as `maxItemBytes`.
    func captureFingerprint(
        snapshot: TextInjector.PasteboardSnapshot,
        types: [String]
    ) -> String? {
        if snapshot.isEmpty { return nil }
        if ClipboardTypeFilter.shouldIgnore(types: types) { return nil }
        let payloadBytes = snapshot.reduce(0) { total, item in
            total + item.values.reduce(0) { $0 + $1.count }
        }
        if payloadBytes == 0 { return nil }
        if payloadBytes > maxItemBytes {
            lastOversizedSkip = OversizedSkip(
                date: Date(),
                byteCount: payloadBytes,
                limit: maxItemBytes
            )
            return nil
        }
        let fingerprint = ClipboardFingerprint.fingerprint(for: snapshot)
        if fingerprint == entries.first?.fingerprint { return nil }
        if inFlightFingerprints.contains(fingerprint) { return nil }
        return fingerprint
    }

    /// Captures `snapshot` into the history. Call on the main thread; sealing,
    /// the disk write, and preview generation all happen off it, and the entry
    /// appears once the blob is safely on disk.
    func record(snapshot: TextInjector.PasteboardSnapshot, sourceBundleID: String?) {
        guard canAttemptCapture, let crypto else { return }
        let types = Array(Set(snapshot.flatMap { $0.keys.map(\.rawValue) })).sorted()
        guard let fingerprint = captureFingerprint(snapshot: snapshot, types: types) else { return }

        let id = UUID()
        let date = Date()
        let kind = ClipboardCapture.kind(for: types)
        let url = blobURL(for: id)
        inFlightFingerprints.insert(fingerprint)

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let written: Int
            let preview: String
            do {
                let plist = snapshot.map { item in
                    Dictionary(uniqueKeysWithValues: item.map { ($0.key.rawValue, $0.value) })
                }
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let sealed = try crypto.seal(try encoder.encode(plist))
                try self.fileOperations.write(sealed, url)
                written = sealed.count

                // Best-effort: a missing thumbnail costs the row its preview
                // image, never the entry itself.
                if kind == .image,
                   let imageData = snapshot.first?[.png] ?? snapshot.first?[.tiff],
                   let thumb = ClipboardCapture.makeThumbnail(from: imageData),
                   let sealedThumb = try? crypto.seal(thumb) {
                    try? sealedThumb.write(to: self.thumbURL(for: id), options: .atomic)
                }
                // Off the main thread deliberately: image previews read pixel
                // dimensions, and `record` is driven by a main-thread timer
                // that shares its thread with the dictation HUD and injection.
                preview = ClipboardCapture.preview(kind: kind, snapshot: snapshot, types: types)
            } catch {
                self.logger.error("Clipboard blob write failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.inFlightFingerprints.remove(fingerprint)
                    self.captureWorkItems.removeValue(forKey: id)
                    self.storageFailure(error)
                }
                return
            }
            self.completedInsertions.append((
                ClipboardEntry(
                    id: id,
                    date: date,
                    kind: kind,
                    preview: preview,
                    sourceBundleID: sourceBundleID,
                    types: types,
                    byteCount: written,
                    fingerprint: fingerprint
                ),
                fingerprint
            ))
            DispatchQueue.main.async { self.commitCompletedInsertions() }
        }
        captureWorkItems[id] = work
        blobQueue.async(execute: work)
    }

    /// Drops the oldest entries until both the byte budget and the count cap
    /// are satisfied, deleting their blobs.
    private func pruneToBudget() {
        guard !isMetadataCorrupt, !isStorageUnavailable, !isLockedOut, !isKeyUnavailable else { return }
        var running = 0
        var keep: [ClipboardEntry] = []
        var drop: [ClipboardEntry] = []
        for entry in entries {
            running += entry.byteCount
            if keep.count < maxEntries && running <= maxBytes {
                keep.append(entry)
            } else {
                drop.append(entry)
            }
        }
        guard !drop.isEmpty else { return }
        guard deleteBlobs(for: drop.map(\.id)) else { return }
        entries = keep
        scheduleSave()
    }

    @discardableResult
    private func deleteBlobs(for ids: [UUID]) -> Bool {
        do {
            try blobQueue.sync {
                for id in ids {
                    for url in [blobURL(for: id), thumbURL(for: id)] {
                        do {
                            try fileOperations.remove(url)
                        } catch {
                            if !Self.isMissingFile(error) { throw error }
                        }
                    }
                }
            }
            return true
        } catch {
            storageFailure(error)
            return false
        }
    }

    // MARK: - Read back

    /// A single broken payload is reported on that row only. The original
    /// sealed preview remains in `storedEntries`, so a later metadata save
    /// cannot replace it with this neutral display value.
    private func markUnreadable(_ id: UUID) {
        let mutate = {
            guard let index = self.entries.firstIndex(where: { $0.id == id }) else { return }
            if self.unreadablePreviews[id] == nil {
                self.unreadablePreviews[id] = self.entries[index].preview
            }
            self.entries[index].preview = "Unavailable clipboard item"
        }
        if Thread.isMainThread {
            mutate()
        } else {
            DispatchQueue.main.async(execute: mutate)
        }
    }

    /// Decrypts and returns the full multi-representation payload for `entry`.
    ///
    /// Synchronous: it reads and decrypts the whole blob on the calling thread.
    /// Entries run up to `maxItemBytes`, so UI code must not call this on the
    /// main thread in response to a click without moving it off first.
    func payload(for entry: ClipboardEntry) -> TextInjector.PasteboardSnapshot? {
        guard let crypto else { return nil }
        guard let sealed = try? Data(contentsOf: blobURL(for: entry.id)) else {
            markUnreadable(entry.id)
            return nil
        }
        do {
            let opened = try crypto.open(sealed)
            let plist = try PropertyListDecoder().decode([[String: Data]].self, from: opened)
            return plist.map { item in
                Dictionary(uniqueKeysWithValues: item.map {
                    (NSPasteboard.PasteboardType(rawValue: $0.key), $0.value)
                })
            }
        } catch {
            logger.error("Clipboard blob open failed: \(error.localizedDescription)")
            markUnreadable(entry.id)
            return nil
        }
    }

    /// Read-only display metric. The encrypted blob's byte count includes
    /// alternate pasteboard representations and encryption overhead, so it is
    /// not a user-facing size. Select one pasteable representation per item;
    /// call this off the main thread.
    func pasteableByteCount(for entry: ClipboardEntry) -> Int? {
        guard let snapshot = payload(for: entry) else { return nil }
        var total = 0
        for item in snapshot {
            let representation: Data?
            switch entry.kind {
            case .text:
                representation = item[.string]
            case .image:
                representation = item[.png] ?? item[.tiff]
            case .other:
                representation = ClipboardFingerprint.canonicalPayload(of: item)
            case .files:
                return nil
            }
            guard let representation else { return nil }
            total += representation.count
        }
        return total
    }

    /// Puts `entry` back on the pasteboard with every representation it was
    /// captured with — reusing `TextInjector`'s restore, which is the same
    /// operation this app already performs after every dictation.
    /// `pasteboard` is injectable so tests can exercise this without writing to
    /// the user's real clipboard.
    @discardableResult
    func copyToPasteboard(
        _ entry: ClipboardEntry,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard let snapshot = payload(for: entry) else { return false }
        TextInjector.restorePasteboardSnapshot(snapshot, on: pasteboard)
        return true
    }

    // MARK: - Mutation

    func delete(_ entry: ClipboardEntry) {
        let mutate = {
            guard !self.isMetadataCorrupt,
                  self.deleteBlobs(for: [entry.id]) else { return }
            self.entries.removeAll { $0.id == entry.id }
            self.unreadablePreviews.removeValue(forKey: entry.id)
            self.scheduleSave()
        }
        Thread.isMainThread ? mutate() : DispatchQueue.main.async(execute: mutate)
    }

    func clearAll() {
        let mutate = {
            guard !self.isMetadataCorrupt else { return }
            self.saveWorkItem?.cancel()
            self.saveWorkItem = nil
            let pendingIDs = Array(self.captureWorkItems.keys)
            for work in self.captureWorkItems.values { work.cancel() }
            self.blobQueue.sync { self.completedInsertions.removeAll() }
            self.captureWorkItems.removeAll()
            self.inFlightFingerprints.removeAll()
            let ids = Array(Set(self.entries.map(\.id) + pendingIDs))
            guard self.deleteBlobs(for: ids) else { return }
            do {
                let archives = try self.fileOperations.contents(self.directory).filter {
                    $0.lastPathComponent.hasPrefix("clipboard.json.recovered.")
                }
                for url in archives { try self.fileOperations.remove(url) }
                do {
                    try self.fileOperations.remove(self.migrationBackupURL)
                } catch {
                    if !Self.isMissingFile(error) { throw error }
                }
            } catch {
                if !Self.isMissingFile(error) {
                    self.storageFailure(error)
                    return
                }
            }
            self.entries = []
            self.storedEntries = []
            self.unreadablePreviews.removeAll()
            self.isLockedOut = false
            self.scheduleSave()
        }
        Thread.isMainThread ? mutate() : DispatchQueue.main.async(execute: mutate)
    }

    /// Deletes the preserved files only after the user confirms recovery from
    /// corrupt metadata. Until this runs successfully, the quarantine marker
    /// keeps capture and reconciliation off so unknown blobs are never swept.
    func discardCorruptHistory() {
        let mutate = {
            guard self.isMetadataCorrupt else { return }
            self.saveWorkItem?.cancel()
            self.saveWorkItem = nil

            let root = self.directory
            let metadata = self.metadataURL
            let marker = self.metadataQuarantineMarkerURL
            let backup = self.migrationBackupURL
            let blobs = self.blobsDirectory
            let thumbs = self.thumbsDirectory
            self.blobQueue.async { [weak self] in
                guard let self else { return }
                let fm = FileManager.default
                var succeeded = true
                for directory in [blobs, thumbs] {
                    let files: [URL]
                    do {
                        files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    } catch {
                        // A positively absent directory is already empty. Any
                        // other enumeration failure means deletion is unknown,
                        // so retain quarantine mode and its marker.
                        let fileError = error as NSError
                        if fileError.domain == NSCocoaErrorDomain,
                           [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(fileError.code) {
                            files = []
                        } else {
                            succeeded = false
                            self.logger.error("Failed to enumerate corrupt clipboard recovery files: \(error.localizedDescription)")
                            continue
                        }
                    }
                    for url in files {
                        do {
                            try fm.removeItem(at: url)
                        } catch {
                            succeeded = false
                            self.logger.error("Failed to remove corrupt clipboard recovery file: \(error.localizedDescription)")
                        }
                    }
                }
                // The decoder moves the bad metadata here. Remove every
                // quarantined generation only during this explicit recovery.
                let prefix = metadata.lastPathComponent + ".corrupt."
                let rootFiles: [URL]
                do {
                    rootFiles = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                } catch {
                    succeeded = false
                    rootFiles = []
                    self.logger.error("Failed to enumerate quarantined clipboard metadata: \(error.localizedDescription)")
                }
                for url in rootFiles where url.lastPathComponent.hasPrefix(prefix)
                    || url.lastPathComponent.hasPrefix("clipboard.json.recovered.")
                    || url.lastPathComponent == backup.lastPathComponent {
                    do {
                        try fm.removeItem(at: url)
                    } catch {
                        succeeded = false
                        self.logger.error("Failed to remove quarantined clipboard metadata: \(error.localizedDescription)")
                    }
                }
                if fm.fileExists(atPath: metadata.path) {
                    do {
                        try fm.removeItem(at: metadata)
                    } catch {
                        succeeded = false
                        self.logger.error("Failed to remove corrupt clipboard metadata: \(error.localizedDescription)")
                    }
                }
                guard succeeded else { return }
                do {
                    try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
                    try fm.createDirectory(at: thumbs, withIntermediateDirectories: true)
                } catch {
                    self.logger.error("Failed to prepare clipboard recovery directories: \(error.localizedDescription)")
                    return
                }
                do {
                    try fm.removeItem(at: marker)
                } catch {
                    if !Self.isMissingFile(error) {
                        self.logger.error("Failed to finish corrupt clipboard recovery: \(error.localizedDescription)")
                        return
                    }
                }
                DispatchQueue.main.async {
                    guard self.isMetadataCorrupt else { return }
                    self.isMetadataCorrupt = false
                    self.isLockedOut = false
                    self.entries = []
                    self.storedEntries = []
                    self.unreadablePreviews.removeAll()
                    self.loadedMetadata = true
                    self.save()
                }
            }
        }
        Thread.isMainThread ? mutate() : DispatchQueue.main.async(execute: mutate)
    }
}
