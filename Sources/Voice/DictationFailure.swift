import Foundation

/// Terminal failure reasons surfaced to the user via the recording HUD and
/// menu-bar badge. Each case maps to a short, actionable message.
enum DictationFailure: Equatable {
    case transcriptionFailed
    case injectionFailed
    case audioWriteFailed
    case micStartFailed
    case micDeliveredNoAudio
    case secureInputBlocked
    case voiceEditFailed

    /// User-facing copy for the HUD error pill.
    var message: String {
        switch self {
        case .transcriptionFailed:
            return "Transcription failed"
        case .injectionFailed:
            return "Couldn't paste — on clipboard"
        case .audioWriteFailed:
            return "Couldn't save audio"
        case .micStartFailed:
            return "Microphone unavailable"
        case .micDeliveredNoAudio:
            return "No mic audio — check Sound input"
        case .secureInputBlocked:
            return "Secure field — can't paste"
        case .voiceEditFailed:
            return "Try rephrasing"
        }
    }
}
