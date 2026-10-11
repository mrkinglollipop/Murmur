import AVFoundation
import XCTest
@testable import Voice

final class LocalTranscriptionDeadlineTests: XCTestCase {
    func testWhisperProductionPathPreservesTenMinuteRecordingDecodedInSixMinutes() async throws {
        let clock = TranscriptionTestClock(completionTime: 360)
        let engine = makeWhisperEngine(clock: clock)
        try await assertLongTranscriptSurvives(engine: engine, clock: clock)
    }

    func testAppleProductionPathPreservesTenMinuteRecordingDecodedInSixMinutes() async throws {
        let clock = TranscriptionTestClock(completionTime: 360)
        let engine = makeAppleEngine(clock: clock)
        try await assertLongTranscriptSurvives(engine: engine, clock: clock)
    }

    func testWhisperProductionPathEnforcesDecodeDeadline() async throws {
        let clock = TranscriptionTestClock(completionTime: 2_401)
        let engine = makeWhisperEngine(clock: clock)
        try await assertProductionTimeout(engine: engine, clock: clock)
    }

    func testAppleProductionPathEnforcesDecodeDeadline() async throws {
        let clock = TranscriptionTestClock(completionTime: 2_401)
        let engine = makeAppleEngine(clock: clock)
        try await assertProductionTimeout(engine: engine, clock: clock)
    }

    private func makeWhisperEngine(clock: TranscriptionTestClock) -> WhisperKitEngine {
        WhisperKitEngine(
            modelID: "offline-test", displayName: "Whisper test", localModel: .default,
            transcribeAudio: { _, language in
                XCTAssertEqual(language, "en")
                return try await clock.completeDecode()
            },
            deadline: { seconds, name, operation in
                try await clock.run(seconds: seconds, engineName: name, operation: operation)
            }
        )
    }

    private func makeAppleEngine(clock: TranscriptionTestClock) -> AppleSpeechEngine {
        AppleSpeechEngine(
            transcribeAudio: { audioFile, language in
                XCTAssertEqual(Double(audioFile.length) / audioFile.processingFormat.sampleRate, 600)
                XCTAssertEqual(language, "en")
                return try await clock.completeDecode()
            },
            deadline: { seconds, name, operation in
                try await clock.run(seconds: seconds, engineName: name, operation: operation)
            }
        )
    }

    private func assertLongTranscriptSurvives(
        engine: ASREngine, clock: TranscriptionTestClock
    ) async throws {
        let audioURL = try makeTenMinuteAudio()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        do {
            let text = try await engine.transcribe(audioURL: audioURL)
            XCTAssertEqual(text, "Recognized speech.")
        } catch {
            XCTFail("A six-minute decode of ten-minute audio must survive: \(error)")
        }
        let scheduledSeconds = await clock.scheduledSeconds
        XCTAssertEqual(scheduledSeconds, 2_400, "The production engine must apply the scaled deadline")
    }

