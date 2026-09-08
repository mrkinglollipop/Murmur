import FluidAudio
import Foundation
import os.log

/// Production `SpeakerEmbeddingProviding` backed by FluidAudio's WeSpeaker
/// diarizer embeddings. Model loading stays off-main and fails open;
/// an explicit settings update can retry a failed load.
final class FluidAudioEmbeddingProvider: SpeakerEmbeddingProviding {

    static let modelId = "fluidaudio-wespeaker-0.15.6"

    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "voice-gate")
    private let stateLock = NSLock()
    private var _isReady = false
    private var isLoading = false
    private var diarizer: DiarizerManager?
    private let loader: () async throws -> DiarizerManager

    var isReady: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isReady
    }

    init(loader: @escaping () async throws -> DiarizerManager = {
        let models = try await DiarizerModels.downloadIfNeeded()
        let manager = DiarizerManager()
        manager.initialize(models: models)
        return manager
    }) {
        self.loader = loader
        retryLoadingIfNeeded()
    }

    @discardableResult
    func retryLoadingIfNeeded() -> Bool {
        stateLock.lock()
        guard !_isReady, !isLoading else {
            stateLock.unlock()
            return false
        }
        isLoading = true
        stateLock.unlock()
        Task { await loadModels() }
        return true
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
            let manager = try await loader()
            stateLock.lock()
            diarizer = manager
            _isReady = true
            isLoading = false
            stateLock.unlock()
            logger.info("FluidAudio speaker-embedding models ready.")
        } catch {
            stateLock.lock()
            isLoading = false
            stateLock.unlock()
            logger.error("FluidAudio model load failed: \(error.localizedDescription)")
        }
    }
}
