import Foundation
import ServiceManagement
#if canImport(FoundationModels)
import FoundationModels
#endif

/// User-facing setting values, mirroring the underlying enums used by
/// `ActivationController` and `ASREngineSelector`.
enum ActivationKeyOption: String, CaseIterable, Identifiable {
    case fnGlobe = "fnGlobe"
    case rightOption = "rightOption"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fnGlobe: return "fn / Globe"
        case .rightOption: return "Right Option"
        }
    }

    /// Short label shown in the recording HUD key chip.
    var hudLabel: String {
        switch self {
        case .fnGlobe: return "fn"
        case .rightOption: return "⌥"
        }
    }

    var activationKey: ActivationKey {
        switch self {
        case .fnGlobe: return .fnGlobe
        case .rightOption: return .rightOption
        }
    }

    static func from(_ key: ActivationKey) -> ActivationKeyOption {
        switch key {
        case .fnGlobe: return .fnGlobe
        case .rightOption: return .rightOption
        }
    }
}

/// Persists user settings to UserDefaults and applies them live to the
/// running `ActivationController` / `ASREngineSelector` instances owned by
/// the app.
///
/// `@MainActor`-isolated: it's constructed on main (`AppDelegate`) and
/// mutated only via SwiftUI bindings (main thread), and it now needs to call
/// the `@MainActor`-isolated `ModelManager` synchronously from `didSet`.
@MainActor
final class SettingsStore: ObservableObject {

    private enum Keys {
        static let activationKey = "voice.settings.activationKey"
        static let selectedLocalModel = "voice.settings.selectedLocalModel"
        static let selectedCloudModel = "voice.settings.selectedCloudModel"
        static let useCloudEngine = "voice.settings.useCloudEngine"
        static let cleanupEnabled = "voice.settings.cleanupEnabled"
        static let cleanupBackend = "voice.settings.cleanupBackend"
        static let codeAwareMode = "voice.settings.codeAwareMode"
        static let launchAtLogin = "voice.settings.launchAtLogin"
        static let playDictationSound = "voice.settings.playDictationSound"
        static let useStreaming = "voice.settings.useStreaming"
        static let removeFillerWords = "voice.settings.removeFillerWords"
        static let useToggleLock = "voice.settings.useToggleLock"
        static let smartLeadingSpace = "voice.settings.smartLeadingSpace"
        static let selectedLanguage = "voice.settings.selectedLanguage"
        static let speakerGatingEnabled = "voice.settings.speakerGatingEnabled"
        static let speakerGatingSensitivity = "voice.settings.speakerGatingSensitivity"
        static let recordingBudgetMB = "voice.settings.recordingBudgetMB"
    }

    /// Size-budget choices for retained dictation audio (P3 Storage UI).
    static let recordingBudgetOptionsMB: [Int] = [50, 100, 200, 500, 1000]

    /// Common ISO 639-1 codes surfaced in Settings.
    static let supportedLanguages: [(code: String, name: String)] = [
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh", "Chinese"),
        ("ru", "Russian"),
        ("ar", "Arabic"),
        ("hi", "Hindi"),
    ]

    /// Keychain-backed storage for user-supplied cloud API keys. Not
    /// persisted to UserDefaults — only the boolean toggle and model choice
    /// are; per-provider key presence is queried live via `hasAPIKey(for:)`.
    private let keychain = KeychainStore()

    @Published var activationKeyOption: ActivationKeyOption {
        didSet {
            UserDefaults.standard.set(activationKeyOption.rawValue, forKey: Keys.activationKey)
            applyActivationKey()
        }
    }

    /// The active LOCAL model — this is always what actually runs
    /// transcription. Persisted + applied to the live `ASREngineSelector` on
    /// change and on launch.
    @Published var selectedLocalModel: LocalModel {
        didSet {
            UserDefaults.standard.set(selectedLocalModel.rawValue, forKey: Keys.selectedLocalModel)
            applyLocalModel()
            ensureSelectedModelDownloaded()
        }
    }

    /// Which cloud model is selected when cloud mode is active. Persisted
    /// regardless of `useCloudEngine` so the choice survives toggling back
    /// and forth.
    @Published var selectedCloudModel: CloudModel {
        didSet {
            UserDefaults.standard.set(selectedCloudModel.rawValue, forKey: Keys.selectedCloudModel)
            applyCloudSettings()
        }
    }

