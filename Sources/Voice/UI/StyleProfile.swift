import Foundation

/// Cleanup formality profiles — appended to the cleanup LLM prompt when enabled.
enum StyleProfile: String, CaseIterable, Identifiable, Codable {
    case formal
    case casual
    case veryCasual = "very_casual"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .veryCasual: return "Very casual"
        }
    }

    var subtitle: String {
        switch self {
        case .formal: return "Polished, professional tone."
        case .casual: return "Natural conversational tone."
        case .veryCasual: return "Relaxed, informal phrasing."
        }
    }

    var example: String {
        switch self {
        case .formal: return "Please review the attached document at your earliest convenience."
        case .casual: return "Can you take a look at the doc when you get a chance?"
        case .veryCasual: return "hey can u check the doc when u have a sec"
        }
    }

    /// Instruction appended to the cleanup prompt.
    var instruction: String {
        switch self {
        case .formal:
            return "Use a formal, professional tone."
        case .casual:
            return "Use a casual, conversational tone."
        case .veryCasual:
            return "Use a very casual, informal tone."
        }
    }
}
