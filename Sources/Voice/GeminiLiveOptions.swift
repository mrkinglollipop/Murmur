import Foundation

/// Gemini Live transcription VAD mode. Manual keeps fn-hold / key-release as
/// the utterance boundary; automatic uses server VAD; hybrid uses VAD but
/// flushes on release via `audioStreamEnd`.
enum GeminiVadMode: String, CaseIterable, Identifiable, Codable {
    case manual
    case automatic
    case hybrid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .manual: return "On key release"
        case .automatic: return "Voice activity"
        case .hybrid: return "Hybrid"
        }
    }
}

enum GeminiStartSensitivity: String, CaseIterable, Identifiable, Codable {
    case high = "START_SENSITIVITY_HIGH"
    case low = "START_SENSITIVITY_LOW"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .high: return "High"
        case .low: return "Low"
        }
    }
}

enum GeminiEndSensitivity: String, CaseIterable, Identifiable, Codable {
    case high = "END_SENSITIVITY_HIGH"
    case low = "END_SENSITIVITY_LOW"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .high: return "High"
        case .low: return "Low"
        }
    }
}

/// Socket setup and VAD knobs for `gemini-3.5-transcribe-live`.
struct GeminiLiveOptions: Equatable {
    var vadMode: GeminiVadMode
    var startSensitivity: GeminiStartSensitivity
    var endSensitivity: GeminiEndSensitivity
    var prefixPaddingMs: Int
    var silenceDurationMs: Int

    static let defaults = GeminiLiveOptions(
        vadMode: .manual,
        startSensitivity: .high,
        endSensitivity: .high,
        prefixPaddingMs: 20,
        silenceDurationMs: 100
    )

    static let prefixPaddingRange: ClosedRange<Int> = 0...500
    static let silenceDurationRange: ClosedRange<Int> = 0...2000

    func clamped() -> GeminiLiveOptions {
        var copy = self
        copy.prefixPaddingMs = Self.clamp(copy.prefixPaddingMs, to: Self.prefixPaddingRange)
        copy.silenceDurationMs = Self.clamp(copy.silenceDurationMs, to: Self.silenceDurationRange)
        return copy
    }

    static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// First client message after the socket opens (camelCase per Google WS examples).
    static func makeSetupMessageJSON(
        language: String,
        smartMode: Bool,
        vocabulary: [String],
        options: GeminiLiveOptions
    ) -> String {
        let opts = options.clamped()
        var inputAudioTranscription: [String: Any] = [
            "mode": smartMode ? "SMART" : "VERBATIM",
            "languageCodes": [language]
        ]
        if !vocabulary.isEmpty {
            inputAudioTranscription["customVocabulary"] = vocabulary
        }

        var automaticActivityDetection: [String: Any] = [:]
        switch opts.vadMode {
        case .manual:
            automaticActivityDetection["disabled"] = true
        case .automatic, .hybrid:
            automaticActivityDetection["disabled"] = false
            automaticActivityDetection["startOfSpeechSensitivity"] = opts.startSensitivity.rawValue
            automaticActivityDetection["endOfSpeechSensitivity"] = opts.endSensitivity.rawValue
            automaticActivityDetection["prefixPaddingMs"] = opts.prefixPaddingMs
            automaticActivityDetection["silenceDurationMs"] = opts.silenceDurationMs
        }

        let setup: [String: Any] = [
            "model": "models/gemini-3.5-transcribe-live",
            "generationConfig": ["responseModalities": ["TEXT"]],
            "inputAudioTranscription": inputAudioTranscription,
            "realtimeInputConfig": [
                "automaticActivityDetection": automaticActivityDetection
            ]
        ]
        return jsonString(["setup": setup])
    }

    static func makeActivityStartFrameJSON() -> String {
        jsonString(["realtimeInput": ["activityStart": [String: Any]()]])
    }

    static func makeActivityEndFrameJSON() -> String {
        jsonString(["realtimeInput": ["activityEnd": [String: Any]()]])
    }

    static func makeAudioFrameJSON(pcmData: Data) -> String {
        jsonString([
            "realtimeInput": [
                "audio": [
                    "mimeType": "audio/pcm;rate=16000",
                    "data": pcmData.base64EncodedString()
                ]
            ]
        ])
    }

    static func makeAudioStreamEndFrameJSON() -> String {
        jsonString(["realtimeInput": ["audioStreamEnd": true]])
    }

    /// Interactions API body for batch `gemini-3.5-transcribe`.
    static func makeBatchRequestBody(
        wavBase64: String,
        mimeType: String,
        smartMode: Bool,
        vocabulary: [String]
    ) -> [String: Any] {
        var transcriptionConfig: [String: Any] = [
            "mode": ["type": smartMode ? "smart" : "verbatim"]
        ]
        if !vocabulary.isEmpty {
            transcriptionConfig["custom_vocabulary"] = vocabulary
        }
        return [
            "model": "gemini-3.5-transcribe",
            "input": [[
                "type": "audio",
                "data": wavBase64,
                "mime_type": mimeType
            ]],
            "generation_config": [
                "transcription_config": transcriptionConfig
            ]
        ]
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object) // swiftlint:disable:this force_try
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
