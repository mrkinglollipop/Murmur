import XCTest
@testable import Voice

/// Accidental-tap discard and the processing-HUD watchdog. A fn tap released
/// almost immediately used to leave "Transcribing…" up for 15-20 s (batch
/// upload + local fallback) with no History row.
final class StuckProcessingHUDTests: XCTestCase {

    // MARK: - Cloud silence versus failure

    func testOnlyExplicitEmptyResponsesAreClassifiedAsEmpty() {
        XCTAssertTrue(CloudTranscriptionError.emptyTranscript(provider: .elevenLabs).isEmptyTranscript)
        XCTAssertFalse(CloudTranscriptionError.httpStatus(500, provider: .elevenLabs).isEmptyTranscript)
        XCTAssertFalse(CloudTranscriptionError(provider: .elevenLabs, message: "Decode failed").isEmptyTranscript)
        for provider in [CloudProvider.gemini, .meta] {
            XCTAssertFalse(CloudTranscriptionError(provider: provider, message: "No transcript in response").isEmptyTranscript)
        }
    }

    func testElevenLabsEmptyTextIsEmptyTranscript() {
        XCTAssertThrowsError(try ElevenLabsTranscriptionService.decodeTranscript(
            from: Data(#"{"text":""}"#.utf8))) { error in
            XCTAssertEqual((error as? CloudTranscriptionError)?.isEmptyTranscript, true)
            XCTAssertEqual((error as? CloudTranscriptionError)?.provider, .elevenLabs)
            XCTAssertEqual(error.localizedDescription, "ElevenLabs: No transcript in response")
        }
    }

    func testElevenLabsWhitespaceTextIsEmptyTranscript() {
        XCTAssertThrowsError(try ElevenLabsTranscriptionService.decodeTranscript(
            from: Data(#"{"text":" \t\r\n "}"#.utf8))) { error in
            XCTAssertEqual((error as? CloudTranscriptionError)?.isEmptyTranscript, true)
        }
    }

    func testElevenLabsMalformedResponseStillFallsBack() {
        for json in ["not JSON", "{}", #"{"text":null}"#, #"{"text":42}"#] {
            XCTAssertThrowsError(try ElevenLabsTranscriptionService.decodeTranscript(
                from: Data(json.utf8))) { error in
                XCTAssertEqual((error as? CloudTranscriptionError)?.isEmptyTranscript, false)
            }
        }
    }

    func testElevenLabsValidTextIsPreserved() throws {
        XCTAssertEqual(try ElevenLabsTranscriptionService.decodeTranscript(
            from: Data(#"{"text":" Hello there.\n"}"#.utf8)), " Hello there.\n")
    }

    private struct EmptyCloud: CloudTranscriptionService {
        var response: Result<String, Error>? = nil
        func transcribe(audioURL: URL, apiKey: String, model: CloudModel, language: String) async throws -> String {
            if let response { return try response.get() }
            // Exercise the decoder that classifies a successful empty response.
            let data = Data(#"{"text":""}"#.utf8)
            if model == .xaiGrokSTT { return try XAITranscriptionService.decodeTranscript(from: data) }
            return try ElevenLabsTranscriptionService.decodeTranscript(from: data)
        }
    }

    private struct LocalStub: ASREngine {
        let id = "local-stub"
        let displayName = "Local stub"
        let run: (URL) async throws -> String
        func transcribe(audioURL: URL) async throws -> String { try await run(audioURL) }
    }

    private actor RecoveryGate {
        private var continuation: CheckedContinuation<String, Error>?
        private var result: Result<String, Error>?

        func value() async throws -> String {
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }

        func resolve(_ result: Result<String, Error>) {
            self.result = result
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    @MainActor
    private func assertBackgroundRecovery(
        cloud: EmptyCloud = EmptyCloud(),
        model: CloudModel = .elevenLabsScribeV2Realtime,
        localResult: Result<String, Error> = .success("Recovered speech."),
        temporary: Bool = false,
        expectFailure: Bool = false
    ) throws {
        let selector = ASREngineSelector()
        selector.cloudModel = model
        selector.apiKeyProvider = { _ in "dummy-test-key" }
        let pipeline = selector.pipeline
        pipeline.cloudServiceProvider = { _ in cloud }
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let gate = RecoveryGate()
        let started = expectation(description: "local recovery started after HUD release")
        let done = expectation(description: "batch recovery completed")
        var localCalls = 0
        var releases = 0
        var completions = 0
        pipeline.localEngineProvider = {
            LocalStub { url in
                XCTAssertEqual(try Data(contentsOf: url), bytes)
                await MainActor.run {
                    localCalls += 1
                    XCTAssertEqual(releases, 1, "HUD release must precede local inference")
                    started.fulfill()
                }
                let text = try await gate.value()
                XCTAssertEqual(try Data(contentsOf: url), bytes, "Audio must survive HUD dismissal")
                return text
            }
        }
        var saved: [(String, String?)] = []
        var failedPaths: [String?] = []
        pipeline.onAbandonedHoldSaved = { text, engine, path in
            XCTAssertEqual(engine, "local-stub")
            saved.append((text, path))
        }
        pipeline.onTranscriptionLogged = { text, engine, inserted, path, failed, replacement in
            XCTAssertTrue(expectFailure)
            XCTAssertEqual(text, "")
            XCTAssertEqual(engine, "local-stub")
            XCTAssertFalse(inserted)
            XCTAssertTrue(failed)
            XCTAssertNil(replacement)
            failedPaths.append(path)
        }
        pipeline.onFailure = { _ in XCTFail("Background recovery must remain quiet") }
        pipeline.onTextInserted = { _ in XCTFail("Background recovery must never insert") }
        let token = pipeline.test_holdSnapshot(.unknown)
        pipeline.transcribeAndLog(
            audioURL: audio, audioIsTemporary: temporary, sessionHeldToken: token,
            onHoldAbandoned: {
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertTrue(pipeline.test_abandonedHoldTokens.contains(token))
                XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
                releases += 1
            }
        ) { result in
            XCTAssertEqual(result, expectFailure ? .failed : .savedToHistory)
            completions += 1
            if temporary { try? FileManager.default.removeItem(at: audio) }
            done.fulfill()
        }
        wait(for: [started], timeout: 5)
        XCTAssertEqual(completions, 0, "HUD release is not terminal audio cleanup")
        // A newer hold owns focus; evict the old watchdog marker as well.
        for _ in 0..<10 {
            let newer = pipeline.test_holdSnapshot(.unknown)
            pipeline.markHoldAbandoned(newer)
        }
        let newerToken = pipeline.test_heldCaretToken
        XCTAssertFalse(pipeline.test_abandonedHoldTokens.contains(token))
        Task { await gate.resolve(localResult) }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(localCalls, 1)
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(pipeline.test_heldCaretToken, newerToken)
        XCTAssertNotNil(pipeline.test_heldCaretSnapshot, "Recovery cannot clear a newer hold")
        if expectFailure {
            XCTAssertTrue(saved.isEmpty)
            XCTAssertEqual(failedPaths.count, 1)
            XCTAssertEqual(failedPaths.first ?? nil, temporary ? nil : audio.path)
        } else {
            XCTAssertEqual(saved.map { $0.0 }, ["Recovered speech."])
            XCTAssertEqual(saved.first?.1, temporary ? nil : audio.path)
            XCTAssertTrue(failedPaths.isEmpty)
        }
    }

    @MainActor
    func testEmptyCloudRecoversToHistoryThroughBatchPipeline() throws {
        try assertBackgroundRecovery()
    }

    @MainActor
    func testXAIEmptyCloudRecoversToHistory() throws {
        try assertBackgroundRecovery(model: .xaiGrokSTT)
    }

    @MainActor
    func testSuccessfulWhitespaceResponseAlsoRecoversInBackground() throws {
        try assertBackgroundRecovery(cloud: EmptyCloud(response: .success(" \n\t")))
    }

    @MainActor
    func testEmptyLocalRecoveryRecordsFailedRowQuietly() throws {
        try assertBackgroundRecovery(localResult: .success(" \n"), expectFailure: true)
    }

    @MainActor
    func testFailedLocalRecoveryRecordsFailedRowQuietly() throws {
        try assertBackgroundRecovery(localResult: .failure(URLError(.cannotDecodeRawData)), expectFailure: true)
    }

    @MainActor
    func testTemporaryAudioSurvivesBackgroundRecoveryUntilCompletion() throws {
        try assertBackgroundRecovery(temporary: true)
    }

    @MainActor
    func testEmptyLocalRecoveryWithoutRetainedAudioStillRecordsFailedRow() throws {
        try assertBackgroundRecovery(localResult: .success(""), temporary: true, expectFailure: true)
    }

    @MainActor
    func testEmptyCloudRecoversVoiceEditInstructionBeforeTransform() {
        let selector = ASREngineSelector()
        selector.cloudModel = .elevenLabsScribeV2Realtime
        selector.apiKeyProvider = { _ in "dummy-test-key" }
        let pipeline = selector.pipeline
        pipeline.cloudServiceProvider = { _ in EmptyCloud() }
        var localCalls = 0
        var instructions: [String] = []
        pipeline.localEngineProvider = {
            LocalStub { _ in
                await MainActor.run { localCalls += 1 }
                return "Make this shorter"
            }
        }
        pipeline.runVoiceEditTransform = { instruction, selection, _ in
            instructions.append(instruction)
            XCTAssertEqual(selection, "Selected words")
            throw TransformRunnerError.emptyResponse
        }
        let snapshot = CaretContext.Snapshot(
            value: "Selected words", location: 0, selectionLength: .readable(14),
            precedingChar: .startOfField, isUnknown: false
        )
        let token = pipeline.test_holdVoiceEditSnapshot(snapshot)
        var failures: [DictationFailure] = []
        pipeline.onFailure = { failures.append($0) }
        pipeline.onTranscriptionLogged = { _, _, _, _, _, _ in XCTFail("Failed edits do not create dictation rows") }
        let done = expectation(description: "voice edit recovery completed")
        pipeline.transcribeAndLog(
            audioURL: URL(fileURLWithPath: "/unused-stub-audio.caf"), audioIsTemporary: true,
            sessionHeldToken: token, sessionHeldSnapshot: snapshot
        ) { result in
            XCTAssertEqual(result, .failed)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(localCalls, 1)
        XCTAssertEqual(instructions, ["Make this shorter"])
        XCTAssertEqual(failures, [.voiceEditFailed])
        XCTAssertTrue(pipeline.test_abandonedHoldTokens.isEmpty)
    }

    @MainActor
    func testVoiceEditStillFailsWhenLocalInstructionIsEmpty() throws {
        let selector = ASREngineSelector()
        selector.cloudModel = .elevenLabsScribeV2Realtime
        selector.apiKeyProvider = { _ in "dummy-test-key" }
        let pipeline = selector.pipeline
        pipeline.cloudServiceProvider = { _ in EmptyCloud() }
        pipeline.localEngineProvider = { LocalStub { _ in "" } }
        pipeline.runVoiceEditTransform = { _, _, _ in
            XCTFail("Empty instructions must not transform the selection")
            return "Unused"
        }
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        try Data([1, 2, 3]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let snapshot = CaretContext.Snapshot(
            value: "Selected words", location: 0, selectionLength: .readable(14),
            precedingChar: .startOfField, isUnknown: false
        )
        let token = pipeline.test_holdVoiceEditSnapshot(snapshot)
        var failures: [DictationFailure] = []
        pipeline.onFailure = { failures.append($0) }
        pipeline.onTranscriptionLogged = { _, _, _, _, _, _ in XCTFail("Failed edits do not create dictation rows") }
        pipeline.onVoiceEditLogged = { _, _, _, _, _ in XCTFail("An empty instruction is not an edit") }
        let done = expectation(description: "empty edit completed")
        pipeline.transcribeAndLog(
            audioURL: audio, sessionHeldToken: token, sessionHeldSnapshot: snapshot,
            onHoldAbandoned: { XCTFail("Empty voice edits preserve normal failure feedback") }
        ) { result in
            XCTAssertEqual(result, .failed)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(failures, [.voiceEditFailed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertFalse(pipeline.isVoiceEditHold(token))
    }

    @MainActor
    func testEmptyCloudHistoryRetryRecoversWithoutAbandoningLiveHold() {
        let selector = ASREngineSelector()
        selector.cloudModel = .elevenLabsScribeV2Realtime
        selector.apiKeyProvider = { _ in "dummy-test-key" }
        let pipeline = selector.pipeline
        pipeline.cloudServiceProvider = { _ in EmptyCloud() }
        pipeline.localEngineProvider = { LocalStub { _ in "Recovered speech." } }
        let token = pipeline.test_holdSnapshot(.unknown)
        let replacement = UUID()
        var rows = 0
        pipeline.onTranscriptionLogged = { text, _, inserted, _, failed, id in
            XCTAssertEqual(text, "Recovered speech.")
            XCTAssertFalse(inserted)
            XCTAssertFalse(failed)
            XCTAssertEqual(id, replacement)
            rows += 1
        }
        pipeline.onAbandonedHoldSaved = { _, _, _ in XCTFail("Retries replace their own History row") }
        let done = expectation(description: "history retry completed")
        pipeline.transcribeAndLog(
            audioURL: URL(fileURLWithPath: "/unused-stub-audio.caf"), audioIsTemporary: true,
            replaceHistoryEntryID: replacement, sessionHeldToken: token,
            onHoldAbandoned: { XCTFail("History retries must not dismiss a live hold") }
        ) { result in
            XCTAssertEqual(result, .savedToHistory)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(rows, 1)
        XCTAssertTrue(pipeline.test_abandonedHoldTokens.isEmpty)
        XCTAssertNotNil(pipeline.test_heldCaretSnapshot)
    }

    @MainActor
    func testCloudTransportFailureKeepsNormalLocalRecovery() {
        let selector = ASREngineSelector()
        selector.cloudModel = .elevenLabsScribeV2Realtime
        selector.apiKeyProvider = { _ in "dummy-test-key" }
        let pipeline = selector.pipeline
        pipeline.cloudServiceProvider = { _ in EmptyCloud(response: .failure(URLError(.timedOut))) }
        var localCalls = 0
        pipeline.localEngineProvider = {
            LocalStub { _ in
                await MainActor.run { localCalls += 1 }
                return ""
            }
        }
        var failures: [DictationFailure] = []
        pipeline.onFailure = { failures.append($0) }
        let done = expectation(description: "foreground recovery completed")
        pipeline.transcribeAndLog(
            audioURL: URL(fileURLWithPath: "/unused-stub-audio.caf"), audioIsTemporary: true,
            sessionHeldToken: pipeline.test_holdSnapshot(.unknown),
            onHoldAbandoned: { XCTFail("Transport failure is not empty cloud success") }
        ) { result in
            XCTAssertEqual(result, .failed)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(localCalls, 1)
        XCTAssertEqual(failures, [.transcriptionFailed])
    }

    // MARK: - Accidental tap

    func testAccidentalTapTruthTable() {
        // (holdDuration, streamTextEver) -> discard
        XCTAssertTrue(AudioRecorder.shouldDiscardAccidentalTap(holdDuration: 0.0, streamTextEver: false))
        XCTAssertTrue(AudioRecorder.shouldDiscardAccidentalTap(holdDuration: 0.12, streamTextEver: false))
        XCTAssertTrue(AudioRecorder.shouldDiscardAccidentalTap(holdDuration: 0.299, streamTextEver: false))
        // Boundary is exclusive: a 0.3 s hold is a real (if short) hold.
        XCTAssertFalse(AudioRecorder.shouldDiscardAccidentalTap(holdDuration: 0.3, streamTextEver: false))
        XCTAssertFalse(AudioRecorder.shouldDiscardAccidentalTap(holdDuration: 1.5, streamTextEver: false))
        // Any stream text means speech landed — never discard.
        XCTAssertFalse(AudioRecorder.shouldDiscardAccidentalTap(holdDuration: 0.12, streamTextEver: true))
        XCTAssertFalse(AudioRecorder.shouldDiscardAccidentalTap(holdDuration: 1.5, streamTextEver: true))
        // Unknown duration (mic never started) is left to the failure paths.
        XCTAssertFalse(AudioRecorder.shouldDiscardAccidentalTap(holdDuration: nil, streamTextEver: false))
        XCTAssertFalse(AudioRecorder.shouldDiscardAccidentalTap(holdDuration: nil, streamTextEver: true))
    }

    /// The post-release grace inflates buffered audio past the silence guard's
    /// floor, so the tap decision must sit below the grace, not include it.
    func testAccidentalTapThresholdIsBelowPostReleaseGrace() {
        XCTAssertLessThan(
            AudioRecorder.accidentalTapMaxHoldSeconds,
            AudioRecorder.postReleaseCaptureGraceForTesting
        )
    }

    // MARK: - Watchdog bound

    func testWatchdogBoundScalesWithAudioDuration() {
        XCTAssertEqual(AudioRecorder.processingHUDWatchdogBound(audioDuration: 0), 20, accuracy: 0.001)
        XCTAssertEqual(AudioRecorder.processingHUDWatchdogBound(audioDuration: 5), 25, accuracy: 0.001)
        XCTAssertEqual(AudioRecorder.processingHUDWatchdogBound(audioDuration: 90), 110, accuracy: 0.001)
    }

    func testWatchdogBoundIgnoresNonsenseDurations() {
        XCTAssertEqual(AudioRecorder.processingHUDWatchdogBound(audioDuration: -4), 20, accuracy: 0.001)
        XCTAssertEqual(AudioRecorder.processingHUDWatchdogBound(audioDuration: .nan), 20, accuracy: 0.001)
        XCTAssertEqual(AudioRecorder.processingHUDWatchdogBound(audioDuration: .infinity), 20, accuracy: 0.001)
    }

    // MARK: - Watchdog firing

    func testWatchdogFiresOnlyForCurrentGenerationWhileProcessing() {
        XCTAssertTrue(AudioRecorder.shouldFireProcessingWatchdog(
            generation: 4, currentGeneration: 4, hudIsProcessing: true))
        // Cancelled on normal completion / superseded by a newer hold.
        XCTAssertFalse(AudioRecorder.shouldFireProcessingWatchdog(
            generation: 4, currentGeneration: 5, hudIsProcessing: true))
        // HUD already left processing (failure pill, success, newer hold).
        XCTAssertFalse(AudioRecorder.shouldFireProcessingWatchdog(
            generation: 4, currentGeneration: 4, hudIsProcessing: false))
    }

    // MARK: - Abandoned hold reaches History without insertion

    private struct Logged {
        let text: String
        let injected: Bool
        let failed: Bool
        let replaceID: UUID?
    }

    private func finish(
        pipeline: TranscriptionPipeline,
        text: String,
        token: UInt64,
        replaceID: UUID? = nil
    ) -> (result: TranscriptionPipeline.InjectPipelineResult, logged: [Logged], failures: Int) {
        var logged: [Logged] = []
        var failures = 0
        pipeline.onTranscriptionLogged = { text, _, injected, _, failed, replaceID in
            logged.append(Logged(text: text, injected: injected, failed: failed, replaceID: replaceID))
        }
        pipeline.onFailure = { _ in failures += 1 }
        let done = expectation(description: "pipeline completion")
        var result: TranscriptionPipeline.InjectPipelineResult = .failed
        pipeline.finishTranscription(
            text: text,
            hadExplicitTrailingNewline: false,
            engineID: "test",
            audioPath: nil,
            replaceHistoryEntryID: replaceID,
            sessionHeldToken: token,
            sessionHeldSnapshot: nil,
            sessionHeldFrontmostPID: nil
        ) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return (result, logged, failures)
    }

    func testAbandonedHoldIsSavedToHistoryWithoutInsertion() {
        let pipeline = TranscriptionPipeline()
        pipeline.markHoldAbandoned(42)
        let out = finish(pipeline: pipeline, text: "late result", token: 42)
        XCTAssertEqual(out.result, .savedToHistory)
        XCTAssertEqual(out.logged.count, 1)
        XCTAssertEqual(out.logged.first?.text, "late result")
        XCTAssertEqual(out.logged.first?.injected, false)
        XCTAssertEqual(out.logged.first?.failed, false)
        XCTAssertNil(out.logged.first?.replaceID)
        XCTAssertEqual(out.failures, 0)
        XCTAssertTrue(pipeline.test_abandonedHoldTokens.isEmpty, "abandonment is one-shot")
    }

    func testAbandonedHoldUsesDedicatedHistoryHookWhenWired() {
        let pipeline = TranscriptionPipeline()
        var saved: [(text: String, engine: String)] = []
        pipeline.onAbandonedHoldSaved = { text, engine, _ in saved.append((text, engine)) }
        pipeline.markHoldAbandoned(9)
        let out = finish(pipeline: pipeline, text: "late result", token: 9)
        XCTAssertEqual(out.result, .savedToHistory)
        XCTAssertEqual(saved.map(\.text), ["late result"])
        XCTAssertTrue(out.logged.isEmpty, "the generic hook would label the row as left on the clipboard")
    }

    func testAbandonedHoldWithEmptyResultRaisesNoLateErrorPill() {
        let pipeline = TranscriptionPipeline()
        pipeline.markHoldAbandoned(7)
        let out = finish(pipeline: pipeline, text: "   ", token: 7)
        XCTAssertEqual(out.result, .failed)
        XCTAssertEqual(out.failures, 0)
        XCTAssertTrue(pipeline.test_abandonedHoldTokens.isEmpty)
    }

    func testRetryNeverConsumesAbandonment() {
        let pipeline = TranscriptionPipeline()
        pipeline.markHoldAbandoned(9)
        let retryID = UUID()
        let out = finish(pipeline: pipeline, text: "retried", token: 9, replaceID: retryID)
        XCTAssertEqual(out.result, .savedToHistory)
        XCTAssertEqual(out.logged.first?.replaceID, retryID)
        XCTAssertEqual(pipeline.test_abandonedHoldTokens, [9])
    }

    func testAbandonedTokenSetIsCapped() {
        let pipeline = TranscriptionPipeline()
        for token in 1 ... 40 { pipeline.markHoldAbandoned(UInt64(token)) }
        XCTAssertLessThanOrEqual(pipeline.test_abandonedHoldTokens.count, 8)
        XCTAssertTrue(pipeline.test_abandonedHoldTokens.contains(40), "newest hold is kept")
    }
}
