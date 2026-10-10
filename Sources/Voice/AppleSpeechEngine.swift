import AVFoundation
import Foundation
import Speech

/// Batch transcription using macOS SpeechAnalyzer and its system-managed
/// on-device speech assets.
final class AppleSpeechEngine: ASREngine {
    let id = "appleSpeech"
    let displayName = "Apple (built in)"

    /// ISO 639-1 code from Settings. The engine is cached, so the selector
    /// updates this before every reuse.
    var language: String

    init(language: String = "en") {
        self.language = language
    }

    func transcribe(audioURL: URL) async throws -> String {
        let audioFile = try AVAudioFile(forReading: audioURL)
        let language = language
        return try await LocalTranscriptionDeadline.run(
            seconds: LocalTranscriptionDeadline.seconds(for: audioFile),
            engineName: displayName
        ) {
            try await Self.transcribe(audioFile: audioFile, language: language)
        }
    }

    private static func transcribe(audioFile: AVAudioFile, language: String) async throws -> String {
        let transcriber = try await Self.transcriber(language: language)
        try Task.checkCancellation()
        let status = await AssetInventory.status(forModules: [transcriber])
        try Task.checkCancellation()
        guard status == .installed else {
            throw AppleSpeechEngineError.assetNotInstalled(language: language)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let transcriptTask = Task<String, Error> {
            try Task.checkCancellation()
            var finalText = ""
            for try await result in transcriber.results {
                try Task.checkCancellation()
                guard result.isFinal else { continue }
                finalText = Self.appendingFinalSegment(
                    String(result.text.characters),
                    to: finalText
                )
            }
            return finalText
        }

        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let finalSample = try await analyzer.analyzeSequence(from: audioFile)
                try Task.checkCancellation()
                if let finalSample {
                    try await analyzer.finalizeAndFinish(through: finalSample)
                } else {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                }
                return try await transcriptTask.value
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                transcriptTask.cancel()
                await analyzer.cancelAndFinishNow()
                _ = await transcriptTask.result
                throw error
            }
        } onCancel: {
            transcriptTask.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// Resolves the exact locale supported by the system before constructing a
    /// module. The same module shape is used for readiness, installation, and
    /// transcription so the UI cannot report a different asset than the engine.
    static func transcriber(language: String) async throws -> SpeechTranscriber {
        let requestedLocale = Locale(identifier: language)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw AppleSpeechEngineError.unsupportedLanguage(language)
        }
        return SpeechTranscriber(locale: locale, preset: .transcription)
    }

    /// Final results can arrive in multiple ranges for a batch file. Keep all
    /// ranges in order instead of letting the last one overwrite prior speech.
    static func appendingFinalSegment(_ segment: String, to transcript: String) -> String {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return transcript }
        return transcript.isEmpty ? trimmed : "\(transcript) \(trimmed)"
    }
}

enum AppleSpeechEngineError: LocalizedError {
    case unsupportedLanguage(String)
    case assetNotInstalled(language: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let language):
            return "Apple speech is unavailable for \(language)."
        case .assetNotInstalled:
            return "Install the Apple speech asset in Settings before dictating."
        }
    }
}
