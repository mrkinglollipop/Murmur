import FluidAudio
import Foundation
import os.log

/// Production `SpeakerEmbeddingProviding` backed by FluidAudio's WeSpeaker
/// diarizer embeddings. Model download/init runs once on a background task;
/// stays fail-open (`isReady == false`) forever on failure.
final class FluidAudioEmbeddingProvider: SpeakerEmbeddingProviding {

    static let modelId = "fluidaudio-wespeaker-0.15.5"

    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "voice-gate")
    private let stateLock = NSLock()
    private var _isReady = false
    private var diarizer: DiarizerManager?

    var isReady: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isReady
    }

    init() {
        Task {
            await loadModels()
        }
    }

    func embedding(for samples: [Float]) -> [Float]? {
        stateLock.lock()
        let manager = diarizer
        let ready = _isReady
        stateLock.unlock()
        guard ready, let manager else { return nil }
        do {
            return try manager.extractSpeakerEmbedding(from: samples)
        } catch {
            logger.error("FluidAudio extractEmbedding failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func loadModels() async {
        do {
            let models = try await DiarizerModels.downloadIfNeeded()
            let manager = DiarizerManager()
            manager.initialize(models: models)
            stateLock.lock()
            diarizer = manager
            _isReady = true
            stateLock.unlock()
            logger.info("FluidAudio speaker-embedding models ready.")
        } catch {
            logger.error("FluidAudio model load failed: \(error.localizedDescription)")
        }
    }
}
