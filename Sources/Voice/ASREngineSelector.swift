import Foundation
import os.log

// MARK: - Engine Selection

/// The set of available ASR backends.
enum ASREngineID: String, CaseIterable {
    /// WhisperKit — on-device CoreML Whisper. Default.
    case whisperKit = "whisperKit"

    /// Parakeet — Python/MLX sidecar via `parakeet-mlx`.
    case parakeet   = "parakeet"
}

// MARK: - Selector

/// Builds and vends the currently-selected ASR engine.
///
/// The selection is held in memory for this session.  Persistence (UserDefaults /
/// Settings UI) is a later slice.
final class ASREngineSelector {

    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "asr-selector")

    /// Post-ASR pipeline (cleanup → correct → inject → history).
    let pipeline = TranscriptionPipeline()

    init() {
        pipeline.engineSelector = self
    }

    /// Currently active LOCAL model. Change this at runtime to switch models
    /// (and, implicitly, engines — Parakeet vs. one of the WhisperKit sizes).
    /// Still consulted as the fallback path when cloud mode is selected but
    /// no API key is available for the chosen provider.
    var selectedModel: LocalModel = .default

    /// Non-nil selects CLOUD transcription for the given model; `nil` (the
    /// default) keeps the app on the local engine path. Set by
    /// `SettingsStore` from the persisted Local/Cloud toggle.
    var cloudModel: CloudModel?

    /// Resolves the stored API key for a given cloud provider. Wired by
    /// `SettingsStore` to `KeychainStore.key(for:)`. If this returns nil or
    /// empty for the selected provider, `transcribeAndLog` falls back to the
    /// local engine rather than failing the dictation.
    var apiKeyProvider: ((CloudProvider) -> String?)?

    /// OpenAI key for transform auto-run and other LLM paths that reuse the
    /// cleanup Keychain account. Wired by `AppDelegate` to
    /// `SettingsStore.cleanupKeyValue()`.
    var openAIKeyProvider: (() -> String?)?

    /// BCP-47 language code for cloud/local ASR (e.g. `"en"`). Pushed by
    /// `SettingsStore.applyLanguage()`.
    var selectedLanguage: String = "en"

    /// When set, runs automatically after cleanup on each dictation. Pushed by
    /// `TransformsStore.pushAutoRunTransform()`.
    var autoRunTransform: Transform?

    /// Invoked on the main thread when a recording session begins — used to
    /// apply per-app style overrides before transcription.
    var onRecordingStart: (() -> Void)?

    /// Live partial transcript from xAI streaming, for HUD preview.
    var onInterimTranscript: ((String) -> Void)?

    /// Master on/off for the AI cleanup pass (grammar/punctuation/filler-word
    /// removal). Set by `SettingsStore` from the persisted toggle.
    var cleanupEnabled: Bool {
        get { pipeline.cleanupEnabled }
        set { pipeline.cleanupEnabled = newValue }
    }

    /// Whether cleanup should use the code-aware prompt variant (preserve
    /// identifiers/symbols, honor spoken punctuation). Set by `SettingsStore`.
    var codeAware: Bool {
        get { pipeline.codeAware }
        set { pipeline.codeAware = newValue }
    }

    /// Prepends a leading space before injection when caret context warrants it.
    /// Set by `SettingsStore` from the persisted toggle.
    var smartLeadingSpaceEnabled: Bool {
        get { pipeline.smartLeadingSpaceEnabled }
        set { pipeline.smartLeadingSpaceEnabled = newValue }
    }

    /// Master enable for the xAI Grok streaming path (see
    /// `makeXAIStreamingSession`). Set by `SettingsStore` from the persisted
    /// `useStreaming` toggle; when off, xAI falls back to the batch multipart
    /// POST like the other cloud providers.
    var xaiStreamingEnabled: Bool = true

    /// Master enable for the ElevenLabs Scribe v2 Realtime streaming path
    /// (see `makeElevenLabsStreamingSession`). ElevenLabs Scribe RT has no
    /// separate "off" toggle in Settings — it IS the provider's only wired
    /// transcription path, so this stays `true`; kept as a var (not a
    /// constant) for parity with `xaiStreamingEnabled` and to leave room for
    /// a future per-provider toggle without another switch-site change.
    var elevenLabsStreamingEnabled: Bool = true

    /// Sent as ElevenLabs' `no_verbatim` param (server-side filler-word /
    /// disfluency removal). Set by `SettingsStore` from the persisted
    /// `removeFillerWords` toggle; defaults `true` here to match that
    /// setting's default (operator request, 2026-07-09) in case a session
    /// ever constructs a stream before `SettingsStore.applyOnLaunch()` runs.
    var removeFillerWordsEnabled: Bool = true

    /// Resolves the current keyterms vocabulary (canonical dictionary terms,
    /// already selected/capped/de-duped) for the ElevenLabs `keyterms` param.
    /// Wired by `AppDelegate` to `ElevenLabsRealtimeTranscriber.selectKeyterms(from:)`
    /// over `DictionaryStore.entries`, mirroring how `apiKeyProvider` is wired.
    var keytermsProvider: (() -> [String])?

    /// Dictionary terms that start with an uppercase letter — used at inject
    /// time to keep proper-noun capitalization mid-sentence. Wired by
    /// `AppDelegate` from `DictionaryStore.entries`.
    var capitalizedDictionaryTermsProvider: (() -> Set<String>)?

    /// Capture caret AX snapshot on the main thread at recording-will-start.
    /// Returns the generation token for token-matched clear on failed start.
    @discardableResult
    func holdCaretSnapshotFromRecordingWillStart() -> UInt64 {
        pipeline.holdCaretSnapshotFromRecordingWillStart()
    }

    /// Clear held caret snapshot (abort / cancel / stop without inject).
    /// When `matching` is set, only clears if that session still owns the slot.
    func clearHeldCaretSnapshot(matching token: UInt64? = nil) {
        pipeline.clearHeldCaretSnapshot(matching: token)
    }

    /// Package-visible held state for lifecycle unit tests.
    var test_heldCaretToken: UInt64 { pipeline.test_heldCaretToken }
    var test_heldCaretSnapshot: CaretContext.Snapshot? { pipeline.test_heldCaretSnapshot }

    @discardableResult
    func test_holdSnapshot(_ snapshot: CaretContext.Snapshot) -> UInt64 {
        pipeline.test_holdSnapshot(snapshot)
    }

    /// Copy held snapshot + PID when `token` still owns the pipeline slot.
    /// Main-thread only — AudioRecorder samples at recording-stop.
    func copyHeldCaretMatching(_ token: UInt64) -> (CaretContext.Snapshot?, pid_t?) {
        pipeline.copyHeldCaretMatching(token)
    }

    /// The active Style profile's formality instruction, appended to the
    /// cleanup prompt when non-nil/non-empty. Only takes effect while cleanup
    /// is enabled (it's an instruction to the cleanup LLM, not a separate
    /// pass). Set by `SettingsStore` from `StyleStore.selected`, mirroring
    /// how `codeAware` is pushed.
    var styleInstruction: String? {
        get { pipeline.styleInstruction }
        set { pipeline.styleInstruction = newValue }
    }

    /// The active cleanup backend (on-device or cloud), or `nil` if cleanup
    /// can't run right now (backend unavailable / no key). Pushed by
    /// `SettingsStore.applyCleanupSettings()` via `CleanupFactory`.
    var cleanupService: TranscriptCleanupService? {
        get { pipeline.cleanupService }
        set { pipeline.cleanupService = newValue }
    }

    /// Cache of constructed engine instances, keyed by `LocalModel` (NOT just
    /// engine family) — this is the fix for stale-cache reuse: a WhisperKit
    /// instance is bound to one model ID for its lifetime (see
    /// `WhisperKitEngine`), so keying only by `ASREngineID` would silently
    /// keep serving the FIRST Whisper size ever selected regardless of which
    /// Whisper size the user picks afterward. Keying by the specific
    /// `LocalModel` case ensures a distinct engine instance (and distinct
    /// CoreML load) per model, while still reusing an instance if the user
    /// switches back to a model already loaded this session.
    private var engineCache: [LocalModel: any ASREngine] = [:]

    /// Optional dictionary-correction hook, applied to the raw transcript
    /// BEFORE injection and BEFORE history logging. Invoked on the main
    /// thread. Wired by AppDelegate to `DictionaryStore.correct(_:)`.
    /// Returns the (possibly unchanged) text.
    var onTranscription: ((String, String) -> (String, [CorrectionRecord]))? {
        get { pipeline.onTranscription }
        set { pipeline.onTranscription = newValue }
    }

    /// Invoked on the main thread when dictionary/phonetic corrections fire.
    var onCorrectionsRecorded: (([CorrectionRecord]) -> Void)? {
        get { pipeline.onCorrectionsRecorded }
        set { pipeline.onCorrectionsRecorded = newValue }
    }

    /// Optional snippet-expansion hook, applied to the dictionary-corrected
    /// transcript AFTER `onTranscription` and BEFORE injection/history
    /// logging, so both injection and History see the fully expanded text.
    /// Invoked on the main thread. Wired by AppDelegate to
    /// `SnippetsStore.expand(_:)`.
    var onSnippetExpand: ((String) -> String)? {
        get { pipeline.onSnippetExpand }
        set { pipeline.onSnippetExpand = newValue }
    }

    /// Optional history-logging hook, invoked on the main thread with the
    /// FINAL (already dictionary-corrected) text, the engine id, whether
    /// injection succeeded, optional audio path, whether transcription
    /// failed, and optional history entry ID to replace (retry). Wired by
    /// AppDelegate to `HistoryStore.append`.
    var onTranscriptionLogged: ((String, String, Bool, String?, Bool, UUID?) -> Void)? {
        get { pipeline.onTranscriptionLogged }
        set { pipeline.onTranscriptionLogged = newValue }
    }

    /// Confirmed insert delivered text — for inline correction watching.
    var onTextInserted: ((String) -> Void)? {
        get { pipeline.onTextInserted }
        set { pipeline.onTextInserted = newValue }
    }

    /// Optional failure hook for terminal errors (transcription, injection,
    /// audio capture). Invoked on the main thread. Wired by AppDelegate to
    /// the HUD error pill and menu-bar badge.
    var onFailure: ((DictationFailure) -> Void)? {
        get { pipeline.onFailure }
        set { pipeline.onFailure = newValue }
    }

    /// Path of the most recently retained recording in Application Support,
    /// set when a capture is retained for transcription / history retry.
    private(set) var lastRetainedRecordingURL: URL?

    func setLastRetainedRecordingURL(_ url: URL?) {
        lastRetainedRecordingURL = url
    }

    /// Returns a concrete engine instance for the current selection, reusing
    /// a cached instance when one already exists for that specific model.
    /// Refreshes WhisperKit language on cache hit so a Settings language
    /// change applies without rebuilding the CoreML engine.
    func makeEngine() -> any ASREngine {
        if let cached = engineCache[selectedModel] {
            if let wk = cached as? WhisperKitEngine {
                wk.language = selectedLanguage
            }
            return cached
        }
        let engine = buildEngine(for: selectedModel)
        engineCache[selectedModel] = engine
        return engine
    }

    /// Whether streaming transcription is eligible right now: local mode
    /// (not cloud — cloud providers don't expose a streaming path here) AND
    /// the selected local model is WhisperKit-backed (Parakeet has no
    /// streaming API in this codebase). Checked fresh on every recording
    /// start so a live Settings change (switching models/engines mid-session)
    /// is always respected.
    /// Master switch for the streaming path. Currently DISABLED: WhisperKit's
    /// `AudioStreamTranscriber` only decodes once ≥1s of NEW audio has accrued
    /// (`guard nextBufferSeconds > 1` in its `transcribeCurrentBuffer`), so it
    /// drops the final sub-second tail of a short push-to-talk utterance (the
    /// truncated-tail bug). Making it correct requires a full-buffer re-decode
    /// at release — the same cost as the file-based path — so for now the
    /// simpler, correct file-based path (with prewarm killing the cold load and
    /// cleanup off) is the primary. The streaming code is kept intact for a
    /// future revisit (e.g. showing live text during speech, where the dropped
    /// 1s tail matters less than it does for the final injected text).
    static let streamingEnabled = false

    var streamingEligible: Bool {
        Self.streamingEnabled && cloudModel == nil && selectedModel.engineID == .whisperKit
    }

    /// Returns the current selection's engine as a `WhisperKitEngine`, or
    /// `nil` if streaming isn't eligible (see `streamingEligible`). Reuses
    /// the same cached instance `makeEngine()`/`transcribeAndLog` use, so the
    /// model warm state (prewarm, loaded CoreML) is shared — no duplicate load.
    func makeWhisperKitEngineForStreaming() -> WhisperKitEngine? {
        guard streamingEligible else { return nil }
        return makeEngine() as? WhisperKitEngine
    }

    /// Builds an xAI Grok streaming session if — and only if — the streaming
    /// path is enabled AND the selected cloud model is xAI Grok STT AND a
    /// non-empty key is stored for it. Returns `nil` otherwise, in which case
    /// the caller uses its normal (WhisperKit-streaming or file-based) path,
    /// and xAI (if selected) transcribes via the batch multipart POST. Checked
    /// fresh on every recording start so a live Settings change is respected.
    func makeXAIStreamingSession() -> XAIStreamingTranscriber? {
        guard xaiStreamingEnabled,
              cloudModel == .xaiGrokSTT,
              let key = apiKeyProvider?(.xai),
              !key.isEmpty else { return nil }
        return XAIStreamingTranscriber(apiKey: key, language: selectedLanguage)
    }

    /// Builds an ElevenLabs Scribe v2 Realtime streaming session if — and
    /// only if — the selected cloud model is ElevenLabs Scribe RT AND a
    /// non-empty key is stored for it. Returns `nil` otherwise, in which case
    /// the caller uses the file-based path and (if ElevenLabs is selected)
    /// transcribes via the batch fallback. Mirrors `makeXAIStreamingSession`.
    func makeElevenLabsStreamingSession() -> ElevenLabsRealtimeTranscriber? {
        guard elevenLabsStreamingEnabled,
              cloudModel == .elevenLabsScribeV2Realtime,
              let key = apiKeyProvider?(.elevenLabs),
              !key.isEmpty else { return nil }
        return ElevenLabsRealtimeTranscriber(
            apiKey: key,
            language: selectedLanguage,
            noVerbatim: removeFillerWordsEnabled,
            keyterms: keytermsProvider?() ?? []
        )
    }

    /// Eagerly warms the selected LOCAL model in the background so the first
    /// dictation after launch isn't blocked on a cold CoreML load (~3s for
    /// large-v3-turbo). No-op in cloud mode (local isn't the active path) or
    /// for engines that don't need warming. Called once at launch by
    /// `AppDelegate` after settings are applied.
    func prewarmSelectedModelIfLocal() {
        guard cloudModel == nil else { return }
        let engine = makeEngine()
        if let wk = engine as? WhisperKitEngine {
            Task.detached(priority: .utility) { await wk.prewarm() }
        }
    }

    /// Constructs the concrete engine backing a given `LocalModel`. Every
    /// WhisperKit-backed case carries a non-nil `whisperKitModelID` (see
    /// `LocalModel`); the fallback to "openai_whisper-base" only guards
    /// against that invariant being violated in the future.
    private func buildEngine(for model: LocalModel) -> any ASREngine {
        switch model.engineID {
        case .whisperKit:
            let modelID = model.whisperKitModelID ?? {
                logger.error("LocalModel \(model.rawValue) has engineID .whisperKit but no whisperKitModelID — falling back to base model.")
                return "openai_whisper-base"
            }()
            return WhisperKitEngine(
                modelID: modelID,
                displayName: model.displayName,
                localModel: model,
                language: selectedLanguage
            )
        case .parakeet:
            return ParakeetEngine()
        }
    }

    /// Transcribes the audio file with the selected engine, applies dictionary
    /// correction, injects, and logs to history — the full pipeline for one
    /// completed dictation.
    func transcribeAndLog(
        audioURL: URL,
        replaceHistoryEntryID: UUID? = nil,
        sessionHeldToken: UInt64? = nil,
        sessionHeldSnapshot: CaretContext.Snapshot? = nil,
        sessionHeldFrontmostPID: pid_t? = nil,
        completion: ((TranscriptionPipeline.InjectPipelineResult) -> Void)? = nil
    ) {
        pipeline.transcribeAndLog(
            audioURL: audioURL,
            replaceHistoryEntryID: replaceHistoryEntryID,
            sessionHeldToken: sessionHeldToken,
            sessionHeldSnapshot: sessionHeldSnapshot,
            sessionHeldFrontmostPID: sessionHeldFrontmostPID,
            completion: completion
        )
    }

    /// Streaming entry point: takes text ALREADY produced by a live session.
    func logStreamedTranscription(
        text: String,
        engineID: String,
        sessionHeldToken: UInt64? = nil,
        sessionHeldSnapshot: CaretContext.Snapshot? = nil,
        sessionHeldFrontmostPID: pid_t? = nil,
        completion: ((TranscriptionPipeline.InjectPipelineResult) -> Void)? = nil
    ) {
        pipeline.logStreamedTranscription(
            text: text,
            engineID: engineID,
            sessionHeldToken: sessionHeldToken,
            sessionHeldSnapshot: sessionHeldSnapshot,
            sessionHeldFrontmostPID: sessionHeldFrontmostPID,
            completion: completion
        )
    }

    /// Forwarded for test compatibility — see `TranscriptionPipeline.cleanupLooksSane`.
    static func cleanupLooksSane(input: String, output: String) -> Bool {
        TranscriptionPipeline.cleanupLooksSane(input: input, output: output)
    }
}
