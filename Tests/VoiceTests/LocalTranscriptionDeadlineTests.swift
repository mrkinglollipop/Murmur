import XCTest
@testable import Voice

final class LocalTranscriptionDeadlineTests: XCTestCase {
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

    func testLongRecordingsUseCeiling() {
        for duration in [TimeInterval(75), 300, 3_600, .greatestFiniteMagnitude, .infinity] {
            XCTAssertEqual(LocalTranscriptionDeadline.seconds(forAudioDuration: duration), 300)
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
