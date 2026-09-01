import Foundation

// MARK: - Cloud Provider

/// BYO-API-key cloud transcription providers. Distinct from `CloudModel` (which
/// is the picker-facing model choice) so provider identity — Keychain account,
/// signup link, display name — lives in one place regardless of which specific
/// model a provider exposes.
enum CloudProvider: String, CaseIterable, Identifiable {
    case assemblyAI = "assemblyAI"
    case deepgram   = "deepgram"
    case openAI     = "openAI"
    case groq       = "groq"
    case xai        = "xai"
    case elevenLabs = "elevenLabs"
    case gemini     = "gemini"
    case meta       = "meta"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .assemblyAI: return "AssemblyAI"
        case .deepgram:   return "Deepgram"
        case .openAI:     return "OpenAI"
        case .groq:       return "Groq"
        case .xai:        return "xAI (Grok)"
        case .elevenLabs: return "ElevenLabs"
        case .gemini:     return "Google Gemini"
        case .meta:       return "Meta"
        }
    }

    /// Keychain account identifier this provider's key is stored under
    /// (service is fixed in `KeychainStore`).
    var keychainAccount: String { rawValue }

    var signupURL: URL {
        switch self {
        case .assemblyAI: return URL(string: "https://www.assemblyai.com/dashboard/signup")!
        case .deepgram:   return URL(string: "https://console.deepgram.com/signup")!
        case .openAI:     return URL(string: "https://platform.openai.com/api-keys")!
        case .groq:       return URL(string: "https://console.groq.com/keys")!
        case .xai:        return URL(string: "https://console.x.ai")!
        case .elevenLabs: return URL(string: "https://elevenlabs.io/app/settings/api-keys")!
        case .gemini:     return URL(string: "https://aistudio.google.com/apikey")!
        case .meta:       return URL(string: "https://dev.meta.ai/docs/quickstart")!
        }
    }
}

// MARK: - Errors

struct CloudTranscriptionError: LocalizedError {
    let provider: CloudProvider
    let message: String

    var errorDescription: String? {
        "\(provider.displayName): \(message)"
    }

    static func httpStatus(_ status: Int, provider: CloudProvider, body: String? = nil) -> CloudTranscriptionError {
        let suffix = body.map { " — \(redactedBodyFragment($0))" } ?? ""
        return CloudTranscriptionError(provider: provider, message: "HTTP \(status)\(suffix)")
    }

    /// Strips anything key-shaped before a body fragment can reach logs:
    /// long unbroken token runs (20+ chars of [A-Za-z0-9_-]) are replaced
    /// with "…". Keeps enough context to diagnose HTTP errors.
    static func redactedBodyFragment(_ body: String, max: Int = 300) -> String {
        let pattern = "[A-Za-z0-9_\\-]{20,}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return String(body.prefix(max))
        }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        let redacted = regex.stringByReplacingMatches(in: body, range: range, withTemplate: "…")
        return String(redacted.prefix(max))
    }
}
