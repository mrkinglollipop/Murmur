import Foundation

/// Deterministic voice-command pass over a transcript. Runs after cleanup
/// and before dictionary correction — pure commands with no other text yield
/// empty output so nothing is injected.
enum VoiceCommands {

    private static let commands = ["scratch that", "delete last sentence"]

    /// Applies voice commands to `text`. Returns trimmed result; empty when
    /// the utterance is purely a command with no dictation payload.
    static func apply(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let normalized = trimmed.lowercased()

        for command in commands {
            if normalized == command {
                return ""
            }
            if normalized.hasSuffix(command) {
                let prefix = trimmed.dropLast(command.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
                return removeLastSentence(from: String(prefix))
            }
        }

        return trimmed
    }

    /// Removes the last sentence from `text`. If nothing remains, returns "".
    private static func removeLastSentence(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var sentences = splitSentences(trimmed)
        guard !sentences.isEmpty else { return "" }
        sentences.removeLast()
        return sentences.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits on sentence-ending punctuation while keeping the delimiter on
    /// each segment (except possibly the last).
    private static func splitSentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""

        for char in text {
            current.append(char)
            if ".!?".contains(char) {
                let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { result.append(piece) }
                current = ""
            }
        }

        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }
}
