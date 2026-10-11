import Foundation
import Carbon
import ApplicationServices
import AppKit
import os.log

/// Post-ASR pipeline: cleanup → dictionary-correct → snippet-expand → inject → history.
/// `ASREngineSelector` owns engine cache/factory and delegates transcription
/// completion work here so the selector stays focused on engine selection.
final class TranscriptionPipeline {

    /// The transcript plus only the formatting provenance needed after edge
    /// whitespace normalization. It deliberately retains no raw provider text.
    struct PreprocessedTranscript {
        let text: String
        let hadExplicitTrailingNewline: Bool
    }

    /// Tri-state handed to HUD after inject — not a Bool collapse of success/fail.
    enum InjectPipelineResult: Equatable {
        case inserted
        case savedToHistory
        case deduped
        case failed
    }

    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "transcription-pipeline")

    /// Resolves engines and cloud settings from the owning selector.
    weak var engineSelector: ASREngineSelector?

    /// Injectable ASR boundaries keep pipeline tests offline and model-free.
    var cloudServiceProvider: (CloudModel) -> any CloudTranscriptionService = CloudTranscriberFactory.service
    var localEngineProvider: (() -> any ASREngine)?

    /// Master on/off for the AI cleanup pass.
    var cleanupEnabled: Bool = false

    /// Existing provider-filler preference, reused for conservative local
    /// hesitation removal before optional AI cleanup.
    var removeFillerWordsEnabled: Bool = false

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

    /// Selection intent captured with the AX snapshot at hold start. Values are
    /// token-scoped so a rapid re-press cannot turn an older instruction into
    /// ordinary dictation against the newer selection.
    private enum VoiceEditIntent {
        case edit(selection: String)
        case selectionTooLong
    }
    private var voiceEditIntents: [UInt64: VoiceEditIntent] = [:]

    /// Active Style profile formality instruction for cleanup.
    var styleInstruction: String?

    /// Active cleanup backend, or `nil` if cleanup can't run right now.
    var cleanupService: TranscriptCleanupService?

    /// Injectable transform operation; production preserves TransformRunner's
    /// backend ordering, including the on-device-only privacy boundary.
    var runVoiceEditTransform: (String, String, TransformCredentials) async throws -> String = { instruction, selection, credentials in
        try await TransformRunner.run(prompt: instruction, over: selection, credentials: credentials)
    }

    /// Injection dependencies for edit verification without AX, CGEvents, or
    /// the user's clipboard. Production uses the normal TextInjector lanes.
    struct VoiceEditInjectionHooks {
        let target: () -> TextInjector.InjectionTarget
        let snapshot: () -> CaretContext.Snapshot
        let insert: (String) -> TextInjector.InsertResult
        let leaveOnClipboard: (String) -> Void
    }
    var voiceEditInjectionHooks: VoiceEditInjectionHooks?

    /// Runs the real delivery pipeline with isolated AX and event dependencies.
    struct DeliveryHooks {
        let injector: TextInjector.Hooks
        let snapshot: () -> CaretContext.Snapshot
    }
    var deliveryHooks: DeliveryHooks?

    private func deliverySnapshot(frontmostPID: pid_t?) -> CaretContext.Snapshot {
        deliveryHooks?.snapshot() ?? CaretContext.snapshot(frontmostPID: frontmostPID)
    }

    private func deliveryFocusedElement(frontmostPID: pid_t) -> AXUIElement? {
        if let hooks = deliveryHooks { return hooks.snapshot().focusedElement }
        return CaretContext.focusedElement(frontmostPID: frontmostPID)
    }

    private func injectionTarget(voiceEdit: Bool) -> TextInjector.InjectionTarget {
        if let hooks = deliveryHooks { return hooks.injector.target() }
        if voiceEdit, let hooks = voiceEditInjectionHooks { return hooks.target() }
        let app = NSWorkspace.shared.frontmostApplication
        return TextInjector.InjectionTarget(
            secureInput: IsSecureEventInputEnabled(),
            pid: app?.processIdentifier,
            bundleIdentifier: app?.bundleIdentifier
        )
    }

    /// Main-thread secure re-read protects clipboard fallback as well as typing.
    private func leaveOnClipboardIfAllowed(_ text: String, voiceEdit: Bool) -> Bool {
        if let hooks = deliveryHooks {
            guard !hooks.injector.target().secureInput else { return true }
            hooks.injector.pasteboard.clearContents()
            hooks.injector.pasteboard.setString(text, forType: .string)
            return false
        }
        if !voiceEdit { return Self.appSwitchAbortLeaveOnMain(text: text) }
        guard !injectionTarget(voiceEdit: true).secureInput else { return true }
        if let hooks = voiceEditInjectionHooks { hooks.leaveOnClipboard(text) }
        else { TextInjector.leaveTranscriptOnClipboard(text) }
        return false
    }

    /// Dictionary-correction hook — applied BEFORE injection and history.
    var onTranscription: ((String, String) -> (String, [CorrectionRecord]))?

    /// Snippet-expansion hook — applied after dictionary correction.
    var onSnippetExpand: ((String) -> String)?

    /// History-logging hook with the final expanded text.
    /// Sixth arg is optional history entry ID to replace (retry path).
    var onTranscriptionLogged: ((String, String, Bool, String?, Bool, UUID?) -> Void)?

    /// Edit history contains only the result and spoken instruction. Audio is
    /// not retryable without the original selection, which is never stored.
    var onVoiceEditLogged: ((String, String, String, Bool, Bool) -> Void)?

    /// History hook for a hold the HUD watchdog abandoned: text, engine id,
    /// audio path. Separate from `onTranscriptionLogged` because the row must
    /// read "Saved in History" — nothing was typed or left on the clipboard.
    var onAbandonedHoldSaved: ((String, String, String?) -> Void)?

    /// Fired on the main thread after a confirmed insert with the delivered text
    /// (for inline correction watching). Not called for dedupe or failed inserts.
    var onTextInserted: ((String) -> Void)?

    /// Invoked on the main thread when dictionary/phonetic corrections fire.
    var onCorrectionsRecorded: (([CorrectionRecord]) -> Void)?

    /// Terminal failure hook (transcription, injection, audio capture).
    var onFailure: ((DictationFailure) -> Void)?

    /// Presentation ownership lives with the recorder HUD, not this pipeline's
    /// latest lifecycle token. A newer startup can advance that token and then
    /// abort before it ever presents, leaving an older processing hold entitled
    /// to its terminal failure.
    var presentedHoldToken: (() -> UInt64?)?

    private func shouldNotifyFailure(for token: UInt64) -> Bool {
        token == heldCaretToken || presentedHoldToken?() == token
    }

    /// Capture caret AX context + frontmost PID on the main thread at
    /// recording-will-start. Replaces any prior hold and bumps the generation token.
    /// Reads frontmost PID once so AX snapshot and held PID cannot desync.
    @discardableResult
    func holdCaretSnapshotFromRecordingWillStart(
        voiceEditEnabled: Bool = true,
        shiftHeld: Bool = false
    ) -> UInt64 {
        assert(Thread.isMainThread, "holdCaretSnapshotFromRecordingWillStart requires main thread")
        heldCaretToken &+= 1
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let snapshot = CaretContext.snapshot(frontmostPID: pid)
        heldCaretSnapshot = snapshot
        heldFrontmostPID = pid
        switch VoiceEditRouting.decide(
            snapshot: snapshot,
            enabled: voiceEditEnabled,
            shiftHeld: shiftHeld
        ) {
        case .edit(let selection):
            voiceEditIntents[heldCaretToken] = .edit(selection: selection)
        case .selectionTooLong(let utf16Count):
            voiceEditIntents[heldCaretToken] = .selectionTooLong
            vlog("voice edit selection too long: \(utf16Count) UTF-16 units")
        case .dictate:
            break
        }
        return heldCaretToken
    }

    /// Drop held snapshot + PID (cancel / abort / stop without inject).
    /// When `matching` is set, clears only if the current token still matches
    /// that session — older finish/fail paths must not wipe a newer hold.
    func clearHeldCaretSnapshot(matching token: UInt64? = nil) {
        if let token {
            voiceEditIntents.removeValue(forKey: token)
            if heldCaretToken != token { return }
        } else {
            voiceEditIntents.removeAll()
        }
        heldCaretSnapshot = nil
        heldFrontmostPID = nil
    }

    /// Package-visible held state for lifecycle unit tests.
    var test_heldCaretToken: UInt64 { heldCaretToken }
    var test_heldCaretSnapshot: CaretContext.Snapshot? { heldCaretSnapshot }
    var test_heldFrontmostPID: pid_t? { heldFrontmostPID }

    func isVoiceEditHold(_ token: UInt64) -> Bool {
        voiceEditIntents[token] != nil
    }

    private func consumeVoiceEditIntent(matching token: UInt64) -> VoiceEditIntent? {
        voiceEditIntents.removeValue(forKey: token)
    }

    /// Hold tokens whose processing HUD was already dismissed by the
    /// recorder's watchdog. A late result for one of these is saved to History
    /// only — typing it into whatever app is focused by then would be a
    /// surprise. Main-thread only; capped so a never-arriving result cannot
    /// grow it.
    private var abandonedHoldTokens: Set<UInt64> = []
    private static let abandonedHoldTokenCap = 8

    /// Marks a live hold as abandoned (main thread).
    func markHoldAbandoned(_ token: UInt64) {
        assert(Thread.isMainThread, "markHoldAbandoned requires main thread")
        abandonedHoldTokens.insert(token)
        if abandonedHoldTokens.count > Self.abandonedHoldTokenCap,
           let oldest = abandonedHoldTokens.min() {
            abandonedHoldTokens.remove(oldest)
        }
    }

    /// One-shot: true when `token` was abandoned, and forgets it. Retries
    /// (`replaceHistoryEntryID != nil`) never consume — they already save
    /// without insertion. Main thread only.
    private func consumeAbandonedHold(token: UInt64, replaceHistoryEntryID: UUID?) -> Bool {
        guard replaceHistoryEntryID == nil else { return false }
        return abandonedHoldTokens.remove(token) != nil
    }

    var test_abandonedHoldTokens: Set<UInt64> { abandonedHoldTokens }

    /// Test hook: install a synthetic held snapshot (no AX) on the main thread.
    @discardableResult
    func test_holdSnapshot(_ snapshot: CaretContext.Snapshot, frontmostPID: pid_t? = nil) -> UInt64 {
        assert(Thread.isMainThread, "test_holdSnapshot requires main thread")
        heldCaretToken &+= 1
        heldCaretSnapshot = snapshot
        heldFrontmostPID = frontmostPID
        return heldCaretToken
    }

    /// Test-only route seam; production capture always goes through the AX
    /// snapshot path above.
    @discardableResult
    func test_holdVoiceEditSnapshot(_ snapshot: CaretContext.Snapshot, frontmostPID: pid_t? = nil) -> UInt64 {
        let token = test_holdSnapshot(snapshot, frontmostPID: frontmostPID)
        switch VoiceEditRouting.decide(snapshot: snapshot, enabled: true, shiftHeld: false) {
        case .edit(let selection): voiceEditIntents[token] = .edit(selection: selection)
        case .selectionTooLong: voiceEditIntents[token] = .selectionTooLong
        case .dictate: break
        }
        return token
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

    /// Diagnostic identity for an app-switch abort: the target app (anchored
    /// at hotkey release by AudioRecorder) vs. which app owned frontmost at
    /// injection time. Bundle identifiers only — never window titles or
    /// content (transcript-privacy rule). Added after two live aborts
    /// (2026-08-09); re-worded when targeting moved from hold-start to
    /// release (2026-08-10).
    static func vlogAppSwitchAbort(heldPID: pid_t?, currentPID: pid_t?) {
        func bundleID(_ pid: pid_t?) -> String {
            guard let pid else { return "nil" }
            return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid:\(pid)"
        }
        vlog("inject abort: frontmost changed between release and insert — target=\(bundleID(heldPID)) current=\(bundleID(currentPID))")
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
    /// `onHoldAbandoned` releases live HUD ownership on main without completing
    /// transcription. `completion` remains terminal so temporary audio stays alive.
    func transcribeAndLog(
        audioURL: URL,
        audioIsTemporary: Bool = false,
        replaceHistoryEntryID: UUID? = nil,
        sessionHeldToken providedToken: UInt64? = nil,
        sessionHeldSnapshot providedSnapshot: CaretContext.Snapshot? = nil,
        sessionHeldFrontmostPID providedPID: pid_t? = nil,
        onHoldAbandoned: (() -> Void)? = nil,
        completion: ((InjectPipelineResult) -> Void)? = nil
    ) {
        guard let selector = engineSelector else {
            completion?(.failed)
            return
        }

        let audioPath = Self.historyAudioPath(audioURL: audioURL, audioIsTemporary: audioIsTemporary)
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
                    let service = self.cloudServiceProvider(cloudModel)
                    if let gemini = service as? GeminiTranscriptionService {
                        gemini.smartMode = selector.removeFillerWordsEnabled
                        gemini.vocabulary = selector.geminiVocabularyProvider?() ?? []
                    }
                    let text = try await service.transcribe(
                        audioURL: audioURL,
                        apiKey: key,
                        model: cloudModel,
                        language: selector.selectedLanguage
                    )
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw CloudTranscriptionError.emptyTranscript(provider: cloudModel.provider)
                    }
                    let cleaned = await self.prepareTranscript(text, holdToken: sessionHeldToken, replaceHistoryEntryID: replaceID)
                    let transformed = cleaned.text
                    self.finishTranscription(
                        text: transformed,
                        hadExplicitTrailingNewline: cleaned.hadExplicitTrailingNewline,
                        engineID: engineTag,
                        audioPath: audioPath,
                        replaceHistoryEntryID: replaceID,
                        sessionHeldToken: sessionHeldToken,
                        sessionHeldSnapshot: sessionHeldSnapshot,
                        sessionHeldFrontmostPID: sessionHeldFrontmostPID,
                        completion: completion
                    )
                } catch {
                    let emptyResponse = (error as? CloudTranscriptionError)?.isEmptyTranscript == true
                    let recoverInBackground = await MainActor.run {
                        guard emptyResponse, replaceID == nil,
                              !self.isVoiceEditHold(sessionHeldToken) else { return false }
                        self.markHoldAbandoned(sessionHeldToken)
                        // Completion still owns audio cleanup and must wait for local ASR.
                        onHoldAbandoned?()
                        return true
                    }
                    if emptyResponse {
                        vlog("cloud empty transcript [\(engineTag)] — recovering locally")
                    } else {
                        self.logger.error("Cloud transcription failed [\(engineTag)]: \(error.localizedDescription)")
                        vlog("cloud transcription error [\(engineTag)]: \(error.localizedDescription) — falling back to local")
                    }
                    self.transcribeLocally(
                        audioURL: audioURL,
                        audioPath: audioPath,
                        replaceHistoryEntryID: replaceID,
                        sessionHeldToken: sessionHeldToken,
                        sessionHeldSnapshot: sessionHeldSnapshot,
                        sessionHeldFrontmostPID: sessionHeldFrontmostPID,
                        saveWithoutInsertion: recoverInBackground,
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

    static func historyAudioPath(audioURL: URL, audioIsTemporary: Bool) -> String? {
        audioIsTemporary ? nil : audioURL.path
    }

    /// Streaming entry point: takes text already produced by a live session.
    /// - Parameters sessionHeld*: when `sessionHeldToken` is non-nil, use that
    ///   stop-sampled triple (before streaming finalize Tasks) instead of
    ///   reading `heldCaret*` at entry.
    func logStreamedTranscription(
        text: String,
        engineID: String,
        retainedAudioURL: URL? = nil,
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
            let cleaned = await self.prepareTranscript(text, holdToken: sessionHeldToken, replaceHistoryEntryID: nil)
            let transformed = cleaned.text
            self.finishTranscription(
                text: transformed,
                hadExplicitTrailingNewline: cleaned.hadExplicitTrailingNewline,
                engineID: engineID,
                audioPath: Self.streamedAudioPath(retainedAudioURL),
                replaceHistoryEntryID: nil,
                sessionHeldToken: sessionHeldToken,
                sessionHeldSnapshot: sessionHeldSnapshot,
                sessionHeldFrontmostPID: sessionHeldFrontmostPID,
                completion: completion
            )
        }
    }

    /// The stream success path has no audio URL until `AudioRecorder` has
    /// retained its raw snapshot. Keep nil explicit when retention failed so
    /// a successful transcript never gets a fabricated history path.
    static func streamedAudioPath(_ retainedAudioURL: URL?) -> String? {
        retainedAudioURL?.path
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
        audioPath: String?,
        replaceHistoryEntryID: UUID?,
        sessionHeldToken: UInt64,
        sessionHeldSnapshot: CaretContext.Snapshot?,
        sessionHeldFrontmostPID: pid_t?,
        // Survives eviction from the bounded watchdog token set during slow recovery.
        saveWithoutInsertion: Bool = false,
        completion: ((InjectPipelineResult) -> Void)? = nil
    ) {
        guard let selector = engineSelector else {
            completion?(.failed)
            return
        }

        let engine = localEngineProvider?() ?? selector.makeEngine()
        logger.info("Transcribing \(audioURL.lastPathComponent) with engine '\(engine.id)'")

        Task {
            do {
                let text = try await engine.transcribe(audioURL: audioURL)
                let cleaned = await self.prepareTranscript(text, holdToken: sessionHeldToken, replaceHistoryEntryID: replaceHistoryEntryID)
                let transformed = cleaned.text
                self.finishTranscription(
                    text: transformed,
                    hadExplicitTrailingNewline: cleaned.hadExplicitTrailingNewline,
                    engineID: engine.id,
                    audioPath: audioPath,
                    replaceHistoryEntryID: replaceHistoryEntryID,
                    sessionHeldToken: sessionHeldToken,
                    sessionHeldSnapshot: sessionHeldSnapshot,
                    sessionHeldFrontmostPID: sessionHeldFrontmostPID,
                    saveWithoutInsertion: saveWithoutInsertion,
                    completion: completion
                )
            } catch {
                self.logger.error("Transcription failed [\(engine.id)]: \(error.localizedDescription)")
                vlog("transcription error [\(engine.id)]: \(error.localizedDescription)")
                self.reportTranscriptionFailure(
                    engineID: engine.id,
                    error: error,
                    audioPath: audioPath,
                    replaceHistoryEntryID: replaceHistoryEntryID,
                    sessionHeldToken: sessionHeldToken,
                    saveWithoutInsertion: saveWithoutInsertion,
                    completion: completion
                )
            }
        }
    }

    func reportTranscriptionFailure(
        engineID: String,
        error: Error? = nil,
        audioPath: String?,
        replaceHistoryEntryID: UUID?,
        sessionHeldToken: UInt64,
        saveWithoutInsertion: Bool = false,
        completion: ((InjectPipelineResult) -> Void)?
    ) {
        DispatchQueue.main.async {
            let abandoned = self.consumeAbandonedHold(
                token: sessionHeldToken,
                replaceHistoryEntryID: replaceHistoryEntryID
            ) || saveWithoutInsertion
            if replaceHistoryEntryID == nil,
               self.consumeVoiceEditIntent(matching: sessionHeldToken) != nil {
                self.clearHeldCaretSnapshot(matching: sessionHeldToken)
                Self.discardUnloggedAudio(audioPath: audioPath, shouldLog: false)
                if !abandoned, self.shouldNotifyFailure(for: sessionHeldToken) { self.onFailure?(.voiceEditFailed) }
                completion?(.failed)
                return
            }
            if replaceHistoryEntryID == nil {
                self.clearHeldCaretSnapshot(matching: sessionHeldToken)
            }
            // The user already saw this hold dismissed; no late error pill.
            if !abandoned, self.shouldNotifyFailure(for: sessionHeldToken) {
                let failure: DictationFailure
                if let appleError = error as? AppleSpeechEngineError,
                   case .assetNotInstalled = appleError {
                    failure = .speechModelDownloading
                } else {
                    failure = .transcriptionFailed
                }
                self.onFailure?(failure)
            }
            self.onTranscriptionLogged?("", engineID, false, audioPath, true, replaceHistoryEntryID)
            completion?(.failed)
        }
    }

    /// Strips known provider audio-event captions, then applies caps, spoken
    /// punctuation (full table if codeAware; sentence commands always), and
    /// DotCompound. Package-visible for pipeline-gate unit tests. This applies
    /// regardless of optional AI cleanup so every ASR path gets the same guard.
    static func preprocessBeforeCleanup(
        _ text: String,
        codeAware: Bool,
        removeFillerWords: Bool = false
    ) -> String {
        let withoutSoundTags = NonSpeechAnnotations.stripRecognizedTags(text)
        let capped = SpokenCapitalization.apply(withoutSoundTags)
        let punctuated = DotCompoundNumberNormalizer.apply(
            SpokenPunctuation.apply(capped, codeAware: codeAware)
        )
        return HesitationNormalizer.normalize(
            punctuated,
            codeAware: codeAware,
            enabled: removeFillerWords
        )
    }

    private func prepareTranscript(
        _ text: String,
        holdToken: UInt64,
        replaceHistoryEntryID: UUID?
    ) async -> PreprocessedTranscript {
        let isEdit = await MainActor.run {
            replaceHistoryEntryID == nil && self.isVoiceEditHold(holdToken)
        }
        if isEdit {
            return PreprocessedTranscript(
                text: Self.normalizeTranscriptForInjection(NonSpeechAnnotations.stripRecognizedTags(text)),
                hadExplicitTrailingNewline: false
            )
        }
        let cleaned = await applyCleanup(text)
        return PreprocessedTranscript(
            text: await applyAutoTransform(cleaned.text),
            hadExplicitTrailingNewline: cleaned.hadExplicitTrailingNewline
        )
    }

    private func applyCleanup(_ text: String) async -> PreprocessedTranscript {
        let preprocessed = Self.preprocessForCleanup(
            text,
            codeAware: codeAware,
            removeFillerWords: removeFillerWordsEnabled
        )
        guard cleanupEnabled, let svc = cleanupService, !preprocessed.text.isEmpty else { return preprocessed }

        let wordCount = preprocessed.text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
        guard wordCount > 3 else {
            vlog("cleanup skipped — short input (\(wordCount) words)")
            return preprocessed
        }

        let cleanupStart = Date()
        do {
            let cleaned = try await svc.cleanup(preprocessed.text, codeAware: codeAware, styleInstruction: styleInstruction)
            vlog("cleanup \(String(format: "%.2f", Date().timeIntervalSince(cleanupStart)))s")
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return preprocessed }
            guard Self.cleanupLooksSane(input: preprocessed.text, output: trimmed) else {
                vlog("cleanup rejected — output diverged from input (likely answered); using raw")
                return preprocessed
            }
            // Cleanup sometimes re-expands joined identifiers (`conduct.mdc` →
            // `conduct dot mdc`) and cleanupLooksSane accepts that. Re-run the
            // deterministic pass so spoken punctuation wins last.
            // Post-SP only on successful cleanup; Caps does not re-run here.
            return PreprocessedTranscript(
                text: SpokenPunctuation.apply(trimmed, codeAware: codeAware),
                hadExplicitTrailingNewline: preprocessed.hadExplicitTrailingNewline
            )
        } catch {
            vlog("cleanup failed: \(error.localizedDescription) — using raw")
            return preprocessed
        }
    }

    /// Records only whether preprocessing created a terminal newline after
    /// provider edge whitespace was removed. That distinguishes a spoken
    /// `new line` command from an incidental provider trailing newline without
    /// retaining the raw provider response beyond this stage.
    static func preprocessForCleanup(
        _ text: String,
        codeAware: Bool,
        removeFillerWords: Bool = false
    ) -> PreprocessedTranscript {
        let preprocessed = preprocessBeforeCleanup(
            text,
            codeAware: codeAware,
            removeFillerWords: removeFillerWords
        )
        let providerEdgeNormalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let formattingProbe = preprocessBeforeCleanup(
            providerEdgeNormalized,
            codeAware: codeAware,
            removeFillerWords: removeFillerWords
        )
        return PreprocessedTranscript(
            text: preprocessed,
            hadExplicitTrailingNewline: formattingProbe.last?.isNewline == true
        )
    }

    /// Shared finish-stage normalization for ordinary provider edge whitespace.
    /// Formatting intent has already been reduced to `hadExplicitTrailingNewline`.
    static func normalizeTranscriptForInjection(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Model edge whitespace is incidental; selected boundary whitespace belongs
    /// to the document and must survive the replacement.
    static func prepareVoiceEditResult(_ text: String, selection: String?) -> String {
        let body = normalizeTranscriptForInjection(text)
        guard !body.isEmpty, let selection else { return body }
        let leading = selection.prefix(while: { $0.isWhitespace })
        let trailing = selection.dropFirst(leading.count).reversed().prefix(while: { $0.isWhitespace }).reversed()
        return String(leading) + body + String(trailing)
    }

    /// A history retry has no live hold; pin it to its own late target sample.
    static func expectedDeliveryPID(heldPID: pid_t?, isHistoryRetry: Bool, latePID: pid_t?) -> pid_t? {
        isHistoryRetry ? latePID : heldPID
    }

    private func applyAutoTransform(_ text: String) async -> String {
        guard let transform = engineSelector?.autoRunTransform else { return text }
        do {
            let result = try await TransformRunner.run(
                prompt: transform.prompt,
                over: text,
                credentials: engineSelector?.transformCredentialsProvider?() ?? .unavailable
            )
            return result.isEmpty ? text : result
        } catch {
            vlog("auto-run transform failed: \(error.localizedDescription) — using pre-transform text")
            return text
        }
    }

    static func cleanupLooksSane(input: String, output: String) -> Bool {
        func words(_ text: String) -> [String] {
            text.lowercased().replacingOccurrences(of: "’", with: "'")
                .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
                .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
                .filter { !$0.isEmpty }
        }
        func expand(_ word: String) -> [String] {
            let irregular: [String: [String]] = [
                "can't": ["can", "not"], "cannot": ["can", "not"],
                "won't": ["will", "not"], "shan't": ["shall", "not"],
                "i'm": ["i", "am"], "let's": ["let", "us"]
            ]
            if let expanded = irregular[word] { return expanded }
            let negatives: Set<String> = [
                "isn't", "aren't", "wasn't", "weren't", "don't", "doesn't", "didn't",
                "hasn't", "haven't", "hadn't", "couldn't", "wouldn't", "shouldn't",
                "mustn't", "needn't", "mightn't"
            ]
            if negatives.contains(word) { return [String(word.dropLast(3)), "not"] }
            let pronouns: Set<String> = ["i", "you", "he", "she", "it", "we", "they", "there", "that", "what", "who"]
            for (suffix, verb) in [("'ll", "will"), ("'re", "are"), ("'ve", "have")] {
                if word.hasSuffix(suffix) {
                    let stem = String(word.dropLast(suffix.count))
                    if pronouns.contains(stem) { return [stem, verb] }
                }
            }
            // 's and 'd can mean different verbs (or possession). Preserve
            // them unless a later, context-aware contract can disambiguate.
            return [word]
        }
        let inputWords = words(input)
        guard !inputWords.isEmpty else { return true }
        let outWords = words(output).flatMap(expand)
        guard !outWords.isEmpty else { return false }

        // Punctuation cleanup must not turn 12.50 into 12 50, or -5 into 5.
        func numbers(_ text: String) -> [String] {
            let expression = try! NSRegularExpression(pattern: #"[+-]?\d+(?:[.,]\d+)*"#)
            return expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        }
        guard numbers(input) == numbers(output) else { return false }

        // Keep standalone sentences even when all of their words can also be
        // fillers. Punctuation can be added elsewhere by the cleanup pass.
        let sentences = input.split(whereSeparator: { ".!?".contains($0) }).map { words(String($0)) }
        var protected = Set<Int>()
        var offset = 0
        for sentence in sentences {
            if sentence == ["like"] || sentence == ["you", "know"] {
                protected.formUnion(offset..<(offset + sentence.count))
            }
            offset += sentence.count
        }
        let asideExpression = try! NSRegularExpression(pattern: #"(?i)(?:^|[,—])\s*(like|you\s+know)\s*(?=[,—.!?]|$)"#)
        let asideStarts = Set(asideExpression.matches(in: input, range: NSRange(input.startIndex..., in: input))
            .compactMap { match -> Int? in
                guard let range = Range(match.range(at: 1), in: input) else { return nil }
                return words(String(input[..<range.lowerBound])).count
            })
        let clauseStarts: Set<String> = ["i", "you", "he", "she", "it", "we", "they", "there", "this", "that"]
        let fillerLeads: Set<String> = ["um", "uh", "so"]
        var inputIndex = 0
        var outputIndex = 0
        while inputIndex < inputWords.count {
            let word = inputWords[inputIndex]
            let equivalent = expand(word)
            if outputIndex + equivalent.count <= outWords.count,
               Array(outWords[outputIndex..<(outputIndex + equivalent.count)]) == equivalent {
                inputIndex += 1
                outputIndex += equivalent.count
                continue
            }
            if word == "um" || word == "uh" { inputIndex += 1; continue }
            if !protected.contains(inputIndex), word == "like", inputIndex + 1 < inputWords.count,
               (asideStarts.contains(inputIndex) || ((inputIndex == 0 || fillerLeads.contains(inputWords[inputIndex - 1]))
                && clauseStarts.contains(expand(inputWords[inputIndex + 1])[0]))) {
                inputIndex += 1
                continue
            }
            if !protected.contains(inputIndex), word == "you", inputIndex + 1 < inputWords.count,
               inputWords[inputIndex + 1] == "know" {
                let after = inputIndex + 2
                let startsAside = inputIndex == 0 || fillerLeads.contains(inputWords[inputIndex - 1])
                if asideStarts.contains(inputIndex)
                    || (startsAside && after < inputWords.count && clauseStarts.contains(expand(inputWords[after])[0])) {
                    inputIndex += 2
                    continue
                }
            }
            return false
        }
        return outputIndex == outWords.count
    }

    /// Failed edits have no usable result to retain. Their audio is an
    /// instruction that cannot safely be retried without its original selection.
    private func failVoiceEdit(
        token: UInt64,
        audioPath: String?,
        failure: DictationFailure = .voiceEditFailed,
        completion: ((InjectPipelineResult) -> Void)?
    ) {
        let abandoned = consumeAbandonedHold(token: token, replaceHistoryEntryID: nil)
        clearHeldCaretSnapshot(matching: token)
        Self.discardUnloggedAudio(audioPath: audioPath, shouldLog: false)
        if !abandoned, shouldNotifyFailure(for: token) { onFailure?(failure) }
        completion?(.failed)
    }

    func finishTranscription(
        text: String,
        hadExplicitTrailingNewline: Bool,
        engineID: String,
        audioPath: String?,
        replaceHistoryEntryID: UUID?,
        sessionHeldToken: UInt64,
        sessionHeldSnapshot: CaretContext.Snapshot?,
        sessionHeldFrontmostPID: pid_t?,
        voiceEditInstruction: String? = nil,
        saveWithoutInsertion: Bool = false,
        completion: ((InjectPipelineResult) -> Void)?
    ) {
        let trimmed = voiceEditInstruction == nil
            ? Self.normalizeTranscriptForInjection(text)
            : text
        self.logger.info("Transcribed \(trimmed.count) chars with engine '\(engineID)'")
        vlog("transcribed \(trimmed.count) chars [\(engineID)]")

        DispatchQueue.main.async {
            if replaceHistoryEntryID == nil, voiceEditInstruction == nil,
               let intent = self.consumeVoiceEditIntent(matching: sessionHeldToken) {
                switch intent {
                case .selectionTooLong:
                    self.failVoiceEdit(token: sessionHeldToken, audioPath: audioPath, failure: .voiceEditSelectionTooLong, completion: completion)
                case .edit(let selection):
                    guard !trimmed.isEmpty else {
                        self.failVoiceEdit(token: sessionHeldToken, audioPath: audioPath, completion: completion)
                        return
                    }
                    let credentials = self.engineSelector?.transformCredentialsProvider?() ?? .unavailable
                    Task {
                        do {
                            let result = try await self.runVoiceEditTransform(trimmed, selection, credentials)
                            guard VoiceEditRouting.resultLooksUsable(result, over: selection) else {
                                DispatchQueue.main.async {
                                    self.failVoiceEdit(token: sessionHeldToken, audioPath: audioPath, completion: completion)
                                }
                                return
                            }
                            self.finishTranscription(
                                text: Self.prepareVoiceEditResult(result, selection: selection),
                                hadExplicitTrailingNewline: false,
                                engineID: engineID,
                                audioPath: audioPath,
                                replaceHistoryEntryID: nil,
                                sessionHeldToken: sessionHeldToken,
                                sessionHeldSnapshot: sessionHeldSnapshot,
                                sessionHeldFrontmostPID: sessionHeldFrontmostPID,
                                voiceEditInstruction: trimmed,
                                completion: completion
                            )
                        } catch {
                            DispatchQueue.main.async {
                                self.failVoiceEdit(token: sessionHeldToken, audioPath: audioPath, completion: completion)
                            }
                        }
                    }
                }
                return
            }
            guard !trimmed.isEmpty else {
                let abandoned = self.consumeAbandonedHold(
                    token: sessionHeldToken,
                    replaceHistoryEntryID: replaceHistoryEntryID
                ) || saveWithoutInsertion
                if replaceHistoryEntryID == nil {
                    self.clearHeldCaretSnapshot(matching: sessionHeldToken)
                }
                if !abandoned, self.shouldNotifyFailure(for: sessionHeldToken) {
                    self.onFailure?(voiceEditInstruction == nil ? .transcriptionFailed : .voiceEditFailed)
                }
                if voiceEditInstruction == nil, audioPath != nil || saveWithoutInsertion {
                    self.onTranscriptionLogged?("", engineID, false, audioPath, true, replaceHistoryEntryID)
                }
                completion?(.failed)
                return
            }
            let (corrected, records) = voiceEditInstruction == nil
                ? (self.onTranscription?(trimmed, engineID) ?? (trimmed, []))
                : (trimmed, [])
            if !records.isEmpty { self.onCorrectionsRecorded?(records) }
            let expanded = voiceEditInstruction == nil ? (self.onSnippetExpand?(corrected) ?? corrected) : corrected
            let snippetExpansionOccurred = expanded != corrected
            let hasExplicitCustomTransform = self.engineSelector?.autoRunTransform != nil
            let abandoned = self.consumeAbandonedHold(
                token: sessionHeldToken,
                replaceHistoryEntryID: replaceHistoryEntryID
            ) || saveWithoutInsertion
            if replaceHistoryEntryID != nil || abandoned {
                // Retrying a recording is a History operation. Focus may be on
                // History's search field or an unrelated app by the time ASR ends.
                // An abandoned hold (HUD watchdog fired) is saved the same way:
                // the user moved on, so nothing is typed into the focused app.
                let saved = voiceEditInstruction != nil ? expanded : Self.prepareResolvedSnapshotTextForInjection(
                    expanded: expanded,
                    snapshot: .unknown,
                    codeAware: self.codeAware,
                    hasExplicitCustomTransform: hasExplicitCustomTransform,
                    snippetExpansionOccurred: snippetExpansionOccurred,
                    hadExplicitTrailingNewline: hadExplicitTrailingNewline
                )
                if abandoned {
                    self.clearHeldCaretSnapshot(matching: sessionHeldToken)
                }
                if let instruction = voiceEditInstruction {
                    self.onVoiceEditLogged?(saved, instruction, engineID, false, true)
                    Self.discardUnloggedAudio(audioPath: audioPath, shouldLog: false)
                } else if abandoned, let onAbandonedHoldSaved = self.onAbandonedHoldSaved {
                    onAbandonedHoldSaved(saved, engineID, audioPath)
                } else {
                    self.onTranscriptionLogged?(saved, engineID, false, audioPath, false, replaceHistoryEntryID)
                }
                completion?(.savedToHistory)
                return
            }
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
                    let target = self.injectionTarget(voiceEdit: voiceEditInstruction != nil)
                    return (target.pid, target.secureInput)
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
                    if voiceEditInstruction != nil {
                        textToInject = expanded
                        liveSecure = DispatchQueue.main.sync {
                            self.injectionTarget(voiceEdit: true).secureInput
                        }
                    } else {
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
                                self.deliveryHooks?.snapshot() ?? CaretContext.snapshot()
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
                            self.deliveryHooks?.injector.target().secureInput ?? IsSecureEventInputEnabled()
                        }
                        textToInject = Self.applyInjectTransforms(
                            expanded: Self.prepareResolvedSnapshotTextForInjection(
                                expanded: expanded,
                                snapshot: resolved,
                                codeAware: self.codeAware,
                                hasExplicitCustomTransform: hasExplicitCustomTransform,
                                snippetExpansionOccurred: snippetExpansionOccurred,
                                hadExplicitTrailingNewline: hadExplicitTrailingNewline
                            ),
                            snapshot: resolved,
                            secureInput: liveSecure,
                            smartLeadingSpaceEnabled: self.smartLeadingSpaceEnabled,
                            codeAware: self.codeAware,
                            capitalizedDictionaryTerms: capitalizedTerms
                        )
                    }
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
                        Self.vlogAppSwitchAbort(heldPID: heldPID, currentPID: currentPID)
                        abortLeaveBecameSecure = self.leaveOnClipboardIfAllowed(textToInject, voiceEdit: voiceEditInstruction != nil)
                    }
                    insertResult = .failed
                    proceededToInsert = false
                case .proceedInsert:
                    // Re-sample frontmost immediately before insert (TOCTOU vs
                    // early PID). Late mismatch → same abort-leave as above.
                    enum LateInjectDecision {
                        case insert(pid: pid_t)
                        case abort(becameSecure: Bool)
                    }
                    let late: LateInjectDecision = DispatchQueue.main.sync {
                        let target = self.injectionTarget(voiceEdit: voiceEditInstruction != nil)
                        let latePID = target.pid
                        if voiceEditInstruction != nil {
                            if target.secureInput { return .abort(becameSecure: true) }
                            guard let heldPID, latePID == heldPID else {
                                return .abort(becameSecure: self.leaveOnClipboardIfAllowed(textToInject, voiceEdit: true))
                            }
                            let fresh = self.voiceEditInjectionHooks?.snapshot()
                                ?? self.deliverySnapshot(frontmostPID: heldPID)
                            guard sessionHeldToken == self.heldCaretToken,
                                  VoiceEditRouting.selectionMatches(held: heldAtStart, fresh: fresh) else {
                                return .abort(becameSecure: self.leaveOnClipboardIfAllowed(textToInject, voiceEdit: true))
                            }
                        }
                        if Self.shouldAbortInjectAfterTransforms(
                            replaceHistoryEntryID: replaceID,
                            heldPID: heldPID,
                            latePID: latePID
                        ) {
                            Self.vlogAppSwitchAbort(heldPID: heldPID, currentPID: latePID)
                            return .abort(
                                becameSecure: self.leaveOnClipboardIfAllowed(textToInject, voiceEdit: voiceEditInstruction != nil)
                            )
                        }
                        guard let deliveryPID = Self.expectedDeliveryPID(
                            heldPID: heldPID, isHistoryRetry: replaceID != nil, latePID: latePID
                        ) else {
                            return .abort(becameSecure: self.leaveOnClipboardIfAllowed(textToInject, voiceEdit: voiceEditInstruction != nil))
                        }
                        return .insert(pid: deliveryPID)
                    }
                    switch late {
                    case .abort(let becameSecure):
                        abortLeaveBecameSecure = becameSecure
                        insertResult = .failed
                        proceededToInsert = false
                    case .insert(let deliveryPID):
                        // Undo relies on the host's ⌘Z: replacement is one inject,
                        // with no delete or select-all step in any lane.
                        if voiceEditInstruction != nil, let hooks = self.voiceEditInjectionHooks {
                            insertResult = hooks.insert(textToInject)
                        } else {
                            insertResult = TextInjector(hooks: self.deliveryHooks?.injector).insert(
                                textToInject,
                                expectedTargetPID: deliveryPID,
                                validateSelection: voiceEditInstruction == nil ? nil : {
                                    VoiceEditRouting.selectionMatches(
                                        held: heldAtStart,
                                        fresh: self.deliverySnapshot(frontmostPID: deliveryPID)
                                    )
                                },
                                validateField: heldAtStart?.focusedElement.map { heldElement in
                                    {
                                        guard let fresh = self.deliveryFocusedElement(frontmostPID: deliveryPID) else {
                                            return voiceEditInstruction == nil ? nil : false
                                        }
                                        return VoiceEditRouting.fieldMatches(held: heldElement, fresh: fresh)
                                    }
                                },
                                preserveBoundaryWhitespace: voiceEditInstruction != nil
                            )
                        }
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
                        ? self.injectionTarget(voiceEdit: voiceEditInstruction != nil).secureInput
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
                        if let instruction = voiceEditInstruction {
                            self.onVoiceEditLogged?(
                                textToInject, instruction, engineID,
                                insertResult.wasInjectedForHistory, false
                            )
                        } else {
                            self.onTranscriptionLogged?(
                                textToInject,
                                engineID,
                                insertResult.wasInjectedForHistory,
                                audioPath,
                                false,
                                replaceID
                            )
                        }
                    }
                    // A retry's audio still belongs to the row being retried.
                    if replaceID == nil {
                        Self.discardUnloggedAudio(audioPath: audioPath, shouldLog: outcome.shouldLog && voiceEditInstruction == nil)
                    }
                    if let failure = outcome.failure, self.shouldNotifyFailure(for: sessionHeldToken) {
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

    /// Preparation that runs after the final AX snapshot resolves, so it can
    /// reject a period before visible text while remaining independent of AI
    /// cleanup and provider selection.
    static func prepareResolvedSnapshotTextForInjection(
        expanded: String,
        snapshot: CaretContext.Snapshot,
        codeAware: Bool,
        hasExplicitCustomTransform: Bool,
        snippetExpansionOccurred: Bool,
        hadExplicitTrailingNewline: Bool = false
    ) -> String {
        TerminalPunctuation.prepare(
            expanded,
            snapshot: snapshot,
            codeAware: codeAware,
            hasExplicitCustomTransform: hasExplicitCustomTransform,
            snippetExpansionOccurred: snippetExpansionOccurred,
            hadExplicitTrailingNewline: hadExplicitTrailingNewline
        )
    }

    static func discardUnloggedAudio(audioPath: String?, shouldLog: Bool) {
        guard !shouldLog, let audioPath else { return }
        try? FileManager.default.removeItem(atPath: audioPath)
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
