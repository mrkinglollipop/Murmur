import Foundation

// MARK: - Local ASR Model

/// The on-device speech-recognition models the user can select, ordered
/// best-first (used as the `CaseIterable` / picker order).
///
/// Each case owns both "which engine family" (WhisperKit vs the Parakeet MLX
/// sidecar) and, for WhisperKit cases, the exact model repo identifier passed
/// to `WhisperKit(model:)`. WhisperKit resolves these against its Hugging
/// Face model repo (argmaxinc/whisperkit-coreml) and downloads on first use.
///
/// WhisperKit model IDs verified against the argmaxinc/WhisperKit README's
/// documented naming convention (`openai_whisper-<size>`, with `-v3` /
/// `-v3-turbo` / distil variants published under the same repo). Stored as a
/// plain `String` (not baked into fixed logic) specifically so a wrong ID is
/// a one-line fix here rather than a structural change.
enum LocalModel: String, CaseIterable, Identifiable, Codable {
    case whisperLargeV3Turbo = "whisperLargeV3Turbo"
    case parakeetTDT06BV3    = "parakeetTDT06BV3"
    case whisperLargeV3      = "whisperLargeV3"
    case distilWhisperLargeV3 = "distilWhisperLargeV3"
    case whisperBase         = "whisperBase"

    var id: String { rawValue }

    /// Best-first default — the model applied on first launch.
    static let `default`: LocalModel = .whisperLargeV3Turbo

    var displayName: String {
        switch self {
        case .whisperLargeV3Turbo:  return "Whisper large-v3-turbo"
        case .parakeetTDT06BV3:     return "Parakeet TDT 0.6B v3"
        case .whisperLargeV3:       return "Whisper large-v3"
        case .distilWhisperLargeV3: return "distil-whisper large-v3"
        case .whisperBase:          return "Whisper base (fast/small)"
        }
    }

    /// Which engine family backs this model.
    var engineID: ASREngineID {
        switch self {
        case .parakeetTDT06BV3:
            return .parakeet
        default:
            return .whisperKit
        }
    }

    /// WhisperKit model repo identifier (per argmaxinc/WhisperKit's
    /// documented `openai_whisper-*` / distil naming). `nil` for the
    /// Parakeet case, which doesn't go through WhisperKit at all.
    var whisperKitModelID: String? {
        switch self {
        // NOTE: turbo uses an underscore before "turbo" in this repo
        // (`openai_whisper-large-v3_turbo`), unlike the other `-v3` variants.
        // Using the hyphen form makes WhisperKit's glob miss and fall back to
        // an ambiguous `*openai*` match, producing a doubled-prefix error.
        case .whisperLargeV3Turbo:  return "openai_whisper-large-v3_turbo"
        case .whisperLargeV3:       return "openai_whisper-large-v3"
        case .distilWhisperLargeV3: return "distil-whisper_distil-large-v3"
        case .whisperBase:          return "openai_whisper-base"
        case .parakeetTDT06BV3:     return nil
        }
    }
}

// MARK: - Cloud ASR Model

/// Cloud transcription providers shown in Settings. Selectable cases are
/// xAI Grok STT and ElevenLabs Scribe v2 Realtime; retired providers remain
/// for Keychain/factory compatibility but are hidden from the picker.
/// Batch uploads are wired via `CloudTranscriber`; streaming via
/// `XAIStreamingTranscriber` / `ElevenLabsRealtimeTranscriber`.
enum CloudModel: String, CaseIterable, Identifiable, Codable {
    /// Retained as scaffolding, not user-selectable: deprecated `speech_model`
    /// param returns HTTP 400 on every request (confirmed 2026-07-09).
    case assemblyAIUniversal3   = "assemblyAIUniversal3"
    /// Retained as scaffolding, not user-selectable: unused (0 of 772
    /// dictations) and scored least-accurate in the bake-off.
    case deepgramNova3          = "deepgramNova3"
    /// Retained as scaffolding, not user-selectable. OpenAI API key is still
    /// used by cleanup and transforms (separate Keychain account).
    case openAIGPT4oTranscribe  = "openAIGPT4oTranscribe"
    /// Retained as scaffolding, not user-selectable: unused (0 of 772
    /// dictations) and the stored key is dead (401 at credential level).
    case groqWhisperLargeV3Turbo = "groqWhisperLargeV3Turbo"
    case xaiGrokSTT             = "xaiGrokSTT"
    case elevenLabsScribeV2Realtime = "elevenLabsScribeV2Realtime"

    var id: String { rawValue }

    /// First selectable cloud model — matches Settings picker default.
    static let `default`: CloudModel = .xaiGrokSTT

    /// Cloud models offered in the Settings picker. AssemblyAI, Deepgram,
    /// Groq, and OpenAI are excluded (see doc comments on each case above)
    /// but their service classes, `CloudProvider` cases, and
    /// `CloudTranscriberFactory` mapping stay compiled and working — this
    /// is a visibility change only (plan 013).
    static var selectable: [CloudModel] {
        [.xaiGrokSTT, .elevenLabsScribeV2Realtime]
    }

    /// Sanitizes a (possibly stale) persisted selection: a model that's
    /// still `selectable` passes through unchanged; a retired model (e.g. a
    /// previously-chosen Deepgram/AssemblyAI/Groq/OpenAI selection) falls
    /// back to xAI so the app never presents or uses a hidden model.
    static func selectableOrFallback(_ model: CloudModel) -> CloudModel {
        selectable.contains(model) ? model : .xaiGrokSTT
    }

    var displayName: String {
        switch self {
        case .assemblyAIUniversal3:    return "AssemblyAI Universal-3"
        case .deepgramNova3:           return "Deepgram Nova-3"
        case .openAIGPT4oTranscribe:   return "OpenAI gpt-4o-transcribe"
        case .groqWhisperLargeV3Turbo: return "Groq whisper-large-v3-turbo"
        case .xaiGrokSTT:              return "xAI Grok (grok-stt)"
        case .elevenLabsScribeV2Realtime: return "ElevenLabs Scribe v2 Realtime"
        }
    }
}
