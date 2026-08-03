import Foundation

// MARK: - ASR Engine Protocol

/// Pluggable speech-recognition backend.
///
/// Each conforming type owns its own model loading / Python subprocess logic.
/// The protocol is intentionally minimal — batch transcription only for now;
/// streaming is a later slice.
protocol ASREngine {
    /// Short machine-readable identifier (e.g. "whisperKit", "parakeet").
    var id: String { get }

    /// Human-readable display name for settings UI.
    var displayName: String { get }

    /// Transcribe the audio file at `audioURL` and return the recognised text.
    ///
    /// - Parameter audioURL: File URL of the recorded audio (CAF or WAV).
    /// - Returns: Recognised text string (may be empty if no speech detected).
    /// - Throws: Any underlying model or I/O error.
    func transcribe(audioURL: URL) async throws -> String
}
