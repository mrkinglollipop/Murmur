import AVFoundation
import Foundation
import os.log
import WhisperKit

// MARK: - WhisperKit ASR Engine

/// On-device speech recognition using WhisperKit (argmaxinc/WhisperKit, MIT licence).
///
/// MODEL: parameterized via `modelID` (a WhisperKit model repo identifier,
/// e.g. "openai_whisper-large-v3-turbo") so the same engine class backs every
/// Whisper option in the Local model picker.
///
/// DOWNLOAD OWNERSHIP: model *acquisition* belongs to `ModelManager`, not
/// this engine — `ModelManager.download(_:)` is the only path that triggers
/// a network fetch, with progress + failure recovery surfaced in Settings.
/// This engine loads directly from `ModelManager.modelFolderURL(for:)` with
/// `download: false`, so if the model isn't present yet it throws instead of
/// silently kicking off an untracked multi-GB download — the exact bug this
/// slice fixes (previously `WhisperKit(model:)` would implicitly download on
/// first transcription with no progress and no recovery).
///
/// One `WhisperKitEngine` instance is bound to exactly one `modelID` for its
/// lifetime — switching models means constructing a NEW instance (see
/// `ASREngineSelector`'s per-model-ID cache keying), not mutating this one.
final class WhisperKitEngine: ASREngine {

    let id: String
    let displayName: String

