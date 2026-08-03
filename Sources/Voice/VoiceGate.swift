import Foundation

// MARK: - Embedding provider

/// Abstraction over the speaker-embedding backend (FluidAudio in production,
/// fakes in unit tests). Never throws across this boundary — the gate fails
/// open on any error.
protocol SpeakerEmbeddingProviding {
    /// True once the underlying model is loaded and ready to embed. False while
    /// downloading/loading or if load failed — callers must fail-open when false.
    var isReady: Bool { get }
    /// Returns an L2-normalizable embedding vector for ~1s of 16kHz mono Float32
    /// samples, or nil on any failure (never throws across this boundary — the
    /// gate must be able to fail-open cheaply).
    func embedding(for samples: [Float]) -> [Float]?
}

// MARK: - Sensitivity

enum VoiceGateSensitivity: String, Codable, CaseIterable {
    case low
    case medium
    case high

    /// Cosine-similarity threshold for pass vs attenuate.
    /// UNTUNED PLACEHOLDERS — plans/022 spike only validated the embedding call
    /// path on random noise, not real enrolled-vs-imposter speech. Real tuning is
    /// session B+.
    var cosineThreshold: Float {
        switch self {
        case .low: return 0.20
        case .medium: return 0.30
        case .high: return 0.40
        }
    }
}

// MARK: - Profile

struct VoiceProfile: Codable, Equatable {
    var embedding: [Float]
    var createdAt: Date
    var modelId: String
}

// MARK: - Pure math (unit-testable)

/// Element-wise mean across embedding vectors. Empty input → empty array.
func meanEmbedding(_ embeddings: [[Float]]) -> [Float] {
    guard let first = embeddings.first, !first.isEmpty else { return [] }
    let dimension = first.count
    var sums = [Float](repeating: 0, count: dimension)
    var count = 0
    for embedding in embeddings {
        guard embedding.count == dimension else { continue }
        for i in 0 ..< dimension {
            sums[i] += embedding[i]
        }
        count += 1
    }
    guard count > 0 else { return [] }
    let divisor = Float(count)
    return sums.map { $0 / divisor }
}

/// L2-normalizes `vector`. Zero-vector input is returned unchanged.
func l2Normalize(_ vector: [Float]) -> [Float] {
    var sumSquares: Float = 0
    for value in vector {
        sumSquares += value * value
    }
    guard sumSquares > 0 else { return vector }
    let norm = sqrt(sumSquares)
    guard norm.isFinite, norm > 0 else { return vector }
    return vector.map { $0 / norm }
}

/// Cosine similarity of two vectors. Returns 0 for mismatched lengths or
/// zero-norm inputs — never NaN.
func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0
    var normA: Float = 0
    var normB: Float = 0
    for i in a.indices {
        dot += a[i] * b[i]
        normA += a[i] * a[i]
        normB += b[i] * b[i]
    }
    guard normA > 0, normB > 0 else { return 0 }
    let denom = sqrt(normA) * sqrt(normB)
    guard denom.isFinite, denom > 0 else { return 0 }
    let result = dot / denom
    return result.isFinite ? result : 0
}

// MARK: - Gate

enum VoiceGateDecision: Equatable {
    case pass
    case attenuate
}

struct VoiceGateEvaluation: Equatable {
    let decision: VoiceGateDecision
    /// Present only when profile, provider, and embedding all succeeded.
    let similarity: Float?
}

struct VoiceGateTelemetrySnapshot: Equatable {
    let attemptedWindows: Int
    let passedWindows: Int
    let attenuatedWindows: Int
    let unscoredWindows: Int
    let medianSimilarity: Float?
    /// True while a recording hold is in progress; false once released.
    let isSessionActive: Bool

    var evaluatedWindows: Int { passedWindows + attenuatedWindows }

    static let empty = VoiceGateTelemetrySnapshot(
        attemptedWindows: 0,
        passedWindows: 0,
        attenuatedWindows: 0,
        unscoredWindows: 0,
        medianSimilarity: nil,
        isSessionActive: false
    )
}

/// Median of scored cosine similarities. Empty input → nil.
func medianSimilarity(_ values: [Float]) -> Float? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[mid - 1] + sorted[mid]) / 2
    }
    return sorted[mid]
}

/// Session token, telemetry, and atomic commit for one recording hold.
final class VoiceGateRecordingSession: @unchecked Sendable {

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var isActive = false
    private var similarities: [Float] = []
    private var attemptedWindows = 0
    private var passedWindows = 0
    private var attenuatedWindows = 0
    private var unscoredWindows = 0

