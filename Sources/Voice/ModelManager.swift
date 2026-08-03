import Foundation
import os.log
import WhisperKit

// MARK: - Per-model download / storage state

/// Lifecycle state for an individual model's on-disk presence, published by
/// `ModelManager` and consumed by Settings UI.
enum ModelDownloadState: Equatable {
    case idle
    case downloading
    case failed(String)
}

// MARK: - Model Manager

/// Owns per-model on-disk storage management for the WhisperKit-backed
/// `LocalModel` cases: checking whether a model is already downloaded, its
/// disk footprint, triggering an explicit (progress-reporting) download, and
/// deleting an individual model's folder.
///
/// WHY THIS EXISTS: `WhisperKitEngine` previously called `WhisperKit(model:)`
/// directly, which silently triggers `WhisperKit.setupModels` → an implicit,
/// no-progress, no-cancellation multi-GB download on first transcription.
/// `ModelManager` makes that download explicit, observable, and recoverable
/// — `WhisperKitEngine` now only loads from an already-downloaded model
/// folder (see its `modelFolder` support), and model *acquisition* is owned
/// here, triggered by Settings model selection.
///
/// STORAGE LAYOUT (verified against the WhisperKit + swift-transformers
/// source, `build/SourcePackages/checkouts/{WhisperKit,swift-transformers}/`,
/// not guessed):
///   - `WhisperKit.download(variant:downloadBase:...progressCallback:)`
///     (`Sources/WhisperKit/Core/WhisperKit.swift`) is the explicit,
///     progress-reporting static download entry point — the same one
///     `setupModels` calls implicitly. It resolves the HF repo
///     "argmaxinc/whisperkit-coreml", downloads via `HubApi.snapshot`, and
///     returns the model's on-disk folder URL.
///   - `HubApi.init(downloadBase:)` (`swift-transformers/Sources/Hub/HubApi.swift`)
///     defaults `downloadBase` to `~/Documents/huggingface` when nil, and
///     `localRepoLocation` resolves to
///     `downloadBase/models/<repo.id>` — i.e.
///     `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/`.
///     `WhisperKit.download` then appends the resolved variant folder name
///     (e.g. `openai_whisper-base`) to that snapshot path. Confirmed
///     empirically on this machine: `openai_whisper-base` already exists
///     there from a prior implicit download.
///   - We pass `downloadBase` explicitly (rather than relying on the nil
///     default) ONLY so `ModelManager` and `WhisperKitEngine` are guaranteed
///     to agree on the same location without depending on an unstated
///     Documents-folder default — both read `ModelManager.downloadBase`.
@MainActor
final class ModelManager: ObservableObject {

    /// 0...1 progress per in-flight download. Absence of a key means "not
    /// currently downloading" (check `state` for idle/failed distinction).
    @Published private(set) var downloadProgress: [LocalModel: Double] = [:]

    /// Per-model lifecycle state.
    @Published private(set) var state: [LocalModel: ModelDownloadState] = [:]

    /// Cached disk size in bytes per model, refreshed by `refreshStatus`.
    @Published private(set) var diskSize: [LocalModel: Int64] = [:]

