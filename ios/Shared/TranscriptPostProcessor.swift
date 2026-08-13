import Foundation

/// Mac `TranscriptionPipeline.preprocessBeforeCleanup` with code-aware off.
/// Caps always, then dot-compound numbers. Spoken punctuation stays Mac-only.
enum TranscriptPostProcessor {
    static func applySpokenPasses(_ text: String) -> String {
        DotCompoundNumberNormalizer.apply(SpokenCapitalization.apply(text))
    }
}