    /// The WhisperKit model repo identifier this instance loads (e.g.
    /// "openai_whisper-large-v3-turbo"). Fixed at init — never changes.
    private let modelID: String

    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "whisperkit")

    /// The `LocalModel` case this engine backs — used to resolve the
    /// already-downloaded model folder via `ModelManager`.
    private let localModel: LocalModel

    /// ISO 639-1 language code passed to WhisperKit decoding options.
    var language: String

    private let transcribeAudio: (@Sendable (URL, String) async throws -> String)?
    private let deadline: LocalTranscriptionDeadline.Runner

    init(
        modelID: String, displayName: String, localModel: LocalModel, language: String = "en",
        transcribeAudio: (@Sendable (URL, String) async throws -> String)? = nil,
        deadline: @escaping LocalTranscriptionDeadline.Runner = LocalTranscriptionDeadline.run
    ) {
        self.modelID = modelID
        self.id = "whisperKit:\(modelID)"
        self.displayName = displayName
        self.localModel = localModel
        self.language = language
        self.transcribeAudio = transcribeAudio
        self.deadline = deadline
    }

    // WhisperKit instance — lazily initialised on first transcription.
    // We keep it alive to avoid reload cost on every recording.
    private var whisper: WhisperKit?
    private let loadLock = NSLock()

    // In-flight model load, so two near-simultaneous transcription calls
    // can't race a double CoreML load — the second caller awaits the same
    // task instead of kicking off its own `WhisperKit(model:)` init.
    private var loadTask: Task<WhisperKit, Error>?

    // MARK: - ASREngine

    /// Ceiling on the model-load phase of a transcription. A cold large-v3-turbo
    /// load measures seconds, not minutes; a load that blows past this is parked
    /// (observed 2026-08-09: a cloud→local fallback whose load never returned —
    /// no error, no thread, model resident — leaving the dictation hung forever).
    /// Timing out turns that into a visible failure with the audio retained for
    /// retry. Decode has a separate budget scaled to the recording's duration.
    static let modelLoadTimeout: TimeInterval = 120

    /// Races `operation` against a deadline. On timeout cancellation is requested
    /// and `timeoutError()` is thrown; an uncancellable operation may linger in
    /// the abandoned task, which is acceptable — the caller's path unblocks and
    /// a late completion just leaves the engine warm for the next attempt.
    static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval,
        timeoutError: @escaping @Sendable () -> Error,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await AsyncDeadline.run(
            seconds: seconds,
            timeoutError: timeoutError,
            operation: operation
        )
    }

    func transcribe(audioURL: URL) async throws -> String {
        let decode = try await prepareDecode(audioURL: audioURL)
        let inferStart = Date()
        let audioFile = try AVAudioFile(forReading: audioURL)
        let text = try await deadline(
            LocalTranscriptionDeadline.seconds(for: audioFile),
            displayName,
            decode
        )
        vlog("inference \(String(format: "%.2f", Date().timeIntervalSince(inferStart)))s")

        return WhisperKitEngine.stripSoundAnnotations(text)
    }

    private func prepareDecode(audioURL: URL) async throws -> LocalTranscriptionDeadline.Operation {
        if let transcribeAudio {
            let language = language
            return { try await transcribeAudio(audioURL, language) }
        }

        loadLock.lock()
        let wasWarm = whisper != nil
        loadLock.unlock()
        let loadStart = Date()
        vlog(wasWarm ? "whisperkit: model warm" : "whisperkit: cold load starting (\(modelID))")
        let wk = try await Self.withDeadline(
            Self.modelLoadTimeout,
            timeoutError: { [displayName] in
                WhisperKitEngineError.modelLoadTimedOut(displayName, Self.modelLoadTimeout)
            },
            operation: { [self] in try await loadModelIfNeeded() }
        )
        vlog(wasWarm ? "whisperkit: using warm model" : "whisperkit: cold-loaded in \(String(format: "%.2f", Date().timeIntervalSince(loadStart)))s")

        // Decoding options tuned to reject non-speech: suppressBlank drops
        // leading blank tokens; the default no-speech / log-prob / compression
        // thresholds stay in force. skipSpecialTokens keeps control tokens out.
        var options = DecodingOptions(task: .transcribe, language: language)
        options.withoutTimestamps = true
        options.skipSpecialTokens = true
        options.suppressBlank = true

        let decodeOptions = options
        return {
            let results = try await wk.transcribe(audioPath: audioURL.path, decodeOptions: decodeOptions)
            return results
                .compactMap { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
        }
    }

    /// Caption removal must not delete arbitrary brackets or Markdown emphasis:
    /// those can contain real words, identifiers, and dictated code.
    static func stripSoundAnnotations(_ text: String) -> String {
        NonSpeechAnnotations.stripRecognizedTags(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Eagerly loads the CoreML model so the first real transcription doesn't
    /// pay the cold-load cost (measured ~3s for large-v3-turbo). Fire-and-forget;
    /// safe to call repeatedly — `loadModelIfNeeded` caches and serializes.
    func prewarm() async {
        let start = Date()
        do {
            _ = try await loadModelIfNeeded()
            vlog("prewarm complete in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        } catch {
            logger.error("Prewarm failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Streaming

    /// Builds a live `AudioStreamTranscriber` bound to THIS engine's already-
    /// loaded `WhisperKit` instance (its own `audioEncoder`/`featureExtractor`/
    /// `segmentSeeker`/`textDecoder`/`tokenizer` and — critically — its own
    /// `audioProcessor`). `AudioStreamTranscriber.startStreamTranscription()`
    /// owns mic capture itself (calls `audioProcessor.startRecordingLive`
    /// internally), so the returned transcriber becomes the SOLE mic owner
    /// for the duration of a streaming session — callers must not also run
    /// `AudioRecorder`'s own tap concurrently.
    ///
    /// Requires the model to already be loaded (call `loadModelIfNeeded()`/
    /// `prewarm()` first) — throws `WhisperKitEngineError.noModelFolder` via
    /// the same load path otherwise.
    func makeStreamTranscriber(
        stateChangeCallback: @escaping AudioStreamTranscriberCallback
    ) async throws -> AudioStreamTranscriber {
        let wk = try await loadModelIfNeeded()
        guard let tokenizer = wk.tokenizer else {
            throw WhisperKitEngineError.noTokenizer
        }
        var decodingOptions = DecodingOptions(task: .transcribe, language: language, withoutTimestamps: true)
        // Strip Whisper's control tokens (<|startoftranscript|>, <|en|>, …) from
        // the decoded output — without this they leak into segment text on the
        // streaming path (WhisperKit defaults skipSpecialTokens to false).
        decodingOptions.skipSpecialTokens = true
        return AudioStreamTranscriber(
            audioEncoder: wk.audioEncoder,
            featureExtractor: wk.featureExtractor,
            segmentSeeker: wk.segmentSeeker,
            textDecoder: wk.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: wk.audioProcessor,
            decodingOptions: decodingOptions,
            stateChangeCallback: stateChangeCallback
        )
    }

    // MARK: - Private

    private func loadModelIfNeeded() async throws -> WhisperKit {
        loadLock.lock()
        if let existing = whisper {
            loadLock.unlock()
            return existing
        }

        // A load is already in flight — await its result instead of
        // starting a second concurrent CoreML load.
        if let existingTask = loadTask {
            loadLock.unlock()
            return try await existingTask.value
        }

        guard let folder = ModelManager.modelFolderURL(for: localModel) else {
            loadLock.unlock()
            throw WhisperKitEngineError.noModelFolder(localModel.rawValue)
        }

        logger.info("WhisperKit: loading model '\(self.modelID)' from \(folder.path, privacy: .public)…")
        vlog("whisperkit: WhisperKit(config) init begin (\(modelID))")

        let modelID = self.modelID
        let task = Task<WhisperKit, Error> {
            // Load from the already-downloaded folder explicitly, with
            // `download: false` — acquisition is ModelManager's job (see
            // type doc). If the folder is missing/incomplete this throws
            // rather than silently starting an untracked download.
            let config = WhisperKitConfig(
                model: modelID,
                modelFolder: folder.path,
                download: false
            )
            return try await WhisperKit(config)
        }
        loadTask = task
        loadLock.unlock()

        do {
            let wk = try await task.value
            loadLock.lock()
            whisper = wk
            loadTask = nil
            loadLock.unlock()
            logger.info("WhisperKit: model ready.")
            vlog("whisperkit: WhisperKit(config) init returned")
            return wk
        } catch {
            loadLock.lock()
            loadTask = nil
            loadLock.unlock()
            vlog("whisperkit: WhisperKit(config) init threw: \(error.localizedDescription)")
            throw error
        }
    }
}

enum WhisperKitEngineError: Error, LocalizedError {
    case noModelFolder(String)
    case noTokenizer
    case modelLoadTimedOut(String, TimeInterval)

    var errorDescription: String? {
        switch self {
        case .noModelFolder(let model):
            return "Model '\(model)' is not downloaded yet. Download it from Settings → Local Model."
        case .noTokenizer:
            return "WhisperKit model loaded without a tokenizer — cannot start streaming transcription."
        case .modelLoadTimedOut(let model, let seconds):
            return "\(model) did not finish loading within \(Int(seconds))s. The recording is kept — retry from History."
        }
    }
}
