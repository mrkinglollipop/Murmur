import Foundation

/// Caps + punctuation profiles. Wispr Style is formatting, not an LLM rewrite.
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
        case .formal: return "Caps + punctuation"
        case .casual: return "Caps + less punctuation"
        case .veryCasual: return "No caps + less punctuation"
        }
    }

    var example: String {
        switch self {
        case .formal:
            return "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you."
        case .casual:
            return "Hey, are you free for lunch tomorrow let's do 12 if that works for you"
        case .veryCasual:
            return "hey are you free for lunch tomorrow let's do 12 if that works for you"
        }
    }
}
