import Foundation

/// Scribe v2 Realtime commit strategy. Manual is Murmur's dictation default
/// so fn-hold still bounds the take; VAD auto-commits when the server hears
/// silence (useful for hands-free, can split a long hold).
enum ElevenLabsCommitStrategy: String, CaseIterable, Identifiable {
    case manual
    case vad

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .manual: return "On key release"
        case .vad: return "Voice activity"
        }
    }
}

/// Query knobs for `scribe_v2_realtime` that Settings Advanced exposes.
/// Defaults match the previous hardcoded socket (manual commit, no
/// background-audio filter, VAD fields omitted).
struct ElevenLabsRealtimeOptions: Equatable {
    var filterBackgroundAudio: Bool
    var commitStrategy: ElevenLabsCommitStrategy
    var vadThreshold: Double
    var vadSilenceThresholdSecs: Double
    var minSpeechDurationMs: Int
    var minSilenceDurationMs: Int

    static let defaults = ElevenLabsRealtimeOptions(
        filterBackgroundAudio: false,
        commitStrategy: .manual,
        vadThreshold: 0.4,
        vadSilenceThresholdSecs: 1.5,
        minSpeechDurationMs: 100,
        minSilenceDurationMs: 100
    )

    static let vadThresholdRange: ClosedRange<Double> = 0.1...0.9
    static let vadSilenceRange: ClosedRange<Double> = 0.3...3.0
    static let minSpeechMsRange: ClosedRange<Int> = 50...500
    static let minSilenceMsRange: ClosedRange<Int> = 50...500

    func clamped() -> ElevenLabsRealtimeOptions {
        var copy = self
        copy.vadThreshold = Self.clamp(copy.vadThreshold, to: Self.vadThresholdRange)
        copy.vadSilenceThresholdSecs = Self.clamp(copy.vadSilenceThresholdSecs, to: Self.vadSilenceRange)
        copy.minSpeechDurationMs = Self.clamp(copy.minSpeechDurationMs, to: Self.minSpeechMsRange)
        copy.minSilenceDurationMs = Self.clamp(copy.minSilenceDurationMs, to: Self.minSilenceMsRange)
        return copy
    }

    /// Extra query items on top of model/format/language/`no_verbatim`/`keyterms`.
    /// VAD numeric params are sent only for `commit_strategy=vad`. Filter is
    /// omitted when off so the default URL stays equivalent to today's socket.
    /// Never pairs with `include_timestamps` (EL rejects that combo).
    func queryItems() -> [URLQueryItem] {
        let value = clamped()
        var items = [
            URLQueryItem(name: "commit_strategy", value: value.commitStrategy.rawValue)
        ]
        if value.filterBackgroundAudio {
            items.append(URLQueryItem(name: "filter_background_audio", value: "true"))
        }
        if value.commitStrategy == .vad {
            items.append(URLQueryItem(name: "vad_threshold", value: Self.decimalString(value.vadThreshold)))
            items.append(URLQueryItem(
                name: "vad_silence_threshold_secs",
                value: Self.decimalString(value.vadSilenceThresholdSecs)
            ))
            items.append(URLQueryItem(name: "min_speech_duration_ms", value: String(value.minSpeechDurationMs)))
            items.append(URLQueryItem(name: "min_silence_duration_ms", value: String(value.minSilenceDurationMs)))
        }
        return items
    }

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func decimalString(_ value: Double) -> String {
        String(format: "%g", value)
    }
}
