import Foundation
import Darwin

/// Retains recent dictation recordings for future retry. Copies from the
/// ephemeral `/tmp` capture path into Application Support and prunes by
/// **size budget** (oldest first past `maxBytes`) — the limit the user actually
/// sets in Settings. Protected paths (failed history rows still eligible for
/// retry) are never pruned.
enum RecordingRetention {

    /// Runaway guard, **not** the user-facing limit.
    ///
    /// This used to be 5, which made it the limit that actually bound: a
    /// typical hold is well under a megabyte, so five of them never approached
    /// any budget option and the MB picker in Settings was decoration. The size
    /// budget is now the governor; this only stops the directory growing without
    /// bound if the budget is somehow never applied. At the 200 MB default,
    /// float32 capture (~192 KB/s) puts the budget in charge well before this.
    static let runawayFileCeiling = 5_000

    /// Default size budget when Settings has never been set — 200 MB.
    static let defaultBudgetMB = 200

    /// Injectable for tests. Production uses Application Support/Voice/Recordings.
    static var recordingsDirectoryOverride: URL?

    static var recordingsDirectory: URL {
        let dir: URL
        if let recordingsDirectoryOverride {
            dir = recordingsDirectoryOverride
        } else {
            VoicePaths.prepareApplicationSupportVoiceDirectory()
            dir = VoicePaths.recordingsDirectory
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var excludedDirectory = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excludedDirectory.setResourceValues(values)
        return dir
    }

    /// Copies `tempURL` into Application Support, prunes older files, and
    /// returns the retained destination path. Returns `nil` if the copy fails or the new file is pruned.
    /// - Parameter keepPaths: absolute paths that must not be pruned (e.g.
    ///   failed history rows still eligible for retry).
    /// - Parameter maxBytes: size budget; oldest unprotected files are removed
    ///   until total size is under this limit (or only protected files remain).
    @discardableResult
    static func retain(
        from tempURL: URL,
        keepPaths: [String] = [],
        maxCount: Int = runawayFileCeiling,
        maxBytes: Int64 = Int64(defaultBudgetMB) * 1024 * 1024
    ) -> URL? {
        let ext = tempURL.pathExtension.isEmpty ? "caf" : tempURL.pathExtension
        // A wall-clock filename is not an identity: rapid releases can land in
        // the same second. Every retained recording gets its own stable path.
        let destination = recordingsDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).\(ext)")
        let fileManager = FileManager.default

        do {
            try fileManager.copyItem(at: tempURL, to: destination)
        } catch {
            return nil
        }

        prune(
            maxCount: maxCount,
            maxBytes: maxBytes,
            keepPaths: Set(keepPaths),
            in: recordingsDirectory
        )
        // A newly copied file can be pruned immediately when its size exceeds
        // the selected budget. Never hand history a dangling audio path.
        return fileManager.fileExists(atPath: destination.path) ? destination : nil
    }