    /// Local/Cloud engine toggle. `false` (default) keeps transcription on
    /// the local WhisperKit/Parakeet path; `true` routes through
    /// `selectedCloudModel`'s provider (falling back to local if no API key
    /// is stored for it — see `ASREngineSelector.transcribeAndLog`).
    @Published var useCloudEngine: Bool {
        didSet {
            UserDefaults.standard.set(useCloudEngine, forKey: Keys.useCloudEngine)
            applyCloudSettings()
        }
    }

    /// Master on/off for the AI cleanup pass (grammar/punctuation/filler-word
    /// removal). Defaults to OFF (2026-07-03: streaming WhisperKit output is
    /// already clean, and cleanup was a serial ~1.6s pass on the fast path —
    /// now opt-in via the Settings toggle rather than on by default).
    @Published var cleanupEnabled: Bool {
        didSet {
            UserDefaults.standard.set(cleanupEnabled, forKey: Keys.cleanupEnabled)
            applyCleanupSettings()
        }
    }

    /// Which backend runs cleanup — on-device (default) or cloud (BYO key).
    @Published var cleanupBackend: CleanupBackend {
        didSet {
            UserDefaults.standard.set(cleanupBackend.rawValue, forKey: Keys.cleanupBackend)
            applyCleanupSettings()
        }
    }

    /// Code-aware cleanup prompt variant — preserves identifiers/symbols and
    /// honors spoken punctuation, for programmers dictating code.
    @Published var codeAwareMode: Bool {
        didSet {
            UserDefaults.standard.set(codeAwareMode, forKey: Keys.codeAwareMode)
            applyCleanupSettings()
        }
    }

