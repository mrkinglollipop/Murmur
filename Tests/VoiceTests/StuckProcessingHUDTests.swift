import AVFoundation
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

    func test01UnstartedReplacementCannotRetargetPendingGrace() {
        let grace = AudioRecorder.StopGrace()
        var deliveries: [(UInt64, Int32)] = []
        let timerA = grace.schedule { deliveries.append((1, 101)) }
        if AudioRecorder.shouldSettleStopGrace(at: .request) { grace.flush() }
        var slots = AudioRecorder.heldCaretTokensAtStartRequest(active: 1, pending: 2)
        // B releases before its queued start; the skipped start clears B.
        slots.pending = nil
        if let sampled = AudioRecorder.preferredSessionHoldToken(active: slots.active, pending: slots.pending) {
            grace.schedule { deliveries.append((sampled, 202)) }
        }
        grace.run(timerA)
        grace.run(grace.generation)
        grace.flush()
        XCTAssertEqual(deliveries.map { $0.0 }, [1])
        XCTAssertEqual(deliveries.map { $0.1 }, [101], "B must not redirect A into app Y")
    }

    func test02OldCompletionCannotHideNewListeningOrProcessingHold() {
        for processing in [false, true] {
            for result: TranscriptionPipeline.InjectPipelineResult in [.inserted, .savedToHistory, .deduped, .failed] {
                var state: RecordingHUD.State = processing ? .processing : .listening
                var visible = true
                var hideCallbacks = 0
                var hideTimer: (() -> Void)?
                switch RecordingHUD.pipelineCompletionAction(result: result, token: 1, owner: 2, isProcessing: processing) {
                case .success:
                    state = .success
                    hideTimer = { visible = false; hideCallbacks += 1 }
                case .hide:
                    visible = false
                    hideCallbacks += 1
                case .none: break
                }
                hideTimer?()
                XCTAssertEqual(state, processing ? .processing : .listening)
                XCTAssertTrue(visible)
                XCTAssertEqual(hideCallbacks, 0, "A must not reset B's menu icon")
            }
        }
    }

    @MainActor
    func test03OldTransformFailureCannotDisarmNewEditsDeadline() {
        let pipeline = TranscriptionPipeline()
        let held = CaretContext.Snapshot(value: "Old words here.", location: 0,
            selectionLength: .readable(15), precedingChar: .startOfField, isUnknown: false)
        let tokenA = pipeline.test_holdVoiceEditSnapshot(held, frontmostPID: 101)
        var tokenB: UInt64 = 0
        var state: RecordingHUD.State = .processing
        var failures = 0
        var inserted = 0
        var saved = 0
        pipeline.onFailure = { _ in failures += 1; state = .error("Try rephrasing") }
        pipeline.voiceEditInjectionHooks = .init(
            target: { .init(secureInput: false, pid: 101, bundleIdentifier: "fixture") },
            snapshot: { held }, insert: { _ in inserted += 1; return .inserted(deliveredText: "New words here.") },
            leaveOnClipboard: { _ in XCTFail("Timed-out edit must be History-only") }
        )
        pipeline.onVoiceEditLogged = { _, _, _, injected, historyOnly in
            if historyOnly { saved += 1 }
            XCTAssertFalse(injected)
        }
        pipeline.runVoiceEditTransform = { _, _, _ in
            await MainActor.run {
                tokenB = pipeline.test_holdVoiceEditSnapshot(held, frontmostPID: 101)
                state = .processing
            }
            throw TransformRunnerError.emptyResponse
        }
        let failedA = expectation(description: "A's pending transform fails after B releases")
        pipeline.finishTranscription(text: "rewrite this", hadExplicitTrailingNewline: false,
            engineID: "fixture", audioPath: nil, replaceHistoryEntryID: nil,
            sessionHeldToken: tokenA, sessionHeldSnapshot: held, sessionHeldFrontmostPID: 101,
            completion: { XCTAssertEqual($0, .failed); failedA.fulfill() })
        wait(for: [failedA], timeout: 5)
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(state, .processing)
        if AudioRecorder.shouldFireProcessingWatchdog(generation: 2, currentGeneration: 2,
                                                       hudIsProcessing: state == .processing) {
            pipeline.markHoldAbandoned(tokenB)
        }
        let completedB = expectation(description: "B completes after its deadline")
        pipeline.finishTranscription(text: "New words here.", hadExplicitTrailingNewline: false,
            engineID: "fixture", audioPath: nil, replaceHistoryEntryID: nil,
            sessionHeldToken: tokenB, sessionHeldSnapshot: held, sessionHeldFrontmostPID: 101,
            voiceEditInstruction: "rewrite this",
            completion: { XCTAssertEqual($0, .savedToHistory); completedB.fulfill() })
        wait(for: [completedB], timeout: 5)
        XCTAssertEqual(inserted, 0)
        XCTAssertEqual(saved, 1)
    }

    @MainActor
    func test04OldTranscriptionFailuresKeepNewHoldAndStillComplete() {
        for edit in [false, true] {
            let pipeline = TranscriptionPipeline()
            let held = CaretContext.Snapshot(value: "Old words here.", location: 0,
                selectionLength: .readable(15), precedingChar: .startOfField, isUnknown: false)
            let old = edit ? pipeline.test_holdVoiceEditSnapshot(held) : pipeline.test_holdSnapshot(held)
            let current = pipeline.test_holdSnapshot(held)
            var failures = 0
            var logs = 0
            pipeline.onFailure = { _ in failures += 1 }
            pipeline.onTranscriptionLogged = { _, _, _, _, _, _ in logs += 1 }
            let completed = expectation(description: "obsolete transcription failure completes")
            pipeline.reportTranscriptionFailure(engineID: "fixture", audioPath: nil,
                replaceHistoryEntryID: nil, sessionHeldToken: old,
                completion: { XCTAssertEqual($0, .failed); completed.fulfill() })
            wait(for: [completed], timeout: 5)
            XCTAssertEqual(failures, 0)
            XCTAssertEqual(logs, edit ? 0 : 1)
            XCTAssertEqual(pipeline.test_heldCaretToken, current)
            XCTAssertEqual(pipeline.test_heldCaretSnapshot, held)
        }
    }

    func testSettledGraceCannotFireAgainAfterNewGraceIsScheduled() {
        let grace = AudioRecorder.StopGrace()
        var finalized: [Int] = []
        let oldTimer = grace.schedule { finalized.append(1) }
        grace.flush()
        let newTimer = grace.schedule { finalized.append(2) }
        grace.run(oldTimer)
        XCTAssertEqual(finalized, [1])
        grace.run(newTimer)
        grace.run(newTimer)
        grace.flush()
        XCTAssertEqual(finalized, [1, 2])
    }

    @MainActor
    func testCurrentTranscriptionFailureStillNotifies() {
        let pipeline = TranscriptionPipeline()
        let token = pipeline.test_holdSnapshot(.unknown)
        var failures = 0
        pipeline.onFailure = { _ in failures += 1 }
        let completed = expectation(description: "current failure delivered")
        pipeline.reportTranscriptionFailure(engineID: "fixture", audioPath: nil,
            replaceHistoryEntryID: nil, sessionHeldToken: token,
            completion: { XCTAssertEqual($0, .failed); completed.fulfill() })
        wait(for: [completed], timeout: 5)
        XCTAssertEqual(failures, 1)
    }

    func testCurrentCompletionStillShowsSuccessAndHidesProcessing() {
        XCTAssertEqual(RecordingHUD.pipelineCompletionAction(
            result: .inserted, token: 2, owner: 2, isProcessing: true), .success)
        for result: TranscriptionPipeline.InjectPipelineResult in [.savedToHistory, .deduped, .failed] {
            XCTAssertEqual(RecordingHUD.pipelineCompletionAction(
                result: result, token: 2, owner: 2, isProcessing: true), .hide)
            XCTAssertEqual(RecordingHUD.pipelineCompletionAction(
                result: result, token: 2, owner: 2, isProcessing: false), .none)
        }
        XCTAssertFalse(RecordingHUD.holdOwnsPresentation(token: nil, owner: 2))
        XCTAssertFalse(RecordingHUD.holdOwnsPresentation(token: 1, owner: 2))
        XCTAssertTrue(RecordingHUD.holdOwnsPresentation(token: 2, owner: 2))
    }

    func testOldPermissionAndListeningCallbacksCannotClaimNewRequest() {
        XCTAssertFalse(AudioRecorder.isCurrentStartCallback(generation: 1, currentGeneration: 2))
        XCTAssertTrue(AudioRecorder.isCurrentStartCallback(generation: 2, currentGeneration: 2))
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

    func testWatchdogFiresOnlyForCurrentGenerationRegardlessOfPresentation() {
        XCTAssertTrue(AudioRecorder.shouldFireProcessingWatchdog(
            generation: 4, currentGeneration: 4, hudIsProcessing: true))
        // Cancelled on normal completion / superseded by a newer hold.
        XCTAssertFalse(AudioRecorder.shouldFireProcessingWatchdog(
            generation: 4, currentGeneration: 5, hudIsProcessing: true))
        // Presentation cannot disable an armed deadline; lifecycle cancellation
        // advances the generation when completion or a newer capture settles it.
        XCTAssertTrue(AudioRecorder.shouldFireProcessingWatchdog(
            generation: 4, currentGeneration: 4, hudIsProcessing: false))
    }

    // MARK: - Watchdog lifecycle

    func testAbortedStartKeepsPreviousProcessingWatchdogArmed() {
        // Secure input, denied permission, and release during the permission
        // hop all exit after a request without announcing a recording start.
        let action = AudioRecorder.processingWatchdogAction(
            for: .startRequested, hudIsProcessing: true
        )
        XCTAssertEqual(action, .keep, "A request alone must not disarm the previous hold")
        let generation: UInt64 = 4
        let currentGeneration = action == .cancel ? generation + 1 : generation
        XCTAssertTrue(AudioRecorder.shouldFireProcessingWatchdog(
            generation: generation, currentGeneration: currentGeneration, hudIsProcessing: true
        ))
    }

    func testAlreadyStoppingRefreshesProcessingWatchdog() {
        XCTAssertEqual(AudioRecorder.processingWatchdogAction(
            for: .alreadyStopping, hudIsProcessing: true
        ), .rearm, "A repeated stop must restore the processing HUD's deadline")
        XCTAssertEqual(AudioRecorder.processingWatchdogAction(
            for: .alreadyStopping, hudIsProcessing: false
        ), .keep, "A repeated stop must not arm a timer for a non-processing HUD")
    }

    func testStartedRecordingCancelsPreviousProcessingWatchdog() {
        for hudIsProcessing in [true, false] {
            XCTAssertEqual(AudioRecorder.processingWatchdogAction(
                for: .recordingStarted, hudIsProcessing: hudIsProcessing
            ), .cancel, "A confirmed recording start supersedes the previous hold's timer")
        }
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

/// Production stop, notification, and deadline paths with hardware/network I/O replaced.
final class HoldOwnershipRegressionTests: XCTestCase {
    @MainActor
    private func recorder(_ coordinator: StreamingCoordinator = StreamingCoordinator()) -> AudioRecorder {
        AudioRecorder(
            streamingCoordinator: coordinator,
            voiceProfileStore: VoiceProfileStore(directoryURL: URL(fileURLWithPath: #filePath).deletingLastPathComponent()),
            hud: RecordingHUD(presentsWindows: false),
            observeInputDevices: false
        )
    }

    @MainActor
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private final class Frames {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func record(_ message: URLSessionWebSocketTask.Message) {
            if case .data = message { lock.withLock { value += 1 } }
        }
    }

    @MainActor
    func test01EverySettledStopDetachesCloudBeforeLocalAudio() async throws {
        // Includes the early return after tearing down a re-armed in-flight start.
        for path in ["pending", "inFlight", "rearmedInFlight", "active", "secure"] {
            let frames = Frames()
            let sent = expectation(description: "connected cloud receives its own audio: \(path)")
            let session = XAIStreamingTranscriber(apiKey: "fixture", messageSender: { message in
                frames.record(message)
                if frames.count == 1 { sent.fulfill() }
            })
            session.handleServerEvent(#"{"type":"transcript.created"}"#)
            try await session.start()
            let coordinator = StreamingCoordinator(xaiSession: session)
            let recorder = recorder(coordinator)
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
            buffer.frameLength = 160
            for index in 0..<160 { buffer.floatChannelData![0][index] = 0.1 }
            let token = recorder.asrSelector.pipeline.test_holdSnapshot(.unknown)
            recorder.test_prepareHold(token: token, active: path == "active" || path == "secure",
                                      inFlight: path == "inFlight" || path == "rearmedInFlight")
            recorder.test_receiveAudio(buffer)
            await fulfillment(of: [sent], timeout: 2)
            XCTAssertEqual(frames.count, 1)
            recorder.test_bufferAudio(buffer)
            if path == "secure" {
                recorder.test_abortForSecureInput()
            } else {
                recorder.stopRecording()
                if path == "rearmedInFlight" {
                    let next = recorder.asrSelector.pipeline.test_holdSnapshot(.unknown)
                    recorder.test_prepareHold(token: next, inFlight: true)
                }
                await drainMainQueue()
                recorder.test_flushStopGrace()
                // A duplicate stop must not reattach or reuse the abandoned session.
                recorder.stopRecording()
                await drainMainQueue()
            }
            XCTAssertNil(coordinator.xaiSession, path)
            if path == "pending" || path == "inFlight" || path == "rearmedInFlight" {
                XCTAssertEqual(recorder.test_bufferCount, 0, path)
            }
            recorder.asrSelector.cloudModel = nil
            XCTAssertNil(recorder.asrSelector.makeXAIStreamingSession())
            XCTAssertNil(recorder.asrSelector.makeElevenLabsStreamingSession())
            XCTAssertNil(recorder.asrSelector.makeGeminiStreamingSession())
            XCTAssertNil(recorder.asrSelector.makeMuseStreamingSession())
            recorder.test_receiveAudio(buffer)
            // Drain the real sender before counting, so absence is not a timing assertion.
            session.handleServerEvent(#"{"type":"transcript.done"}"#)
            _ = await session.finalize()
            XCTAssertEqual(frames.count, 1, "Local audio leaked through \(path)")
            session.cancel()
        }
    }

    @MainActor
    func test02LateEmptyTranscriptCannotReplaceListeningHUD() async {
        for stale in [true, false] {
            let pipeline = TranscriptionPipeline()
            let hud = RecordingHUD(presentsWindows: false)
            let old = pipeline.test_holdSnapshot(.unknown)
            let owner = stale ? pipeline.test_holdSnapshot(.unknown) : old
            hud.claimHold(owner)
            hud.show()
            var failures = 0
            var logs = 0
            var hides = 0
            hud.onHide = { hides += 1 }
            pipeline.onFailure = { _ in failures += 1; hud.showError("Transcription failed") }
            pipeline.onTranscriptionLogged = { _, _, _, _, failed, _ in
                XCTAssertTrue(failed)
                logs += 1
            }
            let done = expectation(description: "empty transcript completes")
            pipeline.finishTranscription(text: "  ", hadExplicitTrailingNewline: false,
                engineID: "fixture", audioPath: #filePath + ".caf", replaceHistoryEntryID: nil,
                sessionHeldToken: old, sessionHeldSnapshot: nil, sessionHeldFrontmostPID: nil,
                completion: { XCTAssertEqual($0, .failed); done.fulfill() })
            await fulfillment(of: [done], timeout: 2)
            hud.test_fireAutoHideTimer()
            XCTAssertEqual(failures, stale ? 0 : 1)
            XCTAssertEqual(logs, 1)
            XCTAssertEqual(hides, stale ? 0 : 1)
            XCTAssertEqual(hud.isVisible, stale)
            if stale { XCTAssertEqual(hud.currentState, .listening) }
            hud.hide()
        }
    }

    @MainActor
    func test02LateInjectionFailureCannotReplaceListeningHUD() async {
        for stale in [true, false] {
            let pipeline = TranscriptionPipeline()
            let hud = RecordingHUD(presentsWindows: false)
            let held = CaretContext.Snapshot(value: "Old words", location: 0,
                selectionLength: .readable(9), precedingChar: .startOfField, isUnknown: false)
            let old = pipeline.test_holdSnapshot(held, frontmostPID: 101)
            hud.claimHold(old)
            hud.show()
            var failures = 0
            var logs = 0
            var inserts = 0
            var hides = 0
            hud.onHide = { hides += 1 }
            pipeline.onFailure = { _ in failures += 1; hud.showError("Injection failed") }
            pipeline.onVoiceEditLogged = { _, _, _, injected, _ in
                XCTAssertFalse(injected)
                logs += 1
            }
            pipeline.voiceEditInjectionHooks = .init(
                target: { .init(secureInput: false, pid: 101, bundleIdentifier: "fixture") },
                snapshot: { held }, insert: { _ in
                    DispatchQueue.main.sync {
                        inserts += 1
                        if stale {
                            let next = pipeline.test_holdSnapshot(.unknown)
                            hud.claimHold(next)
                            hud.show()
                        }
                    }
                    return .failed
                }, leaveOnClipboard: { _ in XCTFail("Must reach the delayed insert result") })
            let done = expectation(description: "delayed injection failure completes")
            pipeline.finishTranscription(text: "New words", hadExplicitTrailingNewline: false,
                engineID: "fixture", audioPath: nil, replaceHistoryEntryID: nil,
                sessionHeldToken: old, sessionHeldSnapshot: held, sessionHeldFrontmostPID: 101,
                voiceEditInstruction: "rewrite",
                completion: { XCTAssertEqual($0, .failed); done.fulfill() })
            await fulfillment(of: [done], timeout: 2)
            hud.test_fireAutoHideTimer()
            XCTAssertEqual(inserts, 1)
            XCTAssertEqual(logs, 1)
            XCTAssertEqual(failures, stale ? 0 : 1)
            XCTAssertEqual(hides, stale ? 0 : 1)
            XCTAssertEqual(hud.isVisible, stale)
            if stale { XCTAssertEqual(hud.currentState, .listening) }
            hud.hide()
        }
    }

    @MainActor
    func test03OlderWatchdogCannotDismissMicrophoneStartError() async {
        let recorder = recorder()
        let pipeline = recorder.asrSelector.pipeline
        let old = pipeline.test_holdSnapshot(.unknown)
        recorder.hud.claimHold(old)
        recorder.hud.show()
        recorder.hud.setProcessing()
        let deadline = recorder.test_armProcessingDeadline(token: old)
        let next = pipeline.test_holdSnapshot(.unknown)
        recorder.test_prepareHold(token: next)
        var failures = 0
        var hides = 0
        recorder.hud.onHide = { hides += 1 }
        pipeline.onFailure = { _ in failures += 1; recorder.hud.showError("Microphone failed") }
        recorder.test_failMicStart()
        await drainMainQueue()
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(recorder.hud.currentState, .error("Microphone failed"))
        deadline()
        XCTAssertTrue(pipeline.test_abandonedHoldTokens.contains(old))
        XCTAssertEqual(recorder.hud.holdToken, next)
        XCTAssertEqual(hides, 0)
        XCTAssertTrue(recorder.hud.isVisible)
        recorder.hud.test_fireAutoHideTimer()
        XCTAssertFalse(recorder.hud.isVisible, "B's own timer still dismisses its error")
        pipeline.onFailure = nil
    }

    @MainActor
    func test03SupersededQueuedMicrophoneFailureCannotClaimNewHold() async {
        let recorder = recorder()
        let pipeline = recorder.asrSelector.pipeline
        let old = pipeline.test_holdSnapshot(.unknown)
        recorder.test_prepareHold(token: old)
        var failures = 0
        pipeline.onFailure = { _ in failures += 1 }
        recorder.test_failMicStart()
        let next = pipeline.test_holdSnapshot(.unknown)
        recorder.test_prepareHold(token: next)
        recorder.hud.claimHold(next)
        recorder.hud.show()
        await drainMainQueue()
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(recorder.hud.holdToken, next)
        XCTAssertEqual(recorder.hud.currentState, .listening)
        recorder.hud.hide()
    }
}
