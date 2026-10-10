import AVFoundation
import Foundation

/// Decode budgets allow slower-than-real-time inference without letting a
/// parked engine hold the dictation pipeline indefinitely.
enum LocalTranscriptionDeadline {
    static let minimumTimeout: TimeInterval = 30
    static let maximumTimeout: TimeInterval = 300
    static let audioDurationMultiplier: Double = 4

    static func seconds(forAudioDuration duration: TimeInterval) -> TimeInterval {
        guard !duration.isNaN else { return minimumTimeout }
        return min(maximumTimeout, max(minimumTimeout, duration * audioDurationMultiplier))
    }

    static func seconds(for audioFile: AVAudioFile) -> TimeInterval {
        seconds(forAudioDuration: Double(audioFile.length) / audioFile.processingFormat.sampleRate)
    }

    /// Use the continuation race rather than a task group: joining a cancelled
    /// child would let an unresponsive framework defeat the caller's deadline.
    static func run(
        seconds: TimeInterval,
        engineName: String,
        operation: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        try await AsyncDeadline.run(
            seconds: seconds,
            timeoutError: { LocalTranscriptionTimeout(engineName: engineName, seconds: seconds) },
            operation: {
                try Task.checkCancellation()
                let text = try await operation()
                try Task.checkCancellation()
                return text
            }
        )
    }
}

struct LocalTranscriptionTimeout: Error, LocalizedError, Sendable {
    let engineName: String
    let seconds: TimeInterval

    var errorDescription: String? {
        "\(engineName) did not finish transcribing within \(seconds)s. The recording is kept — retry from History."
    }
}
