import Foundation

/// Maps stored history `engine` IDs to user-facing names. Stored IDs are
/// inconsistent across writers — display-only; unifying written IDs is out
/// of scope (plan 023 §3.3).
enum EngineDisplayName {
    static func displayName(for storedID: String) -> String {
        switch storedID {
        case "parakeet":
            return LocalModel.parakeetTDT06BV3.displayName
        case "cloud:elevenlabs-streaming":
            return "\(CloudProvider.elevenLabs.displayName) (streaming)"
        case "cloud:elevenLabs":
            return CloudProvider.elevenLabs.displayName
        case "cloud:xai-streaming":
            return "\(CloudProvider.xai.displayName) (streaming)"
        case "whisperKit:streaming":
            return "Whisper (streaming)"
        case "whisperKit:openai_whisper-large-v3_turbo":
            return LocalModel.whisperLargeV3Turbo.displayName
        default:
            break
        }

        if storedID.hasPrefix("whisperKit:") {
            let modelID = String(storedID.dropFirst("whisperKit:".count))
            if let local = LocalModel.allCases.first(where: { $0.whisperKitModelID == modelID }) {
                return local.displayName
            }
            return "Whisper (\(humanize(modelID)))"
        }

        if storedID.hasPrefix("cloud:") {
            let suffix = String(storedID.dropFirst("cloud:".count))
            if suffix.hasSuffix("-streaming") {
                let base = String(suffix.dropLast("-streaming".count))
                return "\(cloudProviderName(for: base)) (streaming)"
            }
            if let provider = CloudProvider(rawValue: suffix) {
                return provider.displayName
            }
            return "Cloud (\(humanize(suffix)))"
        }

        return "Unknown engine"
    }

    private static func cloudProviderName(for suffix: String) -> String {
        switch suffix {
        case "elevenlabs":
            return CloudProvider.elevenLabs.displayName
        case "xai":
            return CloudProvider.xai.displayName
        default:
            if let provider = CloudProvider(rawValue: suffix) {
                return provider.displayName
            }
            return humanize(suffix)
        }
    }

    private static func humanize(_ id: String) -> String {
        id.replacingOccurrences(of: "_", with: " ")
    }
}
