import Foundation
import Carbon
import ApplicationServices
import AppKit
import os.log

/// Post-ASR pipeline: cleanup → dictionary-correct → snippet-expand → inject → history.
/// `ASREngineSelector` owns engine cache/factory and delegates transcription
/// completion work here so the selector stays focused on engine selection.
final class TranscriptionPipeline {

    /// Tri-state handed to HUD after inject — not a Bool collapse of success/fail.
    enum InjectPipelineResult: Equatable {
        case inserted
        case deduped
        case failed
    }

    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "transcription-pipeline")

    /// Resolves engines and cloud settings from the owning selector.
    weak var engineSelector: ASREngineSelector?

    /// Master on/off for the AI cleanup pass.
    var cleanupEnabled: Bool = false

    /// Whether cleanup should use the code-aware prompt variant.
    var codeAware: Bool = false

    /// When true, prepends a leading space before injection when the caret
    /// context warrants it (sentence continuation after alphanumeric/punctuation).
    var smartLeadingSpaceEnabled: Bool = true

    /// AX caret snapshot captured on the main thread at recording-will-start.
    /// Preferred at live inject when selection was readable; ignored for history-retry.
    private var heldCaretSnapshot: CaretContext.Snapshot?

    /// Frontmost app PID captured with the caret at recording-will-start.
    private var heldFrontmostPID: pid_t?

    /// Generation token for `heldCaretSnapshot`. Incremented on each hold so an
    /// older `finishTranscription` cannot clear a newer session's held.
    private var heldCaretToken: UInt64 = 0

    /// Active Style profile formality instruction for cleanup.
    var styleInstruction: String?

    /// Active cleanup backend, or `nil` if cleanup can't run right now.
    var cleanupService: TranscriptCleanupService?

    /// Dictionary-correction hook — applied BEFORE injection and history.
    var onTranscription: ((String, String) -> (String, [CorrectionRecord]))?

    /// Snippet-expansion hook — applied after dictionary correction.
    var onSnippetExpand: ((String) -> String)?

    /// History-logging hook with the final expanded text.
    /// Sixth arg is optional history entry ID to replace (retry path).
    var onTranscriptionLogged: ((String, String, Bool, String?, Bool, UUID?) -> Void)?

    /// Fired on the main thread after a confirmed insert with the delivered text
    /// (for inline correction watching). Not called for dedupe or failed inserts.
    var onTextInserted: ((String) -> Void)?

    /// Invoked on the main thread when dictionary/phonetic corrections fire.
    var onCorrectionsRecorded: (([CorrectionRecord]) -> Void)?

    /// Terminal failure hook (transcription, injection, audio capture).
    var onFailure: ((DictationFailure) -> Void)?

    /// Capture caret AX context + frontmost PID on the main thread at
    /// recording-will-start. Replaces any prior hold and bumps the generation token.
    /// Reads frontmost PID once so AX snapshot and held PID cannot desync.
    @discardableResult
    func holdCaretSnapshotFromRecordingWillStart() -> UInt64 {
        assert(Thread.isMainThread, "holdCaretSnapshotFromRecordingWillStart requires main thread")
        heldCaretToken &+= 1
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        heldCaretSnapshot = CaretContext.snapshot(frontmostPID: pid)
        heldFrontmostPID = pid
        return heldCaretToken
    }

    /// Drop held snapshot + PID (cancel / abort / stop without inject).
    /// When `matching` is set, clears only if the current token still matches
    /// that session — older finish/fail paths must not wipe a newer hold.
    func clearHeldCaretSnapshot(matching token: UInt64? = nil) {
        if let token, heldCaretToken != token { return }
        heldCaretSnapshot = nil
        heldFrontmostPID = nil
    }

    /// Package-visible held state for lifecycle unit tests.
    var test_heldCaretToken: UInt64 { heldCaretToken }
    var test_heldCaretSnapshot: CaretContext.Snapshot? { heldCaretSnapshot }
    var test_heldFrontmostPID: pid_t? { heldFrontmostPID }

    /// Test hook: install a synthetic held snapshot (no AX) on the main thread.
    @discardableResult
    func test_holdSnapshot(_ snapshot: CaretContext.Snapshot, frontmostPID: pid_t? = nil) -> UInt64 {
        assert(Thread.isMainThread, "test_holdSnapshot requires main thread")
        heldCaretToken &+= 1
        heldCaretSnapshot = snapshot
        heldFrontmostPID = frontmostPID
        return heldCaretToken
    }

    /// Copy held snapshot + PID when `token` still owns the slot.
    /// Call on the main thread (AudioRecorder samples at stop before async gaps).
    func copyHeldCaretMatching(_ token: UInt64) -> (CaretContext.Snapshot?, pid_t?) {
        assert(Thread.isMainThread, "copyHeldCaretMatching requires main thread")
        guard heldCaretToken == token else { return (nil, nil) }
        return (heldCaretSnapshot, heldFrontmostPID)
    }

    /// Pure seam: prefer an explicit session hold from recording-stop over a
    /// later entry sample (which can race a newer `holdCaretSnapshot…`).
    static func resolveSessionHold(
        providedToken: UInt64?,
        providedSnapshot: CaretContext.Snapshot?,
        providedPID: pid_t?,
        currentToken: UInt64,
        currentSnapshot: CaretContext.Snapshot?,
        currentPID: pid_t?
    ) -> (token: UInt64, snapshot: CaretContext.Snapshot?, pid: pid_t?) {
        if let providedToken {
            return (providedToken, providedSnapshot, providedPID)
        }
        return (currentToken, currentSnapshot, currentPID)
    }

    /// Pure seam for `finishTranscription`: prefer a non-nil stop-time session
    /// snapshot over the live pipeline slot. Token-matched clear still uses
    /// `sessionHeldToken`; live is only a fallback when the stop sample was nil
    /// (so clearing the live slot cannot wipe a good stop sample).
    static func resolveHeldAtStart(
        sessionHeldSnapshot: CaretContext.Snapshot?,
        sessionHeldToken: UInt64,
        liveToken: UInt64,
        liveSnapshot: CaretContext.Snapshot?
    ) -> CaretContext.Snapshot? {
        if let sessionHeldSnapshot {
            return sessionHeldSnapshot
        }
        if liveToken == sessionHeldToken {
            return liveSnapshot
        }
        return nil
    }

    /// Pure helper: abort inject only when both PIDs are known and unequal.
    /// Nil held or nil current → fail-open (allow insert).
    static func shouldAbortInjectForFrontmostMismatch(held: pid_t?, current: pid_t?) -> Bool {
        guard let held, let current else { return false }
        return held != current
    }

    /// Pure helper: leave transcript on pasteboard only for app-switch abort,
    /// never when secure input is active (password fields must not get clipboard).
    ///
    /// Callers MUST pass a **live** `secureInput` from `IsSecureEventInputEnabled()`
    /// sampled on the main thread immediately before the clipboard/insert gate —
    /// not an earlier pipeline sample (TOCTOU).
    static func shouldLeaveTranscriptOnClipboard(
        abortForAppSwitch: Bool,
        secureInput: Bool
    ) -> Bool {
        abortForAppSwitch && !secureInput
    }

    /// Post-transform inject gate: secure input vs app-switch abort vs insert.
    ///
    /// `liveSecure` must be a fresh main-thread `IsSecureEventInputEnabled()`
    /// sample taken immediately before this decision.
    enum FinishInjectGate: Equatable {
        case blockedSecureInput
        case abortedAppSwitch
        case proceedInsert
    }

    static func finishInjectGate(
        abortForAppSwitch: Bool,
        liveSecure: Bool
    ) -> FinishInjectGate {
        if liveSecure { return .blockedSecureInput }
        if abortForAppSwitch { return .abortedAppSwitch }
        return .proceedInsert
    }

    /// Pure plan: decide app-switch abort **before** wrong-app fresh AX /
    /// caret transforms. History-retry (`replaceHistoryEntryID != nil`) never
    /// takes the abort short path.
    enum InjectAXPlan: Equatable {
        /// Skip fresh AX; inject text is expanded (post dictionary/snippet)
        /// without wrong-app caret transforms.
        case abortWithoutFreshAX
        /// Resolve held/fresh + applyInjectTransforms as usual.
        case resolveWithOptionalFresh
    }

    static func injectAXPlan(
        replaceHistoryEntryID: UUID?,
        heldPID: pid_t?,
        currentPID: pid_t?
    ) -> InjectAXPlan {
        if replaceHistoryEntryID == nil
            && shouldAbortInjectForFrontmostMismatch(held: heldPID, current: currentPID)
        {
            return .abortWithoutFreshAX
        }
        return .resolveWithOptionalFresh
    }

    /// Late TOCTOU immediately before insert (after transforms). Same PID rules
    /// as `injectAXPlan` abort — history-retry never aborts; nil PIDs fail-open.
    static func shouldAbortInjectAfterTransforms(
        replaceHistoryEntryID: UUID?,
        heldPID: pid_t?,
        latePID: pid_t?
    ) -> Bool {
        replaceHistoryEntryID == nil
            && shouldAbortInjectForFrontmostMismatch(held: heldPID, current: latePID)
    }

    /// Call on main. App-switch abort leave: re-read secure; leave clipboard
    /// only when clear. Returns true when secure blocked leave (elevate outcome).
    static func appSwitchAbortLeaveOnMain(text: String) -> Bool {
        let secureAtLeave = IsSecureEventInputEnabled()
        if secureAtLeave { return true }
        if shouldLeaveTranscriptOnClipboard(abortForAppSwitch: true, secureInput: false) {
            TextInjector.leaveTranscriptOnClipboard(text)
        }
        return false
    }

    /// Pure seam for post-insert secure re-read (Carbon cannot flip in tests).
    /// When insert ran and failed, prefer `liveSecureAfterInsert` if true so
    /// outcome is `.secureInputBlocked` rather than `.injectionFailed`.
    static func outcomeSecureAfterInsert(
        proceeded: Bool,
        insertFailed: Bool,
        liveSecureAtGate: Bool,
        liveSecureAfterInsert: Bool
    ) -> Bool {
        if proceeded, insertFailed, liveSecureAfterInsert { return true }
        return liveSecureAtGate
    }

    /// Transcribes the audio file with the selected engine, applies dictionary
    /// correction, injects, and logs to history — the full pipeline for one
    /// completed dictation.
    /// - Parameter replaceHistoryEntryID: when set, history updates that row
    ///   instead of appending (failed-entry retry); concurrent live dictation
    ///   leaves this nil so retries never steal a live append.
    /// - Parameters sessionHeldToken/Snapshot/FrontmostPID: when `sessionHeldToken`
    ///   is non-nil, use that triple (sampled at recording-stop) instead of
    ///   reading `heldCaret*` at entry — avoids poisoning across async IO/ASR
    ///   gaps. History-retry leaves them nil and keeps entry-sample behavior.
    func transcribeAndLog(
        audioURL: URL,
        replaceHistoryEntryID: UUID? = nil,
        sessionHeldToken providedToken: UInt64? = nil,
        sessionHeldSnapshot providedSnapshot: CaretContext.Snapshot? = nil,
        sessionHeldFrontmostPID providedPID: pid_t? = nil,
        completion: ((InjectPipelineResult) -> Void)? = nil
    ) {
        guard let selector = engineSelector else {
            completion?(.failed)
            return
        }

        let audioPath = audioURL.path
        let replaceID = replaceHistoryEntryID
        // Prefer stop-sampled hold when provided; otherwise sample at entry
        // (history-retry / legacy callers). Entry sample still races a newer
        // hold — live dictation must pass the stop-time triple.
        let (sessionHeldToken, sessionHeldSnapshot, sessionHeldFrontmostPID) =
            sampleSessionHold(
                providedToken: providedToken,
                providedSnapshot: providedSnapshot,
                providedPID: providedPID
            )
        if let cloudModel = selector.cloudModel,
           let key = selector.apiKeyProvider?(cloudModel.provider),
           !key.isEmpty {
            let engineTag = "cloud:\(cloudModel.provider.rawValue)"
            logger.info("Transcribing \(audioURL.lastPathComponent) with cloud engine '\(engineTag)'")

            Task {
                do {
                    let service = CloudTranscriberFactory.service(for: cloudModel)
                    let text = try await service.transcribe(
                        audioURL: audioURL,
                        apiKey: key,
                        model: cloudModel,
                        language: selector.selectedLanguage
                    )
                    let cleaned = await self.applyCleanup(text)
                    let transformed = await self.applyAutoTransform(cleaned)
                    self.finishTranscription(
                        text: transformed,
                        engineID: engineTag,
                        audioPath: audioPath,
                        replaceHistoryEntryID: replaceID,
                        sessionHeldToken: sessionHeldToken,
                        sessionHeldSnapshot: sessionHeldSnapshot,
                        sessionHeldFrontmostPID: sessionHeldFrontmostPID,
                        completion: completion
                    )
                } catch {
                    self.logger.error("Cloud transcription failed [\(engineTag)]: \(error.localizedDescription)")
                    vlog("cloud transcription error [\(engineTag)]: \(error.localizedDescription) — falling back to local")
                    self.transcribeLocally(
                        audioURL: audioURL,
                        audioPath: audioPath,
                        replaceHistoryEntryID: replaceID,
                        sessionHeldToken: sessionHeldToken,
                        sessionHeldSnapshot: sessionHeldSnapshot,
                        sessionHeldFrontmostPID: sessionHeldFrontmostPID,
                        completion: completion
                    )
                }
            }
            return
        }

        transcribeLocally(
            audioURL: audioURL,
            audioPath: audioPath,
            replaceHistoryEntryID: replaceID,
            sessionHeldToken: sessionHeldToken,
            sessionHeldSnapshot: sessionHeldSnapshot,
            sessionHeldFrontmostPID: sessionHeldFrontmostPID,
            completion: completion
        )
    }

    /// Streaming entry point: takes text already produced by a live session.
    /// - Parameters sessionHeld*: when `sessionHeldToken` is non-nil, use that
    ///   stop-sampled triple (before streaming finalize Tasks) instead of
    ///   reading `heldCaret*` at entry.
    func logStreamedTranscription(
        text: String,
        engineID: String,
        sessionHeldToken providedToken: UInt64? = nil,
        sessionHeldSnapshot providedSnapshot: CaretContext.Snapshot? = nil,
        sessionHeldFrontmostPID providedPID: pid_t? = nil,
        completion: ((InjectPipelineResult) -> Void)? = nil
    ) {
        let (sessionHeldToken, sessionHeldSnapshot, sessionHeldFrontmostPID) =
            sampleSessionHold(
                providedToken: providedToken,
                providedSnapshot: providedSnapshot,
                providedPID: providedPID
            )
        Task {
            let cleaned = await self.applyCleanup(text)
            let transformed = await self.applyAutoTransform(cleaned)
            self.finishTranscription(
                text: transformed,
                engineID: engineID,
                audioPath: nil,
                replaceHistoryEntryID: nil,
                sessionHeldToken: sessionHeldToken,
                sessionHeldSnapshot: sessionHeldSnapshot,
                sessionHeldFrontmostPID: sessionHeldFrontmostPID,
                completion: completion
            )
        }
    }

    /// Resolve provided stop-time hold, or sample `heldCaret*` once on main.
    private func sampleSessionHold(
        providedToken: UInt64?,
        providedSnapshot: CaretContext.Snapshot?,
        providedPID: pid_t?
    ) -> (token: UInt64, snapshot: CaretContext.Snapshot?, pid: pid_t?) {
        if let providedToken {
            return (providedToken, providedSnapshot, providedPID)
        }
        let current: () -> (UInt64, CaretContext.Snapshot?, pid_t?) = {
            (self.heldCaretToken, self.heldCaretSnapshot, self.heldFrontmostPID)
        }
        if Thread.isMainThread { return current() }
        return DispatchQueue.main.sync(execute: current)
    }

    private func transcribeLocally(
        audioURL: URL,
        audioPath: String,
        replaceHistoryEntryID: UUID?,
        sessionHeldToken: UInt64,
        sessionHeldSnapshot: CaretContext.Snapshot?,
        sessionHeldFrontmostPID: pid_t?,
        completion: ((InjectPipelineResult) -> Void)? = nil
    ) {
        guard let selector = engineSelector else {
            completion?(.failed)
            return
        }

        let engine = selector.makeEngine()
        logger.info("Transcribing \(audioURL.lastPathComponent) with engine '\(engine.id)'")

        Task {
            do {
                let text = try await engine.transcribe(audioURL: audioURL)
                let cleaned = await self.applyCleanup(text)
                let transformed = await self.applyAutoTransform(cleaned)
                self.finishTranscription(
                    text: transformed,
                    engineID: engine.id,
                    audioPath: audioPath,
                    replaceHistoryEntryID: replaceHistoryEntryID,
                    sessionHeldToken: sessionHeldToken,
                    sessionHeldSnapshot: sessionHeldSnapshot,
                    sessionHeldFrontmostPID: sessionHeldFrontmostPID,
                    completion: completion
                )
            } catch {
                self.logger.error("Transcription failed [\(engine.id)]: \(error.localizedDescription)")
                vlog("transcription error [\(engine.id)]: \(error.localizedDescription)")
                self.reportTranscriptionFailure(
                    engineID: engine.id,
                    audioPath: audioPath,
                    replaceHistoryEntryID: replaceHistoryEntryID,
                    sessionHeldToken: sessionHeldToken,
                    completion: completion
                )
            }
        }
    }

    private func reportTranscriptionFailure(
        engineID: String,
        audioPath: String,
        replaceHistoryEntryID: UUID?,
        sessionHeldToken: UInt64,
        completion: ((InjectPipelineResult) -> Void)?
    ) {
        DispatchQueue.main.async {
            if replaceHistoryEntryID == nil {
                self.clearHeldCaretSnapshot(matching: sessionHeldToken)
            }
            self.onFailure?(.transcriptionFailed)
            self.onTranscriptionLogged?("", engineID, false, audioPath, true, replaceHistoryEntryID)
            completion?(.failed)
        }
    }

    /// Caps always, then SpokenPunctuation (codeAware), then DotCompound.
    /// Package-visible for pipeline-gate unit tests. Caps is not gated on
    /// codeAware or cleanup.
    static func preprocessBeforeCleanup(_ text: String, codeAware: Bool) -> String {
        let capped = SpokenCapitalization.apply(text)
        return DotCompoundNumberNormalizer.apply(
            codeAware ? SpokenPunctuation.apply(capped) : capped
        )
    }

    private func applyCleanup(_ text: String) async -> String {
        let preprocessed = Self.preprocessBeforeCleanup(text, codeAware: codeAware)
        guard cleanupEnabled, let svc = cleanupService, !preprocessed.isEmpty else { return preprocessed }

        let wordCount = preprocessed.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
        guard wordCount > 3 else {
            vlog("cleanup skipped — short input (\(wordCount) words)")
            return preprocessed
        }

        let cleanupStart = Date()
        do {
            let cleaned = try await svc.cleanup(preprocessed, codeAware: codeAware, styleInstruction: styleInstruction)
            vlog("cleanup \(String(format: "%.2f", Date().timeIntervalSince(cleanupStart)))s")
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return preprocessed }
            guard Self.cleanupLooksSane(input: preprocessed, output: trimmed) else {
                vlog("cleanup rejected — output diverged from input (likely answered); using raw")
                return preprocessed
            }
            // Cleanup sometimes re-expands joined identifiers (`conduct.mdc` →
            // `conduct dot mdc`) and cleanupLooksSane accepts that. Re-run the
            // deterministic pass so spoken punctuation wins last.
            // Post-SP only on successful cleanup; Caps does not re-run here.
            return codeAware ? SpokenPunctuation.apply(trimmed) : trimmed
        } catch {
            vlog("cleanup failed: \(error.localizedDescription) — using raw")
            return preprocessed
        }
    }

    private func applyAutoTransform(_ text: String) async -> String {
        guard let transform = engineSelector?.autoRunTransform else { return text }
        do {
            let result = try await TransformRunner.run(
                prompt: transform.prompt,
                over: text,
                openAIKey: engineSelector?.openAIKeyProvider?()
            )
            return result.isEmpty ? text : result
        } catch {
            vlog("auto-run transform failed: \(error.localizedDescription) — using pre-transform text")
            return text
        }
    }

    static func cleanupLooksSane(input: String, output: String) -> Bool {
        func words(_ s: String) -> [String] {
            s.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { !$0.isEmpty }
        }
        let inWords = Set(words(input))
        let outWords = words(output)
        guard !outWords.isEmpty, !inWords.isEmpty else { return true }

        let ratio = Double(output.count) / Double(max(input.count, 1))
        if ratio > 2.0 || ratio < 0.4 { return false }

        let newWords = outWords.filter { !inWords.contains($0) }
        return Double(newWords.count) / Double(outWords.count) <= 0.4
    }

    private func finishTranscription(
        text: String,
        engineID: String,
        audioPath: String?,
        replaceHistoryEntryID: UUID?,
        sessionHeldToken: UInt64,
        sessionHeldSnapshot: CaretContext.Snapshot?,
        sessionHeldFrontmostPID: pid_t?,
        completion: ((InjectPipelineResult) -> Void)?
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.logger.info("Transcribed \(trimmed.count) chars with engine '\(engineID)'")
        vlog("transcribed \(trimmed.count) chars [\(engineID)]")

        guard !trimmed.isEmpty else {
            DispatchQueue.main.async {
                if replaceHistoryEntryID == nil {
                    self.clearHeldCaretSnapshot(matching: sessionHeldToken)
                }
                self.onFailure?(.transcriptionFailed)
                if let audioPath {
                    self.onTranscriptionLogged?("", engineID, false, audioPath, true, replaceHistoryEntryID)
                }
                completion?(.failed)
            }
            return
        }

        DispatchQueue.main.async {
            let (corrected, records) = self.onTranscription?(trimmed, engineID) ?? (trimmed, [])
            if !records.isEmpty { self.onCorrectionsRecorded?(records) }
            let expanded = self.onSnippetExpand?(corrected) ?? corrected
            let capitalizedTerms = self.engineSelector?.capitalizedDictionaryTermsProvider?() ?? []
            // Prefer the stop-time session snapshot when present. Token match
            // for clear still uses sessionHeldToken; live held is only a
            // fallback when the stop sample was nil — so clearHeldCaretSnapshot
            // nilling the live slot cannot wipe a good stop sample.
            let heldAtStart = Self.resolveHeldAtStart(
                sessionHeldSnapshot: sessionHeldSnapshot,
                sessionHeldToken: sessionHeldToken,
                liveToken: self.heldCaretToken,
                liveSnapshot: self.heldCaretSnapshot
            )
            let clearToken = sessionHeldToken
            let replaceID = replaceHistoryEntryID
            // Entry-sampled will-start PID — do not re-read NSWorkspace as "held".
            let heldPID = sessionHeldFrontmostPID

            // Insert blocks up to ~1s (event delivery + confirmation waits) —
            // run it off-main so HUD animations don't stall. Only the
            // completion (which drives finishHUDAfterPipeline) hops back to
            // main; correction/snippet steps above stay on main as before.
            DispatchQueue.global(qos: .utility).async {
                // Sample frontmost PID + secure **before** fresh AX / transforms
                // so app-switch abort never drives wrong-app caret reads.
                let (currentPID, liveSecureAtSample): (pid_t?, Bool) = DispatchQueue.main.sync {
                    (
                        NSWorkspace.shared.frontmostApplication?.processIdentifier,
                        IsSecureEventInputEnabled()
                    )
                }
                let axPlan = Self.injectAXPlan(
                    replaceHistoryEntryID: replaceID,
                    heldPID: heldPID,
                    currentPID: currentPID
                )
                let abortForAppSwitch = axPlan == .abortWithoutFreshAX

                let textToInject: String
                let liveSecure: Bool
                switch axPlan {
                case .abortWithoutFreshAX:
                    // Expanded only — no wrong-app fresh AX or caret transforms.
                    textToInject = expanded
                    liveSecure = liveSecureAtSample
                case .resolveWithOptionalFresh:
                    let needsFresh: Bool = {
                        if replaceID != nil { return true }
                        guard let held = heldAtStart, !held.isUnknown else { return true }
                        if case .readable(let n) = held.selectionLength, n > 0 { return false }
                        return true
                    }()
                    let fresh: CaretContext.Snapshot
                    if needsFresh {
                        // Fresh AX read must hop to main — do not call AX only off utility.
                        fresh = DispatchQueue.main.sync {
                            CaretContext.snapshot()
                        }
                    } else {
                        fresh = .unknown
                    }
                    let resolved = CaretContext.resolveInjectSnapshot(
                        held: heldAtStart,
                        fresh: fresh,
                        replaceHistoryEntryID: replaceID
                    )
                    // Re-sample secure immediately before transforms/gate (TOCTOU
                    // vs the early PID sample). PID abort was already decided.
                    liveSecure = DispatchQueue.main.sync {
                        IsSecureEventInputEnabled()
                    }
                    textToInject = Self.applyInjectTransforms(
                        expanded: expanded,
                        snapshot: resolved,
                        secureInput: liveSecure,
                        smartLeadingSpaceEnabled: self.smartLeadingSpaceEnabled,
                        codeAware: self.codeAware,
                        capitalizedDictionaryTerms: capitalizedTerms
                    )
                }

                // Secure input wins over app-switch abort: never put transcript
                // on the pasteboard when typing into a password/secure field.
                let insertResult: TextInjector.InsertResult
                let proceededToInsert: Bool
                // When abort leave re-reads secure=true, override outcome.
                var abortLeaveBecameSecure = false
                switch Self.finishInjectGate(
                    abortForAppSwitch: abortForAppSwitch,
                    liveSecure: liveSecure
                ) {
                case .blockedSecureInput:
                    insertResult = .failed
                    proceededToInsert = false
                case .abortedAppSwitch:
                    // Live secure re-read before pasteboard — skip leave when secure.
                    DispatchQueue.main.sync {
                        abortLeaveBecameSecure = Self.appSwitchAbortLeaveOnMain(
                            text: textToInject
                        )
                    }
                    insertResult = .failed
                    proceededToInsert = false
                case .proceedInsert:
                    // Re-sample frontmost immediately before insert (TOCTOU vs
                    // early PID). Late mismatch → same abort-leave as above.
                    enum LateInjectDecision {
                        case insert
                        case abort(becameSecure: Bool)
                    }
                    let late: LateInjectDecision = DispatchQueue.main.sync {
                        let latePID =
                            NSWorkspace.shared.frontmostApplication?.processIdentifier
                        if Self.shouldAbortInjectAfterTransforms(
                            replaceHistoryEntryID: replaceID,
                            heldPID: heldPID,
                            latePID: latePID
                        ) {
                            return .abort(
                                becameSecure: Self.appSwitchAbortLeaveOnMain(text: textToInject)
                            )
                        }
                        return .insert
                    }
                    switch late {
                    case .abort(let becameSecure):
                        abortLeaveBecameSecure = becameSecure
                        insertResult = .failed
                        proceededToInsert = false
                    case .insert:
                        insertResult = TextInjector().insert(textToInject)
                        proceededToInsert = true
                    }
                }

                if case .inserted(let delivered) = insertResult {
                    let notify = self.onTextInserted
                    DispatchQueue.main.async {
                        notify?(delivered)
                    }
                }
                DispatchQueue.main.async {
                    // One-shot clear after live inject consume (not for history-retry).
                    // Only clear if this session's token still owns the held slot.
                    if replaceID == nil {
                        self.clearHeldCaretSnapshot(matching: clearToken)
                    }
                    // Gate sample, unless insert failed after secure flipped on,
                    // or abort leave re-read found secure (clipboard skipped).
                    let insertFailed: Bool = {
                        if case .failed = insertResult { return true }
                        return false
                    }()
                    let liveSecureAfterInsert =
                        proceededToInsert && insertFailed
                        ? IsSecureEventInputEnabled()
                        : false
                    let outcomeSecure: Bool
                    if abortLeaveBecameSecure {
                        outcomeSecure = true
                    } else {
                        outcomeSecure = Self.outcomeSecureAfterInsert(
                            proceeded: proceededToInsert,
                            insertFailed: insertFailed,
                            liveSecureAtGate: liveSecure,
                            liveSecureAfterInsert: liveSecureAfterInsert
                        )
                    }
                    let outcome = Self.secureInputOutcome(
                        secureInput: outcomeSecure,
                        insertResult: insertResult
                    )
                    if outcome.shouldLog {
                        // History matches inject intent (post-strip + leading space),
                        // not pasteboard bytes after TextInjector trailing-WS trim.
                        // Dedupe skips history (shouldLog false).
                        self.onTranscriptionLogged?(
                            textToInject,
                            engineID,
                            insertResult.wasInjectedForHistory,
                            audioPath,
                            false,
                            replaceID
                        )
                    }
                    if let failure = outcome.failure {
                        self.onFailure?(failure)
                    }

                    completion?(outcome.pipelineResult)
                }
            }
        }
    }

    /// Inject-time transforms: mid-sentence trailing `.!?` strip, Title Case
    /// first-token decap, then smart leading space — gated on
    /// `!secureInput && smartLeadingSpaceEnabled`. Strip/decap further require
    /// Accessibility TCC; fail-open (keep punct/caps) when untrusted.
    /// Package-visible for seam unit tests without mocking `finishTranscription`.
    static func applyInjectTransforms(
        expanded: String,
        snapshot: CaretContext.Snapshot,
        secureInput: Bool,
        smartLeadingSpaceEnabled: Bool,
        codeAware: Bool,
        capitalizedDictionaryTerms: Set<String> = [],
        accessibilityTrusted: Bool = AXIsProcessTrusted()
    ) -> String {
        guard !secureInput, smartLeadingSpaceEnabled else {
            return expanded
        }

        var text = expanded
        if accessibilityTrusted {
            text = CaretContext.stripTrailingSentencePunctuationIfNeeded(
                snapshot: snapshot,
                transcript: text,
                codeAware: codeAware
            )
            text = CaretContext.decapitalizeFirstTokenIfNeeded(
                snapshot: snapshot,
                transcript: text,
                capitalizedDictionaryTerms: capitalizedDictionaryTerms
            )
        }
        let shouldPrepend = CaretContext.shouldPrependSpace(
            snapshot: snapshot,
            transcriptFirstChar: text.first
        )
        return shouldPrepend ? " " + text : text
    }

    /// Pure decision seam for the secure-input / history-logging / HUD outcome
    /// at finish time — extracted so it can be exercised in unit tests, since
    /// `IsSecureEventInputEnabled` (Carbon) cannot be forced on in a test.
    ///
    /// Pass the same `liveSecure` used for transforms / inject gate, except when
    /// `outcomeSecureAfterInsert` (or abort-leave re-read) elevates to secure —
    /// then pass `true` so outcome is `.secureInputBlocked` (not `.injectionFailed`).
    ///
    /// - `secureInput == true`: never log, `.secureInputBlocked`, HUD failed.
    /// - `.inserted`: log, no failure, HUD success.
    /// - `.deduped`: skip history, no failure, HUD neutral hide.
    /// - `.failed`: log, `.injectionFailed`, HUD failed.
    static func secureInputOutcome(
        secureInput: Bool,
        insertResult: TextInjector.InsertResult
    ) -> (shouldLog: Bool, failure: DictationFailure?, pipelineResult: InjectPipelineResult) {
        if secureInput {
            return (false, .secureInputBlocked, .failed)
        }
        switch insertResult {
        case .inserted:
            return (true, nil, .inserted)
        case .deduped:
            return (false, nil, .deduped)
        case .failed:
            return (true, .injectionFailed, .failed)
        }
    }
}
