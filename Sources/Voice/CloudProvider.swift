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

    /// Short name for HUD, menu and Settings copy ("xAI", not "xAI (Grok)").
    var shortName: String {
        switch self {
        case .xai:    return "xAI"
        case .gemini: return "Gemini"
        default:      return displayName
        }
    }

    /// Where the user fixes a billing refusal.
    var billingURL: URL {
        switch self {
        case .elevenLabs: return URL(string: "https://elevenlabs.io/app/subscription")!
        case .xai:        return URL(string: "https://console.x.ai")!
        case .assemblyAI: return URL(string: "https://www.assemblyai.com/dashboard")!
        case .deepgram:   return URL(string: "https://console.deepgram.com")!
        case .openAI:     return URL(string: "https://platform.openai.com/settings/organization/billing/overview")!
        case .groq:       return URL(string: "https://console.groq.com/settings/billing")!
        case .gemini:     return URL(string: "https://aistudio.google.com/apikey")!
        case .meta:       return URL(string: "https://dev.meta.ai/docs/quickstart")!
        }
    }
}

// MARK: - Errors

struct CloudTranscriptionError: LocalizedError {
    let provider: CloudProvider
    let message: String
    /// A successful response contained no text; this is not evidence of silent audio.
    let isEmptyTranscript: Bool
    /// What kind of refusal this was (plan 034). `.transient` for anything that
    /// is not an HTTP billing/auth/rate-limit response, so existing fallback
    /// behaviour is unchanged.
    let kind: CloudFailureKind
    /// HTTP status of the response, when there was one.
    let statusCode: Int?
    /// True when the verdict comes from a realtime handshake status alone (no
    /// body); the batch attempt on the same hold makes the call final.
    let isProvisional: Bool

    init(
        provider: CloudProvider,
        message: String,
        isEmptyTranscript: Bool = false,
        kind: CloudFailureKind = .transient,
        statusCode: Int? = nil,
        isProvisional: Bool = false
    ) {
        self.provider = provider
        self.message = message
        self.isEmptyTranscript = isEmptyTranscript
        self.kind = kind
        self.statusCode = statusCode
        self.isProvisional = isProvisional
    }

    static func emptyTranscript(provider: CloudProvider) -> CloudTranscriptionError {
        CloudTranscriptionError(provider: provider, message: "No transcript in response", isEmptyTranscript: true)
    }

    var errorDescription: String? {
        "\(provider.displayName): \(message)"
    }

    static func httpStatus(_ status: Int, provider: CloudProvider, body: String? = nil) -> CloudTranscriptionError {
        let suffix = body.map { " — \(redactedBodyFragment($0))" } ?? ""
        // Classify from the RAW body (redaction only trims it for logs); only
        // the resulting kind is kept, never the body itself.
        return CloudTranscriptionError(
            provider: provider,
            message: "HTTP \(status)\(suffix)",
            kind: CloudFailureClassifier.classify(status: status, body: body),
            statusCode: status
        )
    }

    /// A realtime WebSocket upgrade answered 401/402/403. There is no body on
    /// that path, so the verdict is provisional until a batch response on the
    /// same hold confirms or contradicts it.
    static func handshakeRejected(_ status: Int, provider: CloudProvider) -> CloudTranscriptionError {
        CloudTranscriptionError(
            provider: provider,
            message: "task completed httpStatus=\(status)",
            kind: CloudFailureClassifier.classify(status: status, body: nil),
            statusCode: status,
            isProvisional: true
        )
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