    /// Cached downloaded/not-downloaded flag per model, refreshed by
    /// `refreshStatus`.
    @Published private(set) var downloaded: [LocalModel: Bool] = [:]

    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "model-manager")

    /// Shared HF download base — same value `WhisperKitEngine` must use so
    /// both agree on where a given model's files live. Explicit (not nil)
    /// so this doesn't silently drift if a future WhisperKit version changes
    /// its nil-default resolution.
    nonisolated static let downloadBase: URL = VoicePaths.modelsDirectory

    private nonisolated static let repo = "argmaxinc/whisperkit-coreml"

    private nonisolated static let legacyDocumentsHuggingFaceBase: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("huggingface", isDirectory: true)
    }()

    private nonisolated static let migrationLogger = Logger(
        subsystem: "com.matt.voice-dictation",
        category: "model-manager-migration"
    )

    /// In-flight download tasks, keyed by model, so a second `download(_:)`
    /// call for the same model awaits the existing task instead of racing a
    /// second HubApi snapshot for the same files.
    private var downloadTasks: [LocalModel: Task<Void, Never>] = [:]

    init() {
        VoicePaths.prepareApplicationSupportVoiceDirectory()
        Self.migrateWhisperKitModelsFromDocumentsIfNeeded()
        refreshAllStatus()
    }

    /// Moves `models/argmaxinc/whisperkit-coreml` from the legacy Documents
    /// huggingface cache into Application Support. Never blocks launch.
    private nonisolated static func migrateWhisperKitModelsFromDocumentsIfNeeded() {
        let oldRepo = legacyDocumentsHuggingFaceBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
        let newRepo = downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
        migrateWhisperKitModelsIfNeeded(from: oldRepo, to: newRepo)
    }

    /// Testable migration core. Production wraps real Documents → App Support
    /// paths; unit tests pass temp dirs.
    ///
    /// Rules: only-old → move; empty/unusable new + old → remove empty new then
    /// move; both usable → new wins, leave legacy orphan; sibling vendor dirs
    /// under `models/` are never touched.
    nonisolated static func migrateWhisperKitModelsIfNeeded(from oldRepo: URL, to newRepo: URL) {
        let fm = FileManager.default
        var oldIsDir: ObjCBool = false
        var newIsDir: ObjCBool = false
        let oldExists = fm.fileExists(atPath: oldRepo.path, isDirectory: &oldIsDir) && oldIsDir.boolValue
        let newExists = fm.fileExists(atPath: newRepo.path, isDirectory: &newIsDir) && newIsDir.boolValue

        if newExists {
            if whisperKitRepoHasUsableContent(newRepo) {
                if oldExists {
                    migrationLogger.info(
                        "WhisperKit migration: new cache present; leaving legacy orphan at \(oldRepo.path, privacy: .public)"
                    )
                }
                return
            }
            // Empty / unusable new: prefer migrating old content into place.
            guard oldExists else { return }
            do {
                try fm.removeItem(at: newRepo)
            } catch {
                migrationLogger.error(
                    "WhisperKit migration: could not clear empty new cache: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
        }

        guard oldExists else { return }

        let newParent = newRepo.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: newParent, withIntermediateDirectories: true)
            try fm.moveItem(at: oldRepo, to: newRepo)
            migrationLogger.info("WhisperKit migration: moved models to Application Support")
        } catch {
            migrationLogger.error(
                "WhisperKit migration failed: \(error.localizedDescription, privacy: .public); leaving legacy cache"
            )
        }
    }

    /// True when `repoURL` has at least one **variant subdirectory** that
    /// contains a non-metadata model file. Repo-root `config.json` / empty
    /// variants / config-only skeletons must return false so migration can
    /// still move a full legacy cache into place.
    nonisolated static func whisperKitRepoHasUsableContent(_ repoURL: URL) -> Bool {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: repoURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for child in children {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if variantFolderHasModelPayload(child) { return true }
        }
        return false
    }

    /// Hub skeletons often leave only JSON / README / tokenizer sidecars. A
    /// real WhisperKit variant has CoreML bundles with files inside, or
    /// explicit weight binaries — never hub metadata alone.
    private nonisolated static func variantFolderHasModelPayload(_ variantURL: URL) -> Bool {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: variantURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent.lowercased()
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])

            // Empty CoreML shell dirs must not count; require at least one
            // regular file under the bundle (checked when enumerator enters).
            if name.hasSuffix(".mlmodelc") || name.hasSuffix(".mlpackage") {
                continue
            }

            guard values?.isRegularFile == true else { continue }
            if Self.isModelWeightFileName(name) { return true }

            // Files nested inside a .mlmodelc / .mlpackage are payload even
            // when their leaf names are opaque (e.g. coremldata.bin, model.mil).
            let pathLower = fileURL.path.lowercased()
            if pathLower.contains(".mlmodelc/") || pathLower.contains(".mlpackage/") {
                return true
            }
        }
        return false
    }

    /// Allowlist of leaf names that count as downloaded WhisperKit weights
    /// outside a CoreML package. Hub sidecars (`tokenizer.model`, `*.json`,
    /// README, etc.) are intentionally excluded.
    private nonisolated static func isModelWeightFileName(_ lowercasedName: String) -> Bool {
        let weightSuffixes = [".bin", ".safetensors", ".mlmodel", ".pt", ".gguf", ".ggml", ".npz"]
        for suffix in weightSuffixes where lowercasedName.hasSuffix(suffix) {
            return true
        }
        return false
    }

    // MARK: - Status queries

    /// Whether `model`'s files are already present on disk. WhisperKit-backed
    /// models are considered downloaded if their variant folder has real
    /// model payload (CoreML package contents or weight binaries) — not hub
    /// metadata alone. Parakeet is handled best-effort via the HF cache
    /// (see `parakeetCacheInfo`) — never blocks on it.
    func isDownloaded(_ model: LocalModel) -> Bool {
        downloaded[model] ?? false
    }

    /// Cached on-disk footprint in bytes, or nil if unknown/not downloaded.
    func diskSizeBytes(_ model: LocalModel) -> Int64? {
        diskSize[model]
    }

    /// Human-readable size string (e.g. "1.6 GB"), or nil if unknown.
    func diskSizeDisplay(_ model: LocalModel) -> String? {
        guard let bytes = diskSize[model], bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Re-scans disk for every WhisperKit-backed model (off the main thread
    /// for the filesystem walk, hopped back to main to publish). Parakeet is
    /// checked best-effort via the HF cache.
    func refreshAllStatus() {
        for model in LocalModel.allCases {
            refreshStatus(model)
        }
    }

    /// Checks disk fresh (not the cached `downloaded` dict, which may not
    /// have been populated/updated yet) and kicks off `download(_:)` if the
    /// model isn't present. This is the selection→download entry point used
    /// by `SettingsStore` — it never trusts a stale cache to decide whether
    /// a multi-GB download is needed.
    func downloadIfNeeded(_ model: LocalModel) {
        guard !isSidecarManaged(model) else { return }
        Task {
            let (isPresent, bytes) = await Self.scanDisk(for: model)
            self.downloaded[model] = isPresent
            self.diskSize[model] = bytes
            if !isPresent {
                self.download(model)
            }
        }
    }

    func refreshStatus(_ model: LocalModel) {
        Task {
            let (isPresent, bytes) = await Self.scanDisk(for: model)
            self.downloaded[model] = isPresent
            self.diskSize[model] = bytes
        }
    }

    /// Filesystem scan, off the main actor. Returns (present, totalBytes).
    private nonisolated static func scanDisk(for model: LocalModel) async -> (Bool, Int64?) {
        guard let folder = modelFolderURL(for: model) else {
            // Parakeet — not a WhisperKit folder; best-effort via HF cache.
            return parakeetCacheInfo()
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            return (false, nil)
        }

        let bytes = directorySize(folder)
        // Align with migration usable-content: hub metadata alone is not "downloaded".
        let present = variantFolderHasModelPayload(folder)
        return (present, present ? bytes : nil)
    }

    /// Sums file sizes recursively under `url`. Off-main, synchronous I/O —
    /// callers must invoke from a background context.
    private nonisolated static func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    /// The on-disk folder a given WhisperKit-backed model's files live in,
    /// or nil for Parakeet (not WhisperKit-managed). Matches the resolution
    /// `WhisperKit.download` performs internally: `downloadBase/models/<repo>/<variant>`.
    ///
    /// NOTE: WhisperKit's `download(variant:)` resolves an ambiguous variant
    /// glob against the actual repo file listing and may prepend "openai_"
    /// or similar — but every `LocalModel.whisperKitModelID` here is already
    /// the exact, unambiguous folder name (verified against the live cache:
    /// "openai_whisper-base" exists at exactly this path on this machine),
    /// so a direct path join is safe and avoids a network call just to
    /// check local presence.
    nonisolated static func modelFolderURL(for model: LocalModel) -> URL? {
        guard let variant = model.whisperKitModelID else { return nil }
        return downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    /// Parakeet is cached by `parakeet-mlx` in the standard HuggingFace CLI
    /// cache (`~/.cache/huggingface/hub/`), not WhisperKit's folder. This is
    /// best-effort: if the expected cache layout isn't found, we report "not
    /// downloaded" rather than guessing — Parakeet acquisition is owned by
    /// the Python sidecar itself, not this manager.
    private nonisolated static func parakeetCacheInfo() -> (Bool, Int64?) {
        let hfCache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: hfCache,
            includingPropertiesForKeys: nil
        ) else {
            return (false, nil)
        }

        // parakeet-mlx caches under a folder name containing "parakeet".
        guard let parakeetDir = contents.first(where: {
            $0.lastPathComponent.lowercased().contains("parakeet")
        }) else {
            return (false, nil)
        }

        let bytes = directorySize(parakeetDir)
        return (bytes > 0, bytes)
    }

    /// True for the Parakeet model — its storage is managed by the Python
    /// sidecar's own cache, not by this manager's download/delete flow.
    func isSidecarManaged(_ model: LocalModel) -> Bool {
        model.engineID == .parakeet
    }

    // MARK: - Download

    /// Triggers (or awaits, if already in flight) a download of `model`'s
    /// WhisperKit files, publishing progress to `downloadProgress[model]`.
    /// No-op for Parakeet (sidecar-managed — see `isSidecarManaged`).
    /// On failure, cleans up any partial folder so a subsequent retry starts
    /// clean instead of resuming into a corrupt partial snapshot.
    func download(_ model: LocalModel) {
        guard !isSidecarManaged(model) else { return }
        guard let variant = model.whisperKitModelID else { return }

        if downloadTasks[model] != nil { return }  // already downloading

        state[model] = .downloading
        downloadProgress[model] = 0

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await WhisperKit.download(
                    variant: variant,
                    downloadBase: Self.downloadBase,
                    from: Self.repo,
                    progressCallback: { progress in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor in
                            self.downloadProgress[model] = fraction
                        }
                    }
                )
                await MainActor.run {
                    self.state[model] = .idle
                    self.downloadProgress[model] = 1.0
                    self.downloadTasks[model] = nil
                }
                self.refreshStatus(model)
                self.logger.info("ModelManager: download complete for \(model.rawValue, privacy: .public)")
            } catch {
                self.logger.error("ModelManager: download failed for \(model.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // Recovery: remove any partial/corrupt folder so the next
                // attempt starts from a clean slate rather than resuming
                // into (or being confused by) a truncated snapshot.
                Self.cleanupPartialDownload(for: model)
                await MainActor.run {
                    self.state[model] = .failed(error.localizedDescription)
                    self.downloadProgress[model] = nil
                    self.downloadTasks[model] = nil
                }
                self.refreshStatus(model)
            }
        }
        downloadTasks[model] = task
    }

    /// Removes a failed/partial download's folder. Safe to call even if
    /// nothing exists yet. Scoped to exactly this model's folder — never
    /// touches sibling model folders or the shared repo directory.
    private nonisolated static func cleanupPartialDownload(for model: LocalModel) {
        guard let folder = modelFolderURL(for: model) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Re-attempts a failed download. Equivalent to calling `download(_:)`
    /// again once the prior failure has been cleaned up.
    func retry(_ model: LocalModel) {
        state[model] = .idle
        download(model)
    }

    // MARK: - Delete

    /// Deletes ONLY `model`'s own folder — never a bulk/all-models wipe.
    /// No-op for Parakeet (sidecar-managed). Updates `downloaded`/`diskSize`
    /// afterward so the UI reflects the removal immediately.
    func delete(_ model: LocalModel) {
        guard !isSidecarManaged(model) else { return }
        guard let folder = Self.modelFolderURL(for: model) else { return }

        // Don't delete out from under an in-flight download.
        downloadTasks[model]?.cancel()
        downloadTasks[model] = nil
        state[model] = .idle
        downloadProgress[model] = nil

        Task {
            await Task.detached {
                try? FileManager.default.removeItem(at: folder)
            }.value
            self.refreshStatus(model)
            self.logger.info("ModelManager: deleted \(model.rawValue, privacy: .public)")
        }
    }
}