    /// Retention is optional; the capture remains readable until ASR completes.
    static func handoffForTranscription(
        from tempURL: URL,
        keepPaths: [String] = [],
        maxBytes: Int64 = Int64(defaultBudgetMB) * 1024 * 1024,
        transcribe: (URL, URL?, @escaping () -> Void) -> Void
    ) {
        let retainedURL = retain(from: tempURL, keepPaths: keepPaths, maxBytes: maxBytes)
        transcribe(retainedURL ?? tempURL, retainedURL) {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    /// Total bytes of retained recording files (0 if the directory is empty/missing).
    static func usageBytes(in directory: URL? = nil) -> Int64 {
        let dir = directory ?? recordingsDirectory
        guard let urls = try? listedRecordings(in: dir) else { return 0 }
        var total: Int64 = 0
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    /// Number of retained recording files.
    static func fileCount(in directory: URL? = nil) -> Int {
        (try? listedRecordings(in: directory ?? recordingsDirectory))?.count ?? 0
    }

    /// Prune without retaining a new file — used when the budget setting drops.
    static func pruneNow(
        keepPaths: [String] = [],
        maxCount: Int = runawayFileCeiling,
        maxBytes: Int64
    ) {
        prune(
            maxCount: maxCount,
            maxBytes: maxBytes,
            keepPaths: Set(keepPaths),
            in: recordingsDirectory
        )
    }

    // MARK: - Export

    enum ExportError: Error, Equatable {
        case nothingToExport
        case stagingFailed(String)
        case zipFailed(String)
    }

    /// Builds a ZIP at `destination` with:
    /// - `recordings/` — retained audio files
    /// - `transcripts/` — one `.txt` per history entry that has text (named by date+id)
    /// - `manifest.json` — entry metadata (id, date, engine, injected, failed, audio file name)
    ///
    /// Uses `/usr/bin/zip` (macOS always has it). Returns the number of audio
    /// files packaged.
    @discardableResult
    static func exportZip(
        to destination: URL,
        historyEntries: [HistoryEntry],
        fileManager: FileManager = .default,
        zipExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/zip")
    ) throws -> Int {
        let recordings = (try? listedRecordings(in: recordingsDirectory)) ?? []

        let hasAudio = !recordings.isEmpty
        let hasTranscripts = historyEntries.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard hasAudio || hasTranscripts else {
            throw ExportError.nothingToExport
        }

        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("murmur-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }

        let recordingsDir = staging.appendingPathComponent("recordings", isDirectory: true)
        let transcriptsDir = staging.appendingPathComponent("transcripts", isDirectory: true)
        do {
            try fileManager.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)
        } catch {
            throw ExportError.stagingFailed(error.localizedDescription)
        }

        var packagedAudio = 0
        var packagedNames = Set<String>()
        for url in recordings {
            let dest = recordingsDir.appendingPathComponent(url.lastPathComponent)
            do {
                try fileManager.copyItem(at: url, to: dest)
                packagedAudio += 1
                packagedNames.insert(url.lastPathComponent)
            } catch {
                // Skip unreadable files; still export what we can.
                continue
            }
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]

        struct ManifestRow: Encodable {
            let id: String
            let date: String
            let engine: String
            let injected: Bool
            let failed: Bool
            let audioFile: String?
            let transcriptFile: String?
        }

        var manifest: [ManifestRow] = []
        for entry in historyEntries {
            let idString = entry.id.uuidString
            let dateString = dateFormatter.string(from: entry.date)
            var transcriptFile: String?
            let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let name = "\(dateString.replacingOccurrences(of: ":", with: "-"))_\(idString.prefix(8)).txt"
                let url = transcriptsDir.appendingPathComponent(name)
                do {
                    try trimmed.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    throw ExportError.stagingFailed(error.localizedDescription)
                }
                transcriptFile = name
            }

            var audioFile: String?
            if let path = entry.audioPath {
                let name = URL(fileURLWithPath: path).lastPathComponent
                if packagedNames.contains(name) {
                    audioFile = name
                }
            }

            manifest.append(
                ManifestRow(
                    id: idString,
                    date: dateString,
                    engine: entry.engine,
                    injected: entry.injected,
                    failed: entry.failed,
                    audioFile: audioFile,
                    transcriptFile: transcriptFile
                )
            )
        }

        // Also list orphan recordings not referenced by history.
        let referencedNames = Set(manifest.compactMap(\.audioFile))
        for url in recordings where packagedNames.contains(url.lastPathComponent) && !referencedNames.contains(url.lastPathComponent) {
            manifest.append(
                ManifestRow(
                    id: "orphan-\(url.lastPathComponent)",
                    date: "",
                    engine: "",
                    injected: false,
                    failed: false,
                    audioFile: url.lastPathComponent,
                    transcriptFile: nil
                )
            )
        }

        let manifestURL = staging.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            throw ExportError.stagingFailed(error.localizedDescription)
        }

        // Build beside the destination so replacement is an atomic rename on
        // the same volume. A failed archive never removes a previous export.
        let archive = destination.deletingLastPathComponent().appendingPathComponent(".murmur-export-\(UUID().uuidString).zip")
        defer { try? fileManager.removeItem(at: archive) }

        let process = Process()
        process.executableURL = zipExecutableURL
        process.arguments = ["-r", "-q", archive.path, "."]
        process.currentDirectoryURL = staging
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ExportError.zipFailed(error.localizedDescription)
        }

        guard process.terminationStatus == 0, fileManager.fileExists(atPath: archive.path) else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? "zip exit \(process.terminationStatus)"
            throw ExportError.zipFailed(errText)
        }

        guard Darwin.rename(archive.path, destination.path) == 0 else {
            throw ExportError.zipFailed("Could not replace the destination; the previous export was preserved.")
        }

        return packagedAudio
    }

    // MARK: - Private

    static func prune(
        maxCount: Int,
        maxBytes: Int64,
        keepPaths: Set<String>,
        in directory: URL
    ) {
        guard let urls = try? listedRecordings(in: directory) else { return }
        // Normalize so /var vs /private/var (and symlink forms) still protect.
        let protected = Set(keepPaths.map { normalizedPath($0) })

        // Newest first (same order as listedRecordings).
        // Count prune: among unprotected, keep only the newest maxCount.
        var keptUnprotected = 0
        var survivors: [URL] = []
        for url in urls {
            if protected.contains(normalizedPath(url.path)) {
                survivors.append(url)
                continue
            }
            keptUnprotected += 1
            if keptUnprotected <= maxCount {
                survivors.append(url)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }

        // Size prune: drop oldest unprotected until under budget.
        // Work oldest-first among unprotected survivors.
        func fileSize(_ url: URL) -> Int64 {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(values?.fileSize ?? 0)
        }

        var total = survivors.reduce(Int64(0)) { $0 + fileSize($1) }
        guard maxBytes > 0, total > maxBytes else { return }

        // Decorate-sort-undecorate: one `resourceValues` per file. Fetching
        // inside the comparator costs O(n log n) syscalls, which was invisible
        // at the old five-file ring and is not once the size budget governs.
        let unprotectedOldestFirst = survivors
            .filter { !protected.contains(normalizedPath($0.path)) }
            .map { (url: $0, date: modificationDate(of: $0)) }
            .sorted { $0.date < $1.date }
            .map(\.url)

        for url in unprotectedOldestFirst {
            guard total > maxBytes else { break }
            let size = fileSize(url)
            try? FileManager.default.removeItem(at: url)
            total -= size
            survivors.removeAll { $0 == url }
        }
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    /// Newest first. Reads each modification date exactly once — see the note on
    /// the size-prune sort above; this runs after every dictation.
    private static func listedRecordings(in directory: URL) throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        return urls
            .map { (url: $0, date: modificationDate(of: $0)) }
            .sorted { $0.date > $1.date }
            .map(\.url)
    }
}
