import XCTest
@testable import Voice

final class VoiceGateTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for dir in tempDirectories {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-voicegate-\(UUID().uuidString)", isDirectory: true)
        tempDirectories.append(url)
        return url
    }

    // MARK: - Fake embedding provider

    private final class FakeEmbeddingProvider: SpeakerEmbeddingProviding {
        var isReady: Bool
        var embeddings: [[Float]]
        private var callIndex = 0

        init(isReady: Bool = true, embeddings: [[Float]] = []) {
            self.isReady = isReady
            self.embeddings = embeddings
        }

        func embedding(for samples: [Float]) -> [Float]? {
            guard isReady else { return nil }
            guard callIndex < embeddings.count else { return nil }
            defer { callIndex += 1 }
            return embeddings[callIndex]
        }
    }

    private struct ConstantEmbeddingProvider: SpeakerEmbeddingProviding {
        var isReady: Bool
        let vector: [Float]?

        func embedding(for samples: [Float]) -> [Float]? {
            guard isReady else { return nil }
            return vector
        }
    }

    // MARK: - Pure math

    func testMeanEmbeddingComputesElementWiseMean() {
        let result = meanEmbedding([[1, 2, 3], [3, 4, 5]])
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0], 2, accuracy: 1e-5)
        XCTAssertEqual(result[1], 3, accuracy: 1e-5)
        XCTAssertEqual(result[2], 4, accuracy: 1e-5)
    }

    func testMeanEmbeddingEmptyInputReturnsEmpty() {
        XCTAssertTrue(meanEmbedding([]).isEmpty)
    }

    func testL2NormalizeUnitVector() {
        let normalized = l2Normalize([3, 4])
        let norm = sqrt(normalized[0] * normalized[0] + normalized[1] * normalized[1])
        XCTAssertEqual(norm, 1.0, accuracy: 1e-5)
    }

    func testL2NormalizeZeroVectorUnchanged() {
        let zero = [Float](repeating: 0, count: 4)
        XCTAssertEqual(l2Normalize(zero), zero)
    }

    func testCosineSimilarityIdenticalVectors() {
        let v: [Float] = [1, 2, 3]
        XCTAssertEqual(cosineSimilarity(v, v), 1.0, accuracy: 1e-5)
    }

    func testCosineSimilarityOrthogonalVectors() {
        XCTAssertEqual(cosineSimilarity([1, 0], [0, 1]), 0.0, accuracy: 1e-5)
    }

    func testCosineSimilarityOppositeVectors() {
        XCTAssertEqual(cosineSimilarity([1, 0], [-1, 0]), -1.0, accuracy: 1e-5)
    }

    func testCosineSimilarityMismatchedLengthsReturnsZero() {
        XCTAssertEqual(cosineSimilarity([1, 2], [1]), 0)
    }

    func testCosineSimilarityZeroVectorReturnsZero() {
        XCTAssertEqual(cosineSimilarity([0, 0], [1, 2]), 0)
    }

    // MARK: - Enrollment

    func testEnrollMeanAndL2Normalize() {
        let dir = tempDirectory()
        let store = VoiceProfileStore(directoryURL: dir)
        let provider = FakeEmbeddingProvider(embeddings: [[1, 0], [0, 1]])
        let gate = VoiceGate(
            profileStore: store,
            embeddingProvider: provider,
            sensitivity: .medium,
            modelId: "test-model"
        )

        let profile = gate.enroll(segments: [[Float](repeating: 0, count: 100), [Float](repeating: 0, count: 100)])
        XCTAssertNotNil(profile)
        let norm = sqrt(profile!.embedding.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 1e-4)
        // Mean of [1,0] and [0,1] → [0.5, 0.5], normalized.
        XCTAssertEqual(profile!.embedding[0], profile!.embedding[1], accuracy: 1e-4)
    }

    func testEnrollReturnsNilWhenProviderNotReady() {
        let dir = tempDirectory()
        let store = VoiceProfileStore(directoryURL: dir)
        let provider = FakeEmbeddingProvider(isReady: false, embeddings: [[1, 0]])
        let gate = VoiceGate(profileStore: store, embeddingProvider: provider, sensitivity: .medium)
        XCTAssertNil(gate.enroll(segments: [[1, 2, 3]]))
    }

    func testEnrollReturnsNilWhenNoEmbeddingsProduced() {
        let dir = tempDirectory()
        let store = VoiceProfileStore(directoryURL: dir)
        let provider = FakeEmbeddingProvider(isReady: true, embeddings: [])
        let gate = VoiceGate(profileStore: store, embeddingProvider: provider, sensitivity: .medium)
        XCTAssertNil(gate.enroll(segments: [[1, 2, 3]]))
    }

    func testEnrollReturnsNilForZeroEmbeddings() {
        let dir = tempDirectory()
        let store = VoiceProfileStore(directoryURL: dir)
        let provider = FakeEmbeddingProvider(embeddings: [[0, 0, 0]])
        let gate = VoiceGate(profileStore: store, embeddingProvider: provider, sensitivity: .medium)
        XCTAssertNil(gate.enroll(segments: [[1, 2, 3]]))
    }

    // MARK: - Threshold bands

    func testSensitivityThresholdBands() {
        let profileVector: [Float] = [1, 0]
        let queryVector: [Float] = [0.25, sqrt(1 - 0.25 * 0.25)] // similarity ≈ 0.25
        let dir = tempDirectory()
        let store = VoiceProfileStore(directoryURL: dir)
        store.save(VoiceProfile(embedding: profileVector, createdAt: Date(), modelId: "test"))
        let provider = ConstantEmbeddingProvider(isReady: true, vector: queryVector)

        let lowGate = VoiceGate(profileStore: store, embeddingProvider: provider, sensitivity: .low)
        XCTAssertEqual(lowGate.evaluate(window: [0]).decision, .pass)

        let mediumGate = VoiceGate(profileStore: store, embeddingProvider: provider, sensitivity: .medium)
        XCTAssertEqual(mediumGate.evaluate(window: [0]).decision, .attenuate)

        let highGate = VoiceGate(profileStore: store, embeddingProvider: provider, sensitivity: .high)
        XCTAssertEqual(highGate.evaluate(window: [0]).decision, .attenuate)
    }

    func testHighSensitivityPassesAtThreshold() {
        let profileVector: [Float] = [1, 0]
        let queryVector: [Float] = [0.40, sqrt(1 - 0.40 * 0.40)]
        let dir = tempDirectory()
        let store = VoiceProfileStore(directoryURL: dir)
        store.save(VoiceProfile(embedding: profileVector, createdAt: Date(), modelId: "test"))
        let provider = ConstantEmbeddingProvider(isReady: true, vector: queryVector)
        let gate = VoiceGate(profileStore: store, embeddingProvider: provider, sensitivity: .high)
        XCTAssertEqual(gate.evaluate(window: [0]).decision, .pass)
    }

    // MARK: - Fail-open evaluate branches

    func testEvaluateNoProfilePasses() {
        let dir = tempDirectory()
        let store = VoiceProfileStore(directoryURL: dir)
        let provider = ConstantEmbeddingProvider(isReady: true, vector: [1, 0])
        let gate = VoiceGate(profileStore: store, embeddingProvider: provider, sensitivity: .medium)
        XCTAssertEqual(gate.evaluate(window: [0]).decision, .pass)
    }

    func testEvaluateProviderNotReadyPasses() {
        let dir = tempDirectory()
        let store = VoiceProfileStore(directoryURL: dir)
        store.save(VoiceProfile(embedding: [1, 0], createdAt: Date(), modelId: "test"))
        let provider = ConstantEmbeddingProvider(isReady: false, vector: [1, 0])
        let gate = VoiceGate(profileStore: store, embeddingProvider: provider, sensitivity: .medium)
        XCTAssertEqual(gate.evaluate(window: [0]).decision, .pass)
    }

    func testEvaluateNilEmbeddingPasses() {
        let dir = tempDirectory()
        let store = VoiceProfileStore(directoryURL: dir)
        store.save(VoiceProfile(embedding: [1, 0], createdAt: Date(), modelId: "test"))
        let provider = ConstantEmbeddingProvider(isReady: true, vector: nil)
        let gate = VoiceGate(profileStore: store, embeddingProvider: provider, sensitivity: .medium)
        XCTAssertEqual(gate.evaluate(window: [0]).decision, .pass)
    }

    func testEvaluateLowSimilarityAttenuates() {
        let dir = tempDirectory()
        let store = VoiceProfileStore(directoryURL: dir)
        store.save(VoiceProfile(embedding: [1, 0], createdAt: Date(), modelId: "test"))
        let provider = ConstantEmbeddingProvider(isReady: true, vector: [0, 1])
        let gate = VoiceGate(profileStore: store, embeddingProvider: provider, sensitivity: .medium)
        XCTAssertEqual(gate.evaluate(window: [0]).decision, .attenuate)
    }

    func testEvaluateHighSimilarityPasses() {
        let dir = tempDirectory()
        let store = VoiceProfileStore(directoryURL: dir)
        store.save(VoiceProfile(embedding: [1, 0], createdAt: Date(), modelId: "test"))
        let provider = ConstantEmbeddingProvider(isReady: true, vector: [1, 0])
        let gate = VoiceGate(profileStore: store, embeddingProvider: provider, sensitivity: .medium)
        XCTAssertEqual(gate.evaluate(window: [0]).decision, .pass)
    }

    // MARK: - Attenuate

    func testAttenuateMultipliesSamples() {
        var samples: [Float] = [1.0, 2.0, -4.0]
        VoiceGate.attenuate(&samples)
        XCTAssertEqual(samples, [0.05, 0.10, -0.20])
    }

    // MARK: - VoiceProfileStore

    func testProfileStoreRoundTrip() {
        let dir = tempDirectory()
        let store = VoiceProfileStore(directoryURL: dir)
        let profile = VoiceProfile(embedding: [0.6, 0.8], createdAt: Date(timeIntervalSince1970: 1_000), modelId: "test")
        store.save(profile)
        let loaded = store.load()
        XCTAssertEqual(loaded, profile)
    }

    func testProfileStoreMissingFileReturnsNil() {
        let dir = tempDirectory()
        let store = VoiceProfileStore(directoryURL: dir)
        XCTAssertNil(store.load())
    }

    func testProfileStoreCorruptFileReturnsNil() {
        let dir = tempDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(VoiceProfileStore.profileFileName)
        try? Data("not-json{{{".utf8).write(to: fileURL)
        let store = VoiceProfileStore(directoryURL: dir)
        XCTAssertNil(store.load())
    }

    func testProfileStoreSaveUsesPOSIX0600() {
        let dir = tempDirectory()
        let store = VoiceProfileStore(directoryURL: dir)
        store.save(VoiceProfile(embedding: [1], createdAt: Date(), modelId: "test"))
        let fileURL = dir.appendingPathComponent(VoiceProfileStore.profileFileName)
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = (attrs?[.posixPermissions] as? NSNumber)?.uint16Value
        XCTAssertEqual(permissions, 0o600)
    }

    // MARK: - Telemetry

    private final class BlockingEmbeddingProvider: SpeakerEmbeddingProviding {
        private let gate = DispatchSemaphore(value: 0)
        private let stateLock = NSLock()
        private var _embeddingCallCount = 0
        private var _completedEmbeddingCount = 0
        var isReady = true
        var vector: [Float]

        init(vector: [Float]) {
            self.vector = vector
        }

        var embeddingCallCount: Int {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _embeddingCallCount
        }

        var completedEmbeddingCount: Int {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _completedEmbeddingCount
        }

        func embedding(for samples: [Float]) -> [Float]? {
            stateLock.lock()
            _embeddingCallCount += 1
            stateLock.unlock()
            gate.wait()
            stateLock.lock()
            _completedEmbeddingCount += 1
            stateLock.unlock()
            return vector
        }

        func unblock() {
            gate.signal()
        }
    }

    private func makeVoiceGate(
        provider: SpeakerEmbeddingProviding,
        profile: [Float] = [1, 0]
    ) -> VoiceGate {
        let dir = tempDirectory()
        let store = VoiceProfileStore(directoryURL: dir)
        store.save(VoiceProfile(embedding: profile, createdAt: Date(), modelId: "test"))
        return VoiceGate(profileStore: store, embeddingProvider: provider, sensitivity: .medium)
    }

    private func makeStreamProcessor(
        gate: VoiceGate,
        session: VoiceGateRecordingSession,
        runEvaluation: ((@escaping () -> Void) -> Void)? = nil
    ) -> VoiceGateStreamProcessor {
        VoiceGateStreamProcessor(
            gate: gate,
            recordingSession: session,
            runEvaluation: runEvaluation
        )
    }

    private func waitUntil(_ condition: () -> Bool, timeoutSeconds: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertTrue(condition(), "Timed out waiting for condition")
    }

    func testMedianSimilarityEmptyReturnsNil() {
        XCTAssertNil(medianSimilarity([]))
    }

    func testMedianSimilarityOddCount() {
        guard let median = medianSimilarity([0.1, 0.5, 0.9]) else {
            return XCTFail("Expected median")
        }
        XCTAssertEqual(median, 0.5, accuracy: 1e-5)
    }

    func testMedianSimilarityEvenCount() {
        guard let median = medianSimilarity([0.2, 0.4, 0.6, 0.8]) else {
            return XCTFail("Expected median")
        }
        XCTAssertEqual(median, 0.5, accuracy: 1e-5)
    }

    func testRecordingSessionAggregatesScoredAndUnscoredWindows() {
        let session = VoiceGateRecordingSession()
        session.begin()
        XCTAssertTrue(session.commit(
            token: 1,
            evaluation: VoiceGateEvaluation(decision: .pass, similarity: 0.8)
        ) { _ in })
        XCTAssertTrue(session.commit(
            token: 1,
            evaluation: VoiceGateEvaluation(decision: .attenuate, similarity: 0.2)
        ) { _ in })
        XCTAssertTrue(session.commit(
            token: 1,
            evaluation: VoiceGateEvaluation(decision: .pass, similarity: nil)
        ) { _ in })

        let snapshot = session.snapshot()
        XCTAssertEqual(snapshot.attemptedWindows, 3)
        XCTAssertEqual(snapshot.evaluatedWindows, 2)
        XCTAssertEqual(snapshot.passedWindows, 1)
        XCTAssertEqual(snapshot.attenuatedWindows, 1)
        XCTAssertEqual(snapshot.unscoredWindows, 1)
        XCTAssertTrue(snapshot.isSessionActive)
        if let median = snapshot.medianSimilarity {
            XCTAssertEqual(median, 0.5, accuracy: 1e-5)
        } else {
            XCTFail("Expected median similarity")
        }
    }

    func testRecordingSessionResetOnNewSession() {
        let session = VoiceGateRecordingSession()
        session.begin()
        XCTAssertTrue(session.commit(
            token: 1,
            evaluation: VoiceGateEvaluation(decision: .pass, similarity: 0.7)
        ) { _ in })
        session.begin()
        let snapshot = session.snapshot()
        XCTAssertEqual(snapshot, VoiceGateTelemetrySnapshot(
            attemptedWindows: 0,
            passedWindows: 0,
            attenuatedWindows: 0,
            unscoredWindows: 0,
            medianSimilarity: nil,
            isSessionActive: true
        ))
    }

    func testRecordingSessionRejectsStaleTokenAfterNewSession() {
        let session = VoiceGateRecordingSession()
        session.begin()
        var latch: VoiceGateDecision = .pass
        XCTAssertTrue(session.commit(
            token: 1,
            evaluation: VoiceGateEvaluation(decision: .attenuate, similarity: 0.9)
        ) { latch = $0 })
        session.begin()
        let latchBeforeStaleCommit = latch
        XCTAssertFalse(session.commit(
            token: 1,
            evaluation: VoiceGateEvaluation(decision: .pass, similarity: 0.1)
        ) { latch = $0 })
        XCTAssertEqual(latch, latchBeforeStaleCommit)
        XCTAssertEqual(session.snapshot().attemptedWindows, 0)
    }

    func testRecordingSessionEndRejectsLateCommit() {
        let session = VoiceGateRecordingSession()
        session.begin()
        var latch: VoiceGateDecision = .pass
        session.end()
        XCTAssertFalse(session.commit(
            token: 1,
            evaluation: VoiceGateEvaluation(decision: .attenuate, similarity: 0.9)
        ) { latch = $0 })
        XCTAssertFalse(session.snapshot().isSessionActive)
        XCTAssertEqual(session.snapshot().attemptedWindows, 0)
        XCTAssertEqual(latch, .pass)
    }

    func testProcessorActiveEvalCommitsLatchAndStats() {
        let session = VoiceGateRecordingSession()
        let gate = makeVoiceGate(provider: ConstantEmbeddingProvider(isReady: true, vector: [0, 1]))
        let processor = makeStreamProcessor(
            gate: gate,
            session: session,
            runEvaluation: { $0() }
        )

        processor.beginRecordingSession()
        processor.evaluateWindowForTesting([Float](repeating: 0, count: 16_000))

        XCTAssertEqual(processor.latchedDecisionForTesting, .attenuate)
        XCTAssertEqual(session.snapshot().attemptedWindows, 1)
        XCTAssertEqual(session.snapshot().attenuatedWindows, 1)
    }

    func testProcessorRejectsStaleEvalWhenNewSessionStartsDuringEmbedding() {
        let session = VoiceGateRecordingSession()
        let blocking = BlockingEmbeddingProvider(vector: [0, 1])
        let gate = makeVoiceGate(provider: blocking)
        let processor = makeStreamProcessor(gate: gate, session: session)

        processor.beginRecordingSession()
        DispatchQueue.global(qos: .userInitiated).async {
            processor.evaluateWindowForTesting([Float](repeating: 0, count: 16_000))
        }
        waitUntil { blocking.embeddingCallCount == 1 }

        processor.beginRecordingSession()
        blocking.unblock()
        waitUntil { processor.evaluationCompletionCountForTesting == 1 }

        XCTAssertEqual(session.snapshot().attemptedWindows, 0)
        XCTAssertEqual(processor.latchedDecisionForTesting, .pass)
        XCTAssertEqual(blocking.completedEmbeddingCount, 1)
    }

    func testProcessorRejectsEvalWhenSessionEndsDuringEmbedding() {
        let session = VoiceGateRecordingSession()
        let blocking = BlockingEmbeddingProvider(vector: [0, 1])
        let gate = makeVoiceGate(provider: blocking)
        let processor = makeStreamProcessor(gate: gate, session: session)

        processor.beginRecordingSession()
        DispatchQueue.global(qos: .userInitiated).async {
            processor.evaluateWindowForTesting([Float](repeating: 0, count: 16_000))
        }
        waitUntil { blocking.embeddingCallCount == 1 }

        processor.endRecordingSession()
        blocking.unblock()
        waitUntil { processor.evaluationCompletionCountForTesting == 1 }

        XCTAssertEqual(session.snapshot().attemptedWindows, 0)
        XCTAssertFalse(session.snapshot().isSessionActive)
        XCTAssertEqual(processor.latchedDecisionForTesting, .pass)
        XCTAssertEqual(blocking.completedEmbeddingCount, 1)
    }

    func testProcessorRejectsTrailingDispatchAfterSessionEnds() {
        let session = VoiceGateRecordingSession()
        let gate = makeVoiceGate(provider: ConstantEmbeddingProvider(isReady: true, vector: [0, 1]))
        let processor = makeStreamProcessor(
            gate: gate,
            session: session,
            runEvaluation: { $0() }
        )

        processor.beginRecordingSession()
        processor.endRecordingSession()
        processor.evaluateWindowForTesting([Float](repeating: 0, count: 16_000))

        XCTAssertEqual(session.snapshot().attemptedWindows, 0)
        XCTAssertEqual(processor.latchedDecisionForTesting, .pass)
    }

    // MARK: - Session teardown independent of processor lifetime
    //
    // AudioRecorder cannot be exercised here without a live mic / TCC grant.
    // These tests hit `AudioRecorder.endGateRecordingSession` — the seam that
    // stopRecording, Focus-disable / profile-clear, and secure-input abort share.

    func testEndGateSessionWhenProcessorNilClearsActiveTelemetry() {
        let session = VoiceGateRecordingSession()
        session.begin()
        XCTAssertTrue(session.snapshot().isSessionActive)

        var publishedInactive = false
        AudioRecorder.endGateRecordingSession(
            session: session,
            processor: nil,
            onSessionEndedWithoutProcessor: {
                publishedInactive = !session.snapshot().isSessionActive
            }
        )

        XCTAssertFalse(session.snapshot().isSessionActive)
        XCTAssertTrue(publishedInactive)
    }

    func testEndGateSessionViaProcessorOnFocusDisablePath() {
        // Mid-hold Focus disable / profile clear: processor still allocated when
        // teardown runs, then dropped. Session must leave active.
        let session = VoiceGateRecordingSession()
        let gate = makeVoiceGate(provider: ConstantEmbeddingProvider(isReady: true, vector: [0, 1]))
        var processor: VoiceGateStreamProcessor? = makeStreamProcessor(
            gate: gate,
            session: session,
            runEvaluation: { $0() }
        )

        processor?.beginRecordingSession()
        XCTAssertTrue(session.snapshot().isSessionActive)

        processor?.isActive = false
        AudioRecorder.endGateRecordingSession(session: session, processor: processor)
        processor = nil

        XCTAssertFalse(session.snapshot().isSessionActive)
    }

    func testEndGateSessionOnSecureInputAbortPathClearsActive() {
        // Mirrors abortForSecureInput → endVoiceGateRecordingSession.
        let session = VoiceGateRecordingSession()
        let gate = makeVoiceGate(provider: ConstantEmbeddingProvider(isReady: true, vector: [0, 1]))
        let processor = makeStreamProcessor(
            gate: gate,
            session: session,
            runEvaluation: { $0() }
        )

        processor.beginRecordingSession()
        XCTAssertTrue(session.snapshot().isSessionActive)

        AudioRecorder.endGateRecordingSession(session: session, processor: processor)

        XCTAssertFalse(session.snapshot().isSessionActive)
    }

    func testInFlightEvalCannotCommitAfterIndependentSessionEnd() {
        // Processor still alive but session ended via the shared teardown seam
        // (nil-processor path or abort) — in-flight embedding must not mutate
        // telemetry or the latched decision.
        let session = VoiceGateRecordingSession()
        let blocking = BlockingEmbeddingProvider(vector: [0, 1])
        let gate = makeVoiceGate(provider: blocking)
        let processor = makeStreamProcessor(gate: gate, session: session)

        processor.beginRecordingSession()
        DispatchQueue.global(qos: .userInitiated).async {
            processor.evaluateWindowForTesting([Float](repeating: 0, count: 16_000))
        }
        waitUntil { blocking.embeddingCallCount == 1 }

        // Independent of processor.endRecordingSession — ends session directly
        // as when the processor was already nil'd, or via the shared helper.
        AudioRecorder.endGateRecordingSession(session: session, processor: nil)
        blocking.unblock()
        waitUntil { processor.evaluationCompletionCountForTesting == 1 }

        XCTAssertEqual(session.snapshot().attemptedWindows, 0)
        XCTAssertFalse(session.snapshot().isSessionActive)
        XCTAssertEqual(processor.latchedDecisionForTesting, .pass)
        XCTAssertEqual(blocking.completedEmbeddingCount, 1)
    }

    // MARK: - Mic-start gate session lifecycle
    //
    // AudioRecorder owns AVAudioEngine with no DI — these tests hit the static
    // seams production uses for begin-if-wanted and end-on-engine-failure.

    func testEngineStartFailureEndsGateSessionBegunForMicCapture() {
        // Mirrors startMicCapture: beginRecordingSession, then engine.start()
        // throws → endVoiceGateRecordingSession. Without the catch end, the
        // session would stay active (Settings "listening…" forever).
        let session = VoiceGateRecordingSession()
        let gate = makeVoiceGate(provider: ConstantEmbeddingProvider(isReady: true, vector: [0, 1]))
        let processor = makeStreamProcessor(
            gate: gate,
            session: session,
            runEvaluation: { $0() }
        )

        let began = AudioRecorder.beginGateRecordingSessionIfWanted(
            wantsRecording: true,
            isStopping: false,
            begin: { processor.beginRecordingSession() }
        )
        XCTAssertTrue(began)
        XCTAssertTrue(session.snapshot().isSessionActive)

        AudioRecorder.endGateRecordingSession(session: session, processor: processor)

        XCTAssertFalse(session.snapshot().isSessionActive)
    }

    func testLateMicStartAfterReleaseDoesNotBeginGateSession() {
        // Race: stopRecording cleared wantsRecording and ended the session;
        // a late doStart/startMicCapture must not re-begin.
        let session = VoiceGateRecordingSession()
        session.begin()
        session.end()
        XCTAssertFalse(session.snapshot().isSessionActive)

        var beginCalled = false
        let began = AudioRecorder.beginGateRecordingSessionIfWanted(
            wantsRecording: false,
            isStopping: false,
            begin: {
                beginCalled = true
                session.begin()
            }
        )

        XCTAssertFalse(began)
        XCTAssertFalse(beginCalled)
        XCTAssertFalse(session.snapshot().isSessionActive)
    }

    func testRapidRepressMicStartNotVetoedByStickyIsStopping() {
        // Models event-tap + main FIFO without AVAudioEngine / TCC:
        // 1. Release: wantsRecording=false; queue doStop (sets isStopping=true)
        // 2. Immediate re-press: wantsRecording=true, isStopping=false; queue doStart
        // 3. Main drains FIFO: doStop runs first → isStopping sticky true
        // 4. doStart / startMicCapture for the new hold must still proceed
        //
        // Pre-fix consulted `!isStopping` and would return false at step 4
        // (silent drop: no Tink, no HUD, no mic).
        var wantsRecording = true
        var isStopping = false

        // Event-tap: release
        wantsRecording = false
        // Event-tap: immediate re-press (startRecording) before main drains
        wantsRecording = true
        isStopping = false

        // Main FIFO: prior hold's doStop runs first
        isStopping = true

        // Bug condition present: still-wanted hold + sticky isStopping
        XCTAssertTrue(wantsRecording)
        XCTAssertTrue(isStopping)

        XCTAssertTrue(
            AudioRecorder.shouldProceedWithRecordingStart(
                wantsRecording: wantsRecording,
                isStopping: isStopping
            ),
            "sticky isStopping from prior doStop must not veto a still-wanted hold"
        )

        let session = VoiceGateRecordingSession()
        var beginCalled = false
        let began = AudioRecorder.beginGateRecordingSessionIfWanted(
            wantsRecording: wantsRecording,
            isStopping: isStopping,
            begin: {
                beginCalled = true
                session.begin()
            }
        )

        XCTAssertTrue(began)
        XCTAssertTrue(beginCalled)
        XCTAssertTrue(session.snapshot().isSessionActive)
        // isStopping remains sticky until doStart clears it — proceed must
        // not have required !isStopping.
        XCTAssertTrue(isStopping)
    }

    func testEvaluateRecordsSimilarityOnlyWhenScored() {
        let dir = tempDirectory()
        let store = VoiceProfileStore(directoryURL: dir)
        store.save(VoiceProfile(embedding: [1, 0], createdAt: Date(), modelId: "test"))
        let provider = ConstantEmbeddingProvider(isReady: true, vector: [1, 0])
        let gate = VoiceGate(profileStore: store, embeddingProvider: provider, sensitivity: .medium)

        let scored = gate.evaluate(window: [0])
        XCTAssertEqual(scored.decision, .pass)
        if let similarity = scored.similarity {
            XCTAssertEqual(similarity, 1.0, accuracy: 1e-5)
        } else {
            XCTFail("Expected scored similarity")
        }

        let notReadyGate = VoiceGate(
            profileStore: store,
            embeddingProvider: ConstantEmbeddingProvider(isReady: false, vector: [1, 0]),
            sensitivity: .medium
        )
        let unscored = notReadyGate.evaluate(window: [0])
        XCTAssertEqual(unscored.decision, .pass)
        XCTAssertNil(unscored.similarity)
    }
}