    private func assertProductionTimeout(
        engine: ASREngine, clock: TranscriptionTestClock
    ) async throws {
        let audioURL = try makeTenMinuteAudio()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        do {
            _ = try await engine.transcribe(audioURL: audioURL)
            XCTFail("The production engine must reject a decode beyond its deadline")
        } catch let error as LocalTranscriptionTimeout {
            XCTAssertEqual(error.engineName, engine.displayName)
            XCTAssertEqual(error.seconds, 2_400)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let scheduledSeconds = await clock.scheduledSeconds
        XCTAssertEqual(scheduledSeconds, 2_400, "Removing the production deadline wrapper must fail this test")
    }

    private func makeTenMinuteAudio() throws -> URL {
        let worktree = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = worktree.appendingPathComponent(".deadline-audio-\(UUID().uuidString).caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.initialize(repeating: 0.25, count: Int(buffer.frameLength))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    func testShortRecordingsUseFloor() {
        for duration in [TimeInterval(0), 0.1, 1, 7.5] {
            XCTAssertEqual(LocalTranscriptionDeadline.seconds(forAudioDuration: duration), 30)
        }
    }

    func testBudgetScalesWithAudioLength() {
        XCTAssertEqual(LocalTranscriptionDeadline.seconds(forAudioDuration: 10), 40)
        XCTAssertEqual(LocalTranscriptionDeadline.seconds(forAudioDuration: 30), 120)
        XCTAssertEqual(LocalTranscriptionDeadline.seconds(forAudioDuration: 60), 240)
    }

    func testLongRecordingsKeepProportionalBudget() {
        for duration in [TimeInterval(75), 300, 600, 3_600, 10_800, 21_600] {
            XCTAssertEqual(LocalTranscriptionDeadline.seconds(forAudioDuration: duration), duration * 4)
        }
    }

    func testExtremeDurationsUseTwentyFourHourEmergencyCeiling() {
        for duration in [TimeInterval(86_400), .greatestFiniteMagnitude, .infinity] {
            XCTAssertEqual(LocalTranscriptionDeadline.seconds(forAudioDuration: duration), 86_400)
        }
    }

    func testInvalidDurationsRemainBounded() {
        for duration in [TimeInterval(-1), -.infinity, .nan] {
            XCTAssertEqual(LocalTranscriptionDeadline.seconds(forAudioDuration: duration), 30)
        }
    }

    func testCompletedTranscriptionReturnsItsText() async throws {
        let text = try await LocalTranscriptionDeadline.run(seconds: 1, engineName: "stub") {
            "Recognized speech."
        }
        XCTAssertEqual(text, "Recognized speech.")
    }

    func testEngineFailureIsPreserved() async {
        enum StubFailure: Error { case decode }
        do {
            _ = try await LocalTranscriptionDeadline.run(seconds: 1, engineName: "stub") {
                throw StubFailure.decode
            }
            XCTFail("Expected the decode failure")
        } catch StubFailure.decode {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNeverReturningEngineTimesOutAndStopsUnderlyingWork() async {
        let cancelled = expectation(description: "Engine receives cancellation")
        let stopped = expectation(description: "Engine operation exits")
        let engine = NeverReturningEngine(seconds: 0.03, cancelled: cancelled, stopped: stopped)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await engine.transcribe(audioURL: URL(fileURLWithPath: "/unused-stub-audio"))
            XCTFail("Expected transcription timeout")
        } catch let error as LocalTranscriptionTimeout {
            XCTAssertEqual(error.engineName, engine.displayName)
            XCTAssertEqual(error.seconds, engine.seconds)
            XCTAssertTrue(error.localizedDescription.contains("History"))
            XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await fulfillment(of: [cancelled, stopped], timeout: 1)
    }

    func testCallerCancellationStopsUnderlyingWorkWithoutBecomingTimeout() async {
        let started = expectation(description: "Engine operation starts")
        let cancelled = expectation(description: "Engine receives cancellation")
        let stopped = expectation(description: "Engine operation exits")
        let engine = NeverReturningEngine(
            seconds: 1, cancelled: cancelled, stopped: stopped, started: started
        )
        let task = Task {
            try await engine.transcribe(audioURL: URL(fileURLWithPath: "/unused-stub-audio"))
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await fulfillment(of: [cancelled, stopped], timeout: 1)
    }

    func testTimeoutDoesNotJoinNonCooperativeWork() async {
        let started = expectation(description: "Non-cooperative operation starts")
        let stopped = expectation(description: "Late operation exits")
        let gate = SuspensionGate()
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task {
            try await LocalTranscriptionDeadline.run(seconds: 0.03, engineName: "stub") {
                defer { stopped.fulfill() }
                await gate.wait(started: started)
                return "Late result"
            }
        }
        await fulfillment(of: [started], timeout: 1)
        do {
            _ = try await task.value
            XCTFail("Expected transcription timeout")
        } catch is LocalTranscriptionTimeout {
            XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        // Release the intentionally uncooperative stub so the test leaks no task.
        await gate.release()
        await fulfillment(of: [stopped], timeout: 1)
    }
}

/// Decode completion advances virtual elapsed time; no wall-clock sleeps,
/// framework models, speech assets, or user settings are involved.
private actor TranscriptionTestClock {
    let completionTime: TimeInterval
    private(set) var scheduledSeconds: TimeInterval?
    private var engineName = ""

    init(completionTime: TimeInterval) {
        self.completionTime = completionTime
    }

    func run(
        seconds: TimeInterval, engineName: String,
        operation: @escaping LocalTranscriptionDeadline.Operation
    ) async throws -> String {
        scheduledSeconds = seconds
        self.engineName = engineName
        return try await operation()
    }

    func completeDecode() throws -> String {
        if let seconds = scheduledSeconds, completionTime >= seconds {
            throw LocalTranscriptionTimeout(engineName: engineName, seconds: seconds)
        }
        return "Recognized speech."
    }
}

private struct NeverReturningEngine: ASREngine {
    let id = "deadline-stub"
    let displayName = "Deadline stub"
    let seconds: TimeInterval
    let cancelled: XCTestExpectation
    let stopped: XCTestExpectation
    var started: XCTestExpectation? = nil

    func transcribe(audioURL: URL) async throws -> String {
        try await LocalTranscriptionDeadline.run(seconds: seconds, engineName: displayName) {
            defer { stopped.fulfill() }
            return try await withTaskCancellationHandler {
                started?.fulfill()
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return "Unreachable"
            } onCancel: {
                cancelled.fulfill()
            }
        }
    }
}

private actor SuspensionGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait(started: XCTestExpectation) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
