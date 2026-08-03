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

    init(modelID: String, displayName: String, localModel: LocalModel, language: String = "en") {
        self.modelID = modelID
        self.id = "whisperKit:\(modelID)"
        self.displayName = displayName
        self.localModel = localModel
        self.language = language
    }

    // WhisperKit instance — lazily initialised on first transcription.
    // We keep it alive to avoid reload cost on every recording.
    private var whisper: WhisperKit?

    // In-flight model load, so two near-simultaneous transcription calls
    // can't race a double CoreML load — the second caller awaits the same
    // task instead of kicking off its own `WhisperKit(model:)` init.
    private var loadTask: Task<WhisperKit, Error>?

    // MARK: - ASREngine

    func transcribe(audioURL: URL) async throws -> String {
        let wasWarm = whisper != nil
        let loadStart = Date()
        let wk = try await loadModelIfNeeded()
        vlog(wasWarm ? "model warm" : "model cold-loaded in \(String(format: "%.2f", Date().timeIntervalSince(loadStart)))s")

        // Decoding options tuned to reject non-speech: suppressBlank drops
        // leading blank tokens; the default no-speech / log-prob / compression
        // thresholds stay in force. skipSpecialTokens keeps control tokens out.
        var options = DecodingOptions(task: .transcribe, language: language)
        options.withoutTimestamps = true
        options.skipSpecialTokens = true
        options.suppressBlank = true

        let inferStart = Date()
        let results = try await wk.transcribe(audioPath: audioURL.path, decodeOptions: options)
        vlog("inference \(String(format: "%.2f", Date().timeIntervalSince(inferStart)))s")

        // `transcribe` returns [TranscriptionResult]; join all segments, then
        // strip Whisper's non-speech sound captions (see stripSoundAnnotations).
        let text = results
            .compactMap { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        return WhisperKitEngine.stripSoundAnnotations(text)
    }

    /// Whisper was trained on subtitles that annotate non-speech sounds
    /// ("[Music]", "*dog barking*", "♪"). On ambiguous or non-speech audio it
    /// emits these captions instead of words — never wanted in a dictation
    /// tool. Strips the bracketed / asterisk-wrapped / musical-note forms; when
    /// noise produces ONLY a caption this yields empty text and the empty-guard
    /// downstream skips injection entirely. Parentheses are left intact (too
    /// often a legitimately dictated aside).
    static func stripSoundAnnotations(_ text: String) -> String {
        var out = text
        for pattern in ["\\[[^\\]]*\\]", "\\*[^*]*\\*", "♪[^♪]*♪", "♪"] {
            out = out.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return out
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
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
        if let existing = whisper { return existing }

        // A load is already in flight — await its result instead of
        // starting a second concurrent CoreML load.
        if let existingTask = loadTask {
            return try await existingTask.value
        }

        guard let folder = ModelManager.modelFolderURL(for: localModel) else {
            throw WhisperKitEngineError.noModelFolder(localModel.rawValue)
        }

        logger.info("WhisperKit: loading model '\(self.modelID)' from \(folder.path, privacy: .public)…")

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

        do {
            let wk = try await task.value
            whisper = wk
            loadTask = nil
            logger.info("WhisperKit: model ready.")
            return wk
        } catch {
            loadTask = nil
            throw error
        }
    }
}

enum WhisperKitEngineError: Error, LocalizedError {
    case noModelFolder(String)
    case noTokenizer

    var errorDescription: String? {
        switch self {
        case .noModelFolder(let model):
            return "Model '\(model)' is not downloaded yet. Download it from Settings → Local Model."
        case .noTokenizer:
            return "WhisperKit model loaded without a tokenizer — cannot start streaming transcription."
        }
    }
}