    /// Registers/unregisters the app as a login item via `SMAppService`
    /// (macOS 13+ public API — no helper-app bundle needed). Defaults to off.
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            applyLaunchAtLogin()
        }
    }

    /// Plays a short system sound at dictation start/stop when on. Playback is
    /// gated in `AudioRecorder` via `playDictationSoundProvider`.
    @Published var playDictationSound: Bool {
        didSet {
            UserDefaults.standard.set(playDictationSound, forKey: Keys.playDictationSound)
        }
    }

    /// When on (default), the xAI Grok cloud path transcribes live over a
    /// WebSocket DURING the key-hold, so text is ready almost instantly at
    /// release instead of after a post-release batch pass. Only the xAI
    /// provider exposes a streaming socket — every other cloud provider (and
    /// the local engines) ignore this flag and use their batch/file path.
    /// Exposed as a toggle so streaming can be A/B'd against the batch path.
    @Published var useStreaming: Bool {
        didSet {
            UserDefaults.standard.set(useStreaming, forKey: Keys.useStreaming)
            applyCloudSettings()
        }
    }

    /// When on, the ElevenLabs Scribe RT socket is asked to strip filler
    /// words and disfluencies server-side (`no_verbatim`) — the same polish
    /// the cleanup LLM round-trip does today, but free and at transcription
    /// time (plan 014). Defaults **true** at the operator's explicit request
    /// (2026-07-09) rather than the plan's original opt-in default — see the
    /// "Why `no_verbatim` defaults ON" maintenance note in
    /// `plans/014-elevenlabs-native-polish.md` for the spoken-correction risk
    /// this accepts (disfluency-shaped speech like "um, actually, no —" used
    /// as a deliberate correction could be swallowed). Only the ElevenLabs
    /// provider reads this; shown in Settings only when it's selected.
    @Published var removeFillerWords: Bool {
        didSet {
            UserDefaults.standard.set(removeFillerWords, forKey: Keys.removeFillerWords)
            applyCloudSettings()
        }
    }

    /// When enabled, double-tap fn within 400ms toggles locked recording mode
    /// (recording continues after release until tapped again).
    @Published var useToggleLock: Bool {
        didSet {
            UserDefaults.standard.set(useToggleLock, forKey: Keys.useToggleLock)
        }
    }

    /// Prepends a leading space before injection when caret context warrants it,
    /// so dictated text doesn't glue to the character before the caret.
    @Published var smartLeadingSpace: Bool {
        didSet {
            UserDefaults.standard.set(smartLeadingSpace, forKey: Keys.smartLeadingSpace)
            applyCleanupSettings()
        }
    }

    /// ISO 639-1 language code for ASR backends (default `"en"`).
    @Published var selectedLanguage: String {
        didSet {
            UserDefaults.standard.set(selectedLanguage, forKey: Keys.selectedLanguage)
            applyLanguage()
        }
    }

    /// When on, attenuates audio that doesn't match the enrolled speaker
    /// profile before transcription. Requires a stored profile (session B UI).
    @Published var speakerGatingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(speakerGatingEnabled, forKey: Keys.speakerGatingEnabled)
            applySpeakerGatingSettings()
        }
    }

    /// Cosine-similarity threshold band for speaker gating (session B UI).
    @Published var speakerGatingSensitivity: VoiceGateSensitivity {
        didSet {
            UserDefaults.standard.set(speakerGatingSensitivity.rawValue, forKey: Keys.speakerGatingSensitivity)
            applySpeakerGatingSettings()
        }
    }

    /// Cached voice-profile load for Settings UI. Disk writes during enrollment
    /// are not observable; publish an explicit refresh so the Focus toggle and
    /// Enroll CTA update without requiring an app relaunch.
    @Published private(set) var enrolledVoiceProfile: VoiceProfile?

    /// Ephemeral speaker-gate telemetry for the most recent recording session.
    @Published private(set) var voiceGateTelemetry: VoiceGateTelemetrySnapshot = .empty

    /// Max megabytes of retained dictation audio under Application Support.
    /// Oldest unprotected files are pruned when the budget is exceeded.
    @Published var recordingBudgetMB: Int {
        didSet {
            guard !isHydrating else { return }
            let clamped = Self.clampBudgetMB(recordingBudgetMB)
            if clamped != recordingBudgetMB {
                recordingBudgetMB = clamped
                return
            }
            UserDefaults.standard.set(recordingBudgetMB, forKey: Keys.recordingBudgetMB)
            applyRecordingBudget()
        }
    }

    /// Live usage stats for the Storage section (refreshed on appear / after prune/export).
    @Published private(set) var recordingUsageBytes: Int64 = 0
    @Published private(set) var recordingFileCount: Int = 0

    /// Weak references to the live app components so setting changes apply
    /// immediately without relaunch. Wired in by `AppDelegate` after both
    /// objects exist.
    weak var activationController: ActivationController?
    weak var asrEngineSelector: ASREngineSelector?
    weak var audioRecorder: AudioRecorder? {
        didSet { wireVoiceGateTelemetryPublisher() }
    }

    /// Optional history store for prune protect-list + export transcripts.
    weak var historyStore: HistoryStore?

    /// Owns per-model download/storage state (see `ModelManager`). Wired in
    /// by `AppDelegate` alongside the other live components; also exposed to
    /// `SettingsView` so its management list can observe progress directly.
    var modelManager: ModelManager?

    /// Suppresses side-effecting didSets while hydrating from UserDefaults so
    /// init cannot prune with a nil `historyStore` (empty protect list).
    private var isHydrating = true

    init() {
        let defaults = UserDefaults.standard

        if let raw = defaults.string(forKey: Keys.activationKey),
           let option = ActivationKeyOption(rawValue: raw) {
            activationKeyOption = option
        } else {
            activationKeyOption = .fnGlobe
        }

        if let raw = defaults.string(forKey: Keys.selectedLocalModel),
           let model = LocalModel(rawValue: raw) {
            selectedLocalModel = model
        } else {
            selectedLocalModel = .default
        }

        // A previously-stored (or the static `.default`) selection may point
        // at a model that's since been retired from the picker (plan 013 —
        // AssemblyAI/Deepgram/Groq/OpenAI stay compiled as scaffolding but
        // are no longer offered). Presenting or using a hidden model would
        // be worse than falling back, so correct it to xAI and persist that
        // correction immediately.
        let storedCloudModel: CloudModel
        if let raw = defaults.string(forKey: Keys.selectedCloudModel),
           let model = CloudModel(rawValue: raw) {
            storedCloudModel = model
        } else {
            storedCloudModel = .default
        }
        let resolvedCloudModel = CloudModel.selectableOrFallback(storedCloudModel)
        selectedCloudModel = resolvedCloudModel
        if resolvedCloudModel != storedCloudModel {
            defaults.set(resolvedCloudModel.rawValue, forKey: Keys.selectedCloudModel)
        }

        useCloudEngine = defaults.bool(forKey: Keys.useCloudEngine)

        if defaults.object(forKey: Keys.cleanupEnabled) != nil {
            cleanupEnabled = defaults.bool(forKey: Keys.cleanupEnabled)
        } else {
            cleanupEnabled = false
        }

        if let raw = defaults.string(forKey: Keys.cleanupBackend),
           let backend = CleanupBackend(rawValue: raw) {
            cleanupBackend = backend
        } else {
            cleanupBackend = .onDevice
        }

        codeAwareMode = defaults.bool(forKey: Keys.codeAwareMode)

        // Reflect the actual SMAppService registration status rather than
        // trusting the persisted flag blindly — the user (or macOS) may have
        // toggled this outside the app via System Settings → Login Items.
        launchAtLogin = SMAppService.mainApp.status == .enabled

        if defaults.object(forKey: Keys.playDictationSound) != nil {
            playDictationSound = defaults.bool(forKey: Keys.playDictationSound)
        } else {
            playDictationSound = false
        }

        if defaults.object(forKey: Keys.useStreaming) != nil {
            useStreaming = defaults.bool(forKey: Keys.useStreaming)
        } else {
            useStreaming = true
        }

        if defaults.object(forKey: Keys.removeFillerWords) != nil {
            removeFillerWords = defaults.bool(forKey: Keys.removeFillerWords)
        } else {
            removeFillerWords = true
        }

        useToggleLock = defaults.bool(forKey: Keys.useToggleLock)

        if defaults.object(forKey: Keys.smartLeadingSpace) != nil {
            smartLeadingSpace = defaults.bool(forKey: Keys.smartLeadingSpace)
        } else {
            smartLeadingSpace = true
        }

        if let lang = defaults.string(forKey: Keys.selectedLanguage), !lang.isEmpty {
            selectedLanguage = lang
        } else {
            selectedLanguage = "en"
        }

        speakerGatingEnabled = defaults.bool(forKey: Keys.speakerGatingEnabled)

        if let raw = defaults.string(forKey: Keys.speakerGatingSensitivity),
           let sensitivity = VoiceGateSensitivity(rawValue: raw) {
            speakerGatingSensitivity = sensitivity
        } else {
            speakerGatingSensitivity = .medium
        }

        enrolledVoiceProfile = VoiceProfileStore().load()

        if defaults.object(forKey: Keys.recordingBudgetMB) != nil {
            recordingBudgetMB = Self.clampBudgetMB(defaults.integer(forKey: Keys.recordingBudgetMB))
        } else {
            recordingBudgetMB = RecordingRetention.defaultBudgetMB
        }

        refreshRecordingUsage()
        isHydrating = false
    }

    /// Call once after `activationController` / `asrEngineSelector` are set,
    /// to push the persisted settings onto the freshly-constructed live
    /// objects (they otherwise start with their own hardcoded defaults).
    func applyOnLaunch() {
        applyActivationKey(restartTap: false)
        applyLocalModel()
        ensureSelectedModelDownloaded()
        applyCloudSettings()
        applyCleanupSettings()
        applyLanguage()
        refreshEnrolledVoiceProfile(autoEnableGatingIfPresent: false)
        applySpeakerGatingSettings()
        applyRecordingBudget()
        refreshRecordingUsage()
    }

    /// Bytes currently allowed for retained recordings.
    var recordingBudgetBytes: Int64 {
        Int64(recordingBudgetMB) * 1024 * 1024
    }

    static func clampBudgetMB(_ value: Int) -> Int {
        if recordingBudgetOptionsMB.contains(value) { return value }
        // Nearest option for any hand-edited defaults value.
        return recordingBudgetOptionsMB.min(by: { abs($0 - value) < abs($1 - value) })
            ?? RecordingRetention.defaultBudgetMB
    }

    func refreshRecordingUsage() {
        recordingUsageBytes = RecordingRetention.usageBytes()
        recordingFileCount = RecordingRetention.fileCount()
    }

    func applyRecordingBudget() {
        let keep = historyStore?.protectedAudioPaths() ?? []
        RecordingRetention.pruneNow(
            keepPaths: keep,
            maxCount: RecordingRetention.maxRetained,
            maxBytes: recordingBudgetBytes
        )
        historyStore?.clearMissingAudioPaths()
        refreshRecordingUsage()
    }

    /// Re-read `voice-profile.json`. When `autoEnableGatingIfPresent` is true
    /// and a profile exists, turn Focus on my voice on so a finished enrollment
    /// is immediately usable (toggle used to stay disabled until relaunch).
    func refreshEnrolledVoiceProfile(autoEnableGatingIfPresent: Bool) {
        let profile = VoiceProfileStore().load()
        enrolledVoiceProfile = profile
        guard autoEnableGatingIfPresent, profile != nil else {
            applySpeakerGatingSettings()
            return
        }
        if !speakerGatingEnabled {
            speakerGatingEnabled = true
        } else {
            applySpeakerGatingSettings()
        }
    }

    func clearEnrolledVoiceProfile() {
        enrolledVoiceProfile = nil
        if speakerGatingEnabled {
            speakerGatingEnabled = false
        }
    }

    /// The local model is always kept current on the selector — it's the
    /// active engine when cloud mode is off, and the fallback engine when
    /// cloud mode is on but no key is available.
    private func applyLocalModel() {
        asrEngineSelector?.selectedModel = selectedLocalModel
    }

    /// Pushes the cloud engine choice + Keychain lookup closure onto the
    /// live `ASREngineSelector`. `cloudModel` is nil when `useCloudEngine` is
    /// false, which keeps the selector on its local-only path.
    private func applyCloudSettings() {
        guard let asrEngineSelector else { return }
        asrEngineSelector.cloudModel = useCloudEngine ? selectedCloudModel : nil
        asrEngineSelector.apiKeyProvider = { [keychain] provider in
            keychain.key(for: provider.keychainAccount)
        }
        asrEngineSelector.xaiStreamingEnabled = useStreaming
        asrEngineSelector.removeFillerWordsEnabled = removeFillerWords
    }

    /// Pushes the cleanup toggle, code-aware flag, and a freshly-built
    /// cleanup service onto the live `ASREngineSelector`. Rebuilding the
    /// service on every settings change is cheap (both backends are
    /// stateless constructions) and keeps it in sync with backend/key
    /// changes without extra invalidation bookkeeping.
    private func applyCleanupSettings() {
        guard let asrEngineSelector else { return }
        asrEngineSelector.cleanupEnabled = cleanupEnabled
        asrEngineSelector.codeAware = codeAwareMode
        asrEngineSelector.smartLeadingSpaceEnabled = smartLeadingSpace
        asrEngineSelector.cleanupService = CleanupFactory.service(
            backend: cleanupBackend,
            openAIKey: keychain.key(for: Self.cleanupKeyAccount),
            xaiKey: keychain.key(for: CloudProvider.xai.keychainAccount)
        )
    }

    private func applyLanguage() {
        asrEngineSelector?.selectedLanguage = selectedLanguage
    }

    private func applySpeakerGatingSettings() {
        audioRecorder?.updateSpeakerGating(
            enabled: speakerGatingEnabled,
            sensitivity: speakerGatingSensitivity
        )
    }

    private func wireVoiceGateTelemetryPublisher() {
        audioRecorder?.voiceGateTelemetryPublisher = { [weak self] snapshot in
            self?.voiceGateTelemetry = snapshot
        }
    }

    /// Formats retained-audio usage for the Storage UI.
    static func formatByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    /// Keychain account the cleanup cloud (OpenAI) key is stored under —
    /// distinct from the cloud-ASR provider accounts in `CloudProvider`.
    private static let cleanupKeyAccount = "cleanup-openai"

    /// Saves the cleanup cloud API key and republishes cleanup settings so a
    /// live cloud-backend session picks it up immediately.
    /// Returns `false` if the Keychain write failed (input should stay in UI).
    @discardableResult
    func saveCleanupKey(_ value: String) -> Bool {
        guard keychain.setKey(value, for: Self.cleanupKeyAccount) else { return false }
        applyCleanupSettings()
        objectWillChange.send()
        return true
    }

    /// Removes the stored cleanup cloud API key.
    func removeCleanupKey() {
        keychain.deleteKey(for: Self.cleanupKeyAccount)
        applyCleanupSettings()
        objectWillChange.send()
    }

    /// Whether a non-empty cleanup cloud API key is currently stored.
    func hasCleanupKey() -> Bool {
        guard let key = keychain.key(for: Self.cleanupKeyAccount) else { return false }
        return !key.isEmpty
    }

    /// The raw cleanup cloud API key, if any — used by `TransformRunner` via
    /// `AppDelegate`'s `openAIKeyProvider`, which reuses cleanup's Keychain
    /// account rather than a separate one (a Transform run shares cleanup's
    /// backend-selection logic).
    func cleanupKeyValue() -> String? {
        keychain.key(for: Self.cleanupKeyAccount)
    }

    /// Whether the on-device cleanup model is currently usable on this
    /// machine (macOS 26+ with Apple Intelligence enabled/downloaded). The
    /// View uses this to warn when On-device is selected but unavailable.
    var onDeviceCleanupAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        } else {
            return false
        }
        #else
        return false
        #endif
    }

    /// Whether the xAI Keychain key (shared with xAI transcription) is
    /// currently stored — the View uses this to warn when Grok cleanup is
    /// selected but no key has been entered yet (in the Cloud Model section).
    func hasXAIKey() -> Bool {
        guard let key = keychain.key(for: CloudProvider.xai.keychainAccount) else { return false }
        return !key.isEmpty
    }

    // MARK: - API key management (Keychain-backed)

    /// Saves `value` as the API key for `provider` and republishes cloud
    /// settings so a live `useCloudEngine` session picks it up immediately.
    /// Returns `false` if the Keychain write failed (input should stay in UI).
    @discardableResult
    func saveAPIKey(_ value: String, for provider: CloudProvider) -> Bool {
        guard keychain.setKey(value, for: provider.keychainAccount) else { return false }
        applyCloudSettings()
        if provider == .xai {
            applyCleanupSettings()
        }
        objectWillChange.send()
        return true
    }

    /// Removes the stored API key for `provider`.
    func removeAPIKey(for provider: CloudProvider) {
        keychain.deleteKey(for: provider.keychainAccount)
        applyCloudSettings()
        if provider == .xai {
            applyCleanupSettings()
        }
        objectWillChange.send()
    }

    /// Whether a non-empty API key is currently stored for `provider`.
    func hasAPIKey(for provider: CloudProvider) -> Bool {
        guard let key = keychain.key(for: provider.keychainAccount) else { return false }
        return !key.isEmpty
    }

    /// Kicks off a download for the currently-selected local model if it
    /// isn't present on disk yet — this is the selection→download wiring:
    /// picking a model in Settings (or launching with one already selected)
    /// triggers acquisition through `ModelManager` (progress + failure
    /// recovery), rather than the old behavior of silently downloading on
    /// first transcription. No-op for the Parakeet sidecar model and for
    /// models already downloaded.
    private func ensureSelectedModelDownloaded() {
        guard let modelManager else { return }
        modelManager.downloadIfNeeded(selectedLocalModel)
    }

    /// Registers/unregisters `SMAppService.mainApp` to match `launchAtLogin`.
    /// Both calls can throw (e.g. no Info.plist login-item entry, or the user
    /// denies it in System Settings) — failures are logged and the published
    /// flag is reverted to the actual post-attempt status rather than lying
    /// about what happened.
    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            vlog("SMAppService.mainApp register/unregister failed: \(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    /// Applies the activation key to the live `ActivationController`. When
    /// `restartTap` is true (default — a live setting change) the tap is
    /// stopped and restarted so the change takes effect immediately without
    /// relaunching the app.
    private func applyActivationKey(restartTap: Bool = true) {
        guard let controller = activationController else { return }
        controller.activationKey = activationKeyOption.activationKey
        if restartTap {
            controller.stop()
            controller.start()
        }
    }
}