    func begin() {
        lock.lock()
        generation &+= 1
        isActive = true
        similarities.removeAll(keepingCapacity: false)
        attemptedWindows = 0
        passedWindows = 0
        attenuatedWindows = 0
        unscoredWindows = 0
        lock.unlock()
    }

    /// Invalidates the current token so in-flight async work cannot commit.
    func end() {
        lock.lock()
        generation &+= 1
        isActive = false
        lock.unlock()
    }

    /// Returns the live session token, or nil when inactive (blocks trailing dispatch).
    func tokenForDispatch() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return nil }
        return generation
    }

    /// Atomically validates the token, records telemetry, and runs `updateLatch`.
    @discardableResult
    func commit(
        token: UInt64,
        evaluation: VoiceGateEvaluation,
        updateLatch: (VoiceGateDecision) -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isActive, token == generation else { return false }
        attemptedWindows += 1
        if let similarity = evaluation.similarity {
            similarities.append(similarity)
            switch evaluation.decision {
            case .pass:
                passedWindows += 1
            case .attenuate:
                attenuatedWindows += 1
            }
        } else {
            unscoredWindows += 1
        }
        updateLatch(evaluation.decision)
        return true
    }

    func snapshot() -> VoiceGateTelemetrySnapshot {
        lock.lock()
        let snapshot = VoiceGateTelemetrySnapshot(
            attemptedWindows: attemptedWindows,
            passedWindows: passedWindows,
            attenuatedWindows: attenuatedWindows,
            unscoredWindows: unscoredWindows,
            medianSimilarity: medianSimilarity(similarities),
            isSessionActive: isActive
        )
        lock.unlock()
        return snapshot
    }
}

/// Speaker-gating decision engine — pure logic over an injected embedding
/// provider and on-disk profile. Fail-open on every error path.
final class VoiceGate {

    private let profileStore: VoiceProfileStore
    private let embeddingProvider: SpeakerEmbeddingProviding
    private var sensitivity: VoiceGateSensitivity
    let modelId: String

    init(
        profileStore: VoiceProfileStore,
        embeddingProvider: SpeakerEmbeddingProviding,
        sensitivity: VoiceGateSensitivity,
        modelId: String = FluidAudioEmbeddingProvider.modelId
    ) {
        self.profileStore = profileStore
        self.embeddingProvider = embeddingProvider
        self.sensitivity = sensitivity
        self.modelId = modelId
    }

    func updateSensitivity(_ sensitivity: VoiceGateSensitivity) {
        self.sensitivity = sensitivity
    }

    /// Enrolls from per-segment ~1s 16kHz mono Float32 windows. Returns nil if
    /// the provider isn't ready or produced zero usable embeddings.
    func enroll(segments: [[Float]]) -> VoiceProfile? {
        guard embeddingProvider.isReady else { return nil }
        var embeddings: [[Float]] = []
        for segment in segments {
            if let embedding = embeddingProvider.embedding(for: segment) {
                embeddings.append(embedding)
            }
        }
        guard !embeddings.isEmpty else { return nil }
        let mean = meanEmbedding(embeddings)
        guard !mean.isEmpty else { return nil }
        let normalized = l2Normalize(mean)
        guard normalized.contains(where: { $0 != 0 }) else { return nil }
        let profile = VoiceProfile(
            embedding: normalized,
            createdAt: Date(),
            modelId: modelId
        )
        profileStore.save(profile)
        return profile
    }

    /// Fail-open speaker gate — see branch comments for precedence.
    func evaluate(window: [Float]) -> VoiceGateEvaluation {
        // 1. No stored profile → pass (gate inactive until enrolled).
        guard let profile = profileStore.load() else {
            return VoiceGateEvaluation(decision: .pass, similarity: nil)
        }
        // 2. Provider not ready (loading / download failed / unavailable) → pass.
        guard embeddingProvider.isReady else {
            return VoiceGateEvaluation(decision: .pass, similarity: nil)
        }
        // 3. Embedding computation failed → pass.
        guard let embedding = embeddingProvider.embedding(for: window) else {
            return VoiceGateEvaluation(decision: .pass, similarity: nil)
        }
        // 4. Cosine similarity at or above threshold → pass.
        let similarity = cosineSimilarity(embedding, profile.embedding)
        if similarity >= sensitivity.cosineThreshold {
            return VoiceGateEvaluation(decision: .pass, similarity: similarity)
        }
        // 5. Below threshold → attenuate non-owner speech.
        return VoiceGateEvaluation(decision: .attenuate, similarity: similarity)
    }

    /// Multiplies every sample by 0.05 in place.
    static func attenuate(_ samples: inout [Float]) {
        for index in samples.indices {
            samples[index] *= 0.05
        }
    }
}
