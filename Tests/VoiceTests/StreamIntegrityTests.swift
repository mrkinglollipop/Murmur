import AVFoundation
import XCTest
@testable import Voice

final class StreamIntegrityTests: XCTestCase {
    private enum InjectedFailure: Error { case send }

    func testFinalizeDeadlineBoundsNonCooperativeTerminalSendForXAI() async {
        let session = XAIStreamingTranscriber(
            apiKey: "key",
            finalizeBudgetOverride: 0.05,
            messageSender: Self.nonCooperativeSender
        )
        session.handleServerEvent(#"{"type":"transcript.partial","text":"xai prefix","is_final":false}"#)
        let startedAt = Date()
        let text = await session.finalize(recordingDuration: 4)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.4)
        XCTAssertEqual(text, "xai prefix")
        XCTAssertTrue(session.requiresBufferedAudioRecovery)
    }

    func testFinalizeDeadlineBoundsNonCooperativeTerminalSendForGemini() async {
        let session = GeminiLiveTranscriber(
            apiKey: "key",
            finalizeBudgetOverride: 0.05,
            messageSender: Self.nonCooperativeSender
        )
        session.handleServerEvent(#"{"serverContent":{"inputTranscription":{"text":"gemini prefix"}}}"#)
        let startedAt = Date()
        let text = await session.finalize(recordingDuration: 4)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.4)
        XCTAssertEqual(text, "gemini prefix")
        XCTAssertTrue(session.requiresBufferedAudioRecovery)
    }

    func testFinalizeDeadlineBoundsNonCooperativeTerminalSendForMuse() async {
        let session = MuseLiveTranscriber(
            apiKey: "key",
            finalizeBudgetOverride: 0.05,
            messageSender: Self.nonCooperativeSender
        )
        session.handleServerEvent(#"{"type":"transcript","transcript":"muse prefix","final":true}"#)
        let startedAt = Date()
        let text = await session.finalize(recordingDuration: 4)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.4)
        XCTAssertEqual(text, "muse prefix")
        XCTAssertTrue(session.requiresBufferedAudioRecovery)
    }

    private static func nonCooperativeSender(_ message: URLSessionWebSocketTask.Message) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.75) {
                continuation.resume()
            }
        }
    }

    func testTerminalSendFailureLatchesRecoveryForEveryProvider() async {
        let eleven = ElevenLabsRealtimeTranscriber(apiKey: "key") { _ in throw InjectedFailure.send }
        eleven.handleServerEvent(#"{"message_type":"partial_transcript","text":"plausible eleven prefix"}"#)
        let elevenText = await eleven.finalize(recordingDuration: 4)
        XCTAssertEqual(elevenText, "plausible eleven prefix")
        XCTAssertTrue(eleven.requiresBufferedAudioRecovery)

        let gemini = GeminiLiveTranscriber(apiKey: "key", messageSender: { _ in throw InjectedFailure.send })
        gemini.handleServerEvent(#"{"serverContent":{"inputTranscription":{"text":"plausible gemini prefix"}}}"#)
        let geminiText = await gemini.finalize(recordingDuration: 4)
        XCTAssertEqual(geminiText, "plausible gemini prefix")
        XCTAssertTrue(gemini.requiresBufferedAudioRecovery)

        let muse = MuseLiveTranscriber(apiKey: "key", messageSender: { _ in throw InjectedFailure.send })
        muse.handleServerEvent(#"{"type":"transcript","transcript":"plausible muse prefix","final":true}"#)
        let museText = await muse.finalize(recordingDuration: 4)
        XCTAssertEqual(museText, "plausible muse prefix")
        XCTAssertTrue(muse.requiresBufferedAudioRecovery)

        let xai = XAIStreamingTranscriber(apiKey: "key", messageSender: { _ in throw InjectedFailure.send })
        xai.handleServerEvent(#"{"type":"transcript.partial","text":"plausible xai prefix","is_final":false}"#)
        let xaiText = await xai.finalize(recordingDuration: 4)
        XCTAssertEqual(xaiText, "plausible xai prefix")
        XCTAssertTrue(xai.requiresBufferedAudioRecovery)
    }

    func testProtocolErrorLatchesRecoveryForEveryProvider() {
        let eleven = ElevenLabsRealtimeTranscriber(apiKey: "key")
        eleven.handleServerEvent(#"{"message_type":"input_error","error":"bad audio"}"#)
        XCTAssertTrue(eleven.requiresBufferedAudioRecovery)

        let gemini = GeminiLiveTranscriber(apiKey: "key")
        gemini.handleServerEvent(#"{"error":{"message":"bad audio"}}"#)
        XCTAssertTrue(gemini.requiresBufferedAudioRecovery)

        let muse = MuseLiveTranscriber(apiKey: "key")
        muse.handleServerEvent(#"{"type":"error","message":"bad audio"}"#)
        XCTAssertTrue(muse.requiresBufferedAudioRecovery)

        let xai = XAIStreamingTranscriber(apiKey: "key")
        xai.handleServerEvent(#"{"type":"error","message":"bad audio"}"#)
        XCTAssertTrue(xai.requiresBufferedAudioRecovery)
    }

    func testEveryUnsolicitedRemoteSocketCloseLatchesRecovery() {
        let normalCloseSessions: [() -> Bool] = [
            {
                let session = ElevenLabsRealtimeTranscriber(apiKey: "key")
                session.noteSocketClosed(closeCode: .normalClosure)
                return session.requiresBufferedAudioRecovery
            },
            {
                let session = GeminiLiveTranscriber(apiKey: "key")
                session.noteSocketClosed(closeCode: .normalClosure)
                return session.requiresBufferedAudioRecovery
            },
            {
                let session = MuseLiveTranscriber(apiKey: "key")
                session.noteSocketClosed(closeCode: .normalClosure)
                return session.requiresBufferedAudioRecovery
            },
            {
                let session = XAIStreamingTranscriber(apiKey: "key")
                session.noteSocketClosed(closeCode: .normalClosure)
                return session.requiresBufferedAudioRecovery
            },
        ]
        XCTAssertTrue(
            normalCloseSessions.allSatisfy { $0() },
            "a remote normal close is still premature until this client proves terminal coverage"
        )

        let abnormalSessions: [() -> Bool] = [
            {
                let session = ElevenLabsRealtimeTranscriber(apiKey: "key")
                session.noteSocketClosed(closeCode: .abnormalClosure)
                return session.requiresBufferedAudioRecovery
            },
            {
                let session = GeminiLiveTranscriber(apiKey: "key")
                session.noteSocketClosed(closeCode: .abnormalClosure)
                return session.requiresBufferedAudioRecovery
            },
            {
                let session = MuseLiveTranscriber(apiKey: "key")
                session.noteSocketClosed(closeCode: .abnormalClosure)
                return session.requiresBufferedAudioRecovery
            },
            {
                let session = XAIStreamingTranscriber(apiKey: "key")
                session.noteSocketClosed(closeCode: .abnormalClosure)
                return session.requiresBufferedAudioRecovery
            },
        ]
        XCTAssertTrue(abnormalSessions.allSatisfy { $0() })
    }

    func testGeminiCapLatchesRecoveryAndPreservesPrefix() async {
        let gemini = GeminiLiveTranscriber(apiKey: "key")
        gemini.handleServerEvent(#"{"serverContent":{"inputTranscription":{"text":"ten minute prefix"}}}"#)
        gemini.recordSessionCapReached()
        let text = await gemini.finalize(recordingDuration: 601)
        XCTAssertEqual(text, "ten minute prefix")
        XCTAssertTrue(gemini.requiresBufferedAudioRecovery)
    }

    func testCoordinatorRoutesEveryFailedNonemptyStreamToBufferedAudio() async {
        let buffer = Self.audioBuffer(seconds: 1)
        await assertElevenCoordinatorFallback(buffer: buffer)
        await assertGeminiCoordinatorFallback(buffer: buffer)
        await assertMuseCoordinatorFallback(buffer: buffer)
        await assertXAICoordinatorFallback(buffer: buffer)
    }

    func testElevenLabsTerminalEllipsisRoutesShortManualFinalizeToBufferedAudio() async {
        let buffer = Self.audioBuffer(seconds: 11.3)
        let duration = 10.657
        let prefix = "We want to customize this draft and make the final result fit the product..."
        XCTAssertFalse(StreamingCoordinator.streamResultLooksTruncated(text: prefix, duration: duration))
        let session = ElevenLabsRealtimeTranscriber(apiKey: "key", messageSender: { _ in })
        let coordinator = StreamingCoordinator(elevenLabsSession: session)
        let fallback = expectation(description: "ElevenLabs ellipsis batch fallback")

        XCTAssertTrue(coordinator.handleStopElevenLabs(
            context: .init(duration: duration, hadSpeech: true, bufferedAudio: [buffer], streamTextEver: true),
            onSilence: { XCTFail("unexpected silence") },
            onStreamSuccess: { _ in XCTFail("ellipsis-ended prefix escaped as stream success") },
            onBatchFallback: { buffers, recoveredDuration in
                XCTAssertEqual(buffers.count, 1)
                XCTAssertTrue(buffers.first === buffer)
                XCTAssertEqual(recoveredDuration, duration)
                XCTAssertFalse(session.requiresBufferedAudioRecovery)
                fallback.fulfill()
            }
        ))

        try? await Task.sleep(nanoseconds: 20_000_000)
        let event = try! JSONSerialization.data(withJSONObject: ["message_type": "committed_transcript", "text": prefix])
        session.handleServerEvent(String(decoding: event, as: UTF8.self))
        await fulfillment(of: [fallback], timeout: 1)
    }

    func testElevenLabsKnownRecoverySkipsCommitWaitAndPreservesRawBuffer() async {
        for scenario in ["long", "vad", "priorCommit"] {
            var options = ElevenLabsRealtimeOptions.defaults
            if scenario == "vad" { options.commitStrategy = .vad }
            let duration: TimeInterval = scenario == "long" ? 30 : 4
            let buffer = Self.audioBuffer(seconds: duration)
            let session = ElevenLabsRealtimeTranscriber(
                apiKey: "key", realtimeOptions: options,
                messageSender: { _ in XCTFail("Known recovery must not send an unnecessary final commit") }
            )
            let type = scenario == "priorCommit" ? "committed_transcript" : "partial_transcript"
            session.handleServerEvent("{\"message_type\":\"\(type)\",\"text\":\"plausible but incomplete prefix\"}")
            let coordinator = StreamingCoordinator(elevenLabsSession: session)
            let fallback = expectation(description: "Immediate complete-audio recovery: \(scenario)")
            XCTAssertTrue(coordinator.handleStopElevenLabs(
                context: .init(duration: duration, hadSpeech: true, bufferedAudio: [buffer], streamTextEver: true),
                onSilence: { XCTFail("unexpected silence") },
                onStreamSuccess: { _ in XCTFail("Ambiguous prefix escaped as stream success") },
                onBatchFallback: { buffers, recoveredDuration in
                    XCTAssertEqual(buffers.count, 1)
                    XCTAssertTrue(buffers.first === buffer)
                    XCTAssertEqual(recoveredDuration, duration)
                    XCTAssertTrue(session.requiresBufferedAudioRecovery)
                    fallback.fulfill()
                }
            ))
            // The old serial wait was at least four seconds for these cases.
            // No provider event is supplied: recovery must not depend on one.
            await fulfillment(of: [fallback], timeout: 1)
        }
    }

    func testElevenLabsFinalizeBudgetFallsBackOnceWithExactRetainedAudio() async {
        let buffer = Self.audioBuffer(seconds: 4)
        let session = ElevenLabsRealtimeTranscriber(apiKey: "key", messageSender: { _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
        })
        session.handleServerEvent(#"{"message_type":"partial_transcript","text":"plausible but incomplete prefix"}"#)
        let coordinator = StreamingCoordinator(elevenLabsSession: session)
        let fallback = expectation(description: "bounded full-audio recovery")
        let lock = NSLock()
        var successCount = 0
        var fallbackCount = 0
        var interimCount = 0
        session.onInterim = { _ in
            lock.lock()
            interimCount += 1
            lock.unlock()
        }
        let startedAt = Date()

        XCTAssertTrue(coordinator.handleStopElevenLabs(
            context: .init(duration: 4, hadSpeech: true, bufferedAudio: [buffer], streamTextEver: true),
            onSilence: { XCTFail("unexpected silence") },
            onStreamSuccess: { _ in
                lock.lock()
                successCount += 1
                lock.unlock()
            },
            onBatchFallback: { buffers, duration in
                lock.lock()
                fallbackCount += 1
                lock.unlock()
                XCTAssertEqual(buffers.count, 1)
                XCTAssertTrue(buffers.first === buffer)
                XCTAssertEqual(buffers.first?.frameLength, buffer.frameLength)
                XCTAssertEqual(duration, 4)
                fallback.fulfill()
            }
        ))

        await fulfillment(of: [fallback], timeout: 2.5)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2.2)

        // A provider event arriving after the deadline must not revive the
        // abandoned stream or produce a second delivery.
        session.handleServerEvent(#"{"message_type":"committed_transcript","text":"late authority"}"#)
        try? await Task.sleep(nanoseconds: 300_000_000)
        lock.lock()
        let counts = (successCount, fallbackCount, interimCount)
        lock.unlock()
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(counts.2, 0)
        XCTAssertEqual(session.joinedTranscriptSnapshot(), "")
    }

    func testElevenLabsPromptFinalCommitKeepsStreamingResult() async {
        let buffer = Self.audioBuffer(seconds: 4)
        let session = ElevenLabsRealtimeTranscriber(apiKey: "key", messageSender: { _ in })
        let coordinator = StreamingCoordinator(elevenLabsSession: session)
        let success = expectation(description: "prompt committed stream result")
        var fallbackCount = 0

        XCTAssertTrue(coordinator.handleStopElevenLabs(
            context: .init(duration: 4, hadSpeech: true, bufferedAudio: [buffer], streamTextEver: true),
            onSilence: { XCTFail("unexpected silence") },
            onStreamSuccess: { text in
                XCTAssertEqual(text, "complete short result")
                success.fulfill()
            },
            onBatchFallback: { _, _ in fallbackCount += 1 }
        ))

        try? await Task.sleep(nanoseconds: 50_000_000)
        session.handleServerEvent(#"{"message_type":"committed_transcript","text":"complete short result"}"#)
        await fulfillment(of: [success], timeout: 1)
        XCTAssertEqual(fallbackCount, 0)
        XCTAssertFalse(session.requiresBufferedAudioRecovery)
    }

    /// Replays the logged order: session ready -> finalize -> committed_transcript
    /// 0.15 s in -> a trailing partial that only re-emits committed words.
    func testElevenLabsTrailingDuplicatePartialDoesNotHoldFinalizeToDeadline() async {
        let session = ElevenLabsRealtimeTranscriber(apiKey: "key", messageSender: { _ in })
        let finalizer = Task { await session.finalize(recordingDuration: 4) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        session.handleServerEvent(#"{"message_type":"committed_transcript","text":"Send the report to Dana before noon today."}"#)
        session.handleServerEvent(#"{"message_type":"partial_transcript","text":"send the report to dana before noon today"}"#)
        let startedAt = Date()
        let text = await finalizer.value
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.8)
        XCTAssertEqual(text, "Send the report to Dana before noon today.")
        XCTAssertFalse(session.requiresBufferedAudioRecovery)
    }

    /// A post-commit partial that carries words the commit lacks still waits for
    /// its authoritative commit and falls back to buffered audio if none arrives.
    func testElevenLabsTrailingPartialWithNewWordsStillRequestsRecovery() async {
        let session = ElevenLabsRealtimeTranscriber(apiKey: "key", messageSender: { _ in })
        let finalizer = Task { await session.finalize(recordingDuration: 4) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        session.handleServerEvent(#"{"message_type":"committed_transcript","text":"Send the report"}"#)
        session.handleServerEvent(#"{"message_type":"partial_transcript","text":"send the report to Dana"}"#)
        _ = await finalizer.value
        XCTAssertTrue(session.requiresBufferedAudioRecovery)
    }

    // MARK: - Release before the socket is ready

    /// Records every message a session writes so a test can assert that no
    /// end-of-stream/commit frame went out ahead of the (never-sent) audio.
    private final class SentLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func record(_ message: URLSessionWebSocketTask.Message) {
            lock.lock()
            defer { lock.unlock() }
            switch message {
            case .string(let text): items.append(text)
            case .data(let data): items.append("<\(data.count) bytes>")
            @unknown default: break
            }
        }
        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    private static let endMarkers = ["audio.done", "endStream", "activityEnd", "audioStreamEnd", "\"commit\":true"]

    private func assertNoEndFrame(_ log: SentLog, file: StaticString = #filePath, line: UInt = #line) {
        for frame in log.all {
            for marker in Self.endMarkers {
                XCTAssertFalse(frame.contains(marker), "end frame sent before readiness: \(marker)", file: file, line: line)
            }
        }
    }

    func testGeminiReleaseBeforeSetupCompleteSkipsSocketAndRecovers() async {
        let log = SentLog()
        let session = GeminiLiveTranscriber(apiKey: "key", readinessTimeoutSeconds: 1, messageSender: { log.record($0) })
        let starting = Task { try? await session.start() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let startedAt = Date()
        _ = await session.finalize(recordingDuration: 4)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
        XCTAssertTrue(session.requiresBufferedAudioRecovery)
        assertNoEndFrame(log)
        _ = await starting.value
    }

    func testMuseReleaseBeforeHandshakeAckSkipsSocketAndRecovers() async {
        let log = SentLog()
        let session = MuseLiveTranscriber(apiKey: "key", readinessTimeoutSeconds: 1, messageSender: { log.record($0) })
        let starting = Task { try? await session.start() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let startedAt = Date()
        _ = await session.finalize(recordingDuration: 4)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
        XCTAssertTrue(session.requiresBufferedAudioRecovery)
        assertNoEndFrame(log)
        _ = await starting.value
    }

    func testXAIReleaseBeforeTranscriptCreatedSkipsSocketAndRecovers() async {
        let log = SentLog()
        let session = XAIStreamingTranscriber(apiKey: "key", messageSender: { log.record($0) })
        _ = Task { try? await session.start() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let startedAt = Date()
        _ = await session.finalize(recordingDuration: 4)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
        XCTAssertTrue(session.requiresBufferedAudioRecovery)
        assertNoEndFrame(log)
    }

    func testElevenLabsReleaseBeforeSessionStartedSkipsSocketAndRecovers() async {
        let log = SentLog()
        let session = ElevenLabsRealtimeTranscriber(apiKey: "key", messageSender: { log.record($0) })
        _ = Task { try? await session.start() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let startedAt = Date()
        _ = await session.finalize(recordingDuration: 4)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
        XCTAssertTrue(session.requiresBufferedAudioRecovery)
        assertNoEndFrame(log)
    }

    func testAssemblyAIPollURLRejectsNonIDShapedTranscriptIDs() {
        XCTAssertEqual(
            AssemblyAITranscriptionService.pollURL(transcriptID: "abc-123_DEF")?.absoluteString,
            "https://api.assemblyai.com/v2/transcript/abc-123_DEF"
        )
        for bad in ["", "../v2/upload", "a/b", "a?b=c", "has space", "id\n"] {
            XCTAssertNil(AssemblyAITranscriptionService.pollURL(transcriptID: bad), bad)
        }
    }

    func testStartFailureLogOmitsURLSessionErrorDescription() {
        let leaky = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
            userInfo: [NSLocalizedDescriptionKey: "wss://host/ws?key=SECRETKEY0123456789 refused"]
        )
        let text = StreamingCoordinator.startFailureDescription(leaky)
        XCTAssertEqual(text, "\(NSURLErrorDomain)#\(NSURLErrorCannotConnectToHost)")
        XCTAssertFalse(text.contains("SECRET"))
        XCTAssertTrue(StreamingCoordinator.startFailureDescription(
            CloudTranscriptionError(provider: .gemini, message: "Timed out")).contains("Timed out"))
    }

    func testCancelAllClearsEverySessionReference() {
        let coordinator = StreamingCoordinator(
            xaiSession: XAIStreamingTranscriber(apiKey: "key"),
            elevenLabsSession: ElevenLabsRealtimeTranscriber(apiKey: "key"),
            geminiSession: GeminiLiveTranscriber(apiKey: "key"),
            museSession: MuseLiveTranscriber(apiKey: "key")
        )
        coordinator.cancelAll()
        XCTAssertNil(coordinator.xaiSession)
        XCTAssertNil(coordinator.elevenLabsSession)
        XCTAssertNil(coordinator.geminiSession)
        XCTAssertNil(coordinator.museSession)
    }

    func testElevenLabsPartialCoverageIsCaseAndPunctuationInsensitive() {
        XCTAssertTrue(ElevenLabsRealtimeTranscriber.partialIsCovered(
            byCommitted: ["Hello, world.", "Second one"], partial: "hello world second"))
        XCTAssertFalse(ElevenLabsRealtimeTranscriber.partialIsCovered(
            byCommitted: ["Hello, world."], partial: "hello there"))
        XCTAssertFalse(ElevenLabsRealtimeTranscriber.partialIsCovered(
            byCommitted: ["Hello"], partial: "hello world"))
    }

    func testElevenLabsLongSessionCannotTreatFirstRacedCommitAsSessionFinal() async {
        let session = ElevenLabsRealtimeTranscriber(apiKey: "key", messageSender: { _ in })
        let finalizer = Task { await session.finalize(recordingDuration: 40) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        session.handleServerEvent(#"{"message_type":"committed_transcript","text":"automatic prefix"}"#)
        _ = await finalizer.value
        XCTAssertTrue(
            session.requiresBufferedAudioRecovery,
            "a long-session commit cannot be correlated to the manual final boundary"
        )
    }

    func testElevenLabsVADSessionCannotTreatFirstRacedCommitAsSessionFinal() async {
        var options = ElevenLabsRealtimeOptions.defaults
        options.commitStrategy = .vad
        let session = ElevenLabsRealtimeTranscriber(
            apiKey: "key",
            realtimeOptions: options,
            messageSender: { _ in }
        )
        let finalizer = Task { await session.finalize(recordingDuration: 4) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        session.handleServerEvent(#"{"message_type":"committed_transcript","text":"automatic VAD prefix"}"#)
        _ = await finalizer.value
        XCTAssertTrue(
            session.requiresBufferedAudioRecovery,
            "VAD can auto-commit before the manual finalize boundary at any duration"
        )
    }

    private func assertElevenCoordinatorFallback(buffer: AVAudioPCMBuffer) async {
        let session = ElevenLabsRealtimeTranscriber(apiKey: "key")
        session.handleServerEvent(#"{"message_type":"partial_transcript","text":"plausible eleven prefix"}"#)
        session.noteSocketClosed(closeCode: .normalClosure)
        let coordinator = StreamingCoordinator(elevenLabsSession: session)
        let fallback = expectation(description: "ElevenLabs batch fallback")
        XCTAssertTrue(coordinator.handleStopElevenLabs(
            context: .init(duration: 4, hadSpeech: true, bufferedAudio: [buffer], streamTextEver: true),
            onSilence: { XCTFail("unexpected silence") },
            onStreamSuccess: { _ in XCTFail("failed prefix escaped as success") },
            onBatchFallback: { buffers, duration in
                XCTAssertEqual(buffers.count, 1)
                XCTAssertTrue(buffers.first === buffer)
                XCTAssertEqual(buffers.first?.frameLength, buffer.frameLength)
                XCTAssertEqual(duration, 4)
                fallback.fulfill()
            }
        ))
        await fulfillment(of: [fallback], timeout: 1)
    }

    private func assertGeminiCoordinatorFallback(buffer: AVAudioPCMBuffer) async {
        let session = GeminiLiveTranscriber(apiKey: "key")
        session.handleServerEvent(#"{"serverContent":{"inputTranscription":{"text":"plausible gemini prefix"}}}"#)
        session.handleServerEvent(#"{"error":{"message":"bad audio"}}"#)
        let coordinator = StreamingCoordinator(geminiSession: session)
        let fallback = expectation(description: "Gemini batch fallback")
        XCTAssertTrue(coordinator.handleStopGemini(
            context: .init(duration: 4, hadSpeech: true, bufferedAudio: [buffer], streamTextEver: true),
            onSilence: { XCTFail("unexpected silence") },
            onStreamSuccess: { _ in XCTFail("failed prefix escaped as success") },
            onBatchFallback: { buffers, duration in
                XCTAssertEqual(buffers.count, 1)
                XCTAssertTrue(buffers.first === buffer)
                XCTAssertEqual(buffers.first?.frameLength, buffer.frameLength)
                XCTAssertEqual(duration, 4)
                fallback.fulfill()
            }
        ))
        await fulfillment(of: [fallback], timeout: 1)
    }

    private func assertMuseCoordinatorFallback(buffer: AVAudioPCMBuffer) async {
        let session = MuseLiveTranscriber(apiKey: "key")
        session.handleServerEvent(#"{"type":"transcript","transcript":"plausible muse prefix","final":true}"#)
        session.handleServerEvent(#"{"type":"error","message":"bad audio"}"#)
        let coordinator = StreamingCoordinator(museSession: session)
        let fallback = expectation(description: "Muse batch fallback")
        XCTAssertTrue(coordinator.handleStopMuse(
            context: .init(duration: 4, hadSpeech: true, bufferedAudio: [buffer], streamTextEver: true),
            onSilence: { XCTFail("unexpected silence") },
            onStreamSuccess: { _ in XCTFail("failed prefix escaped as success") },
            onBatchFallback: { buffers, duration in
                XCTAssertEqual(buffers.count, 1)
                XCTAssertTrue(buffers.first === buffer)
                XCTAssertEqual(buffers.first?.frameLength, buffer.frameLength)
                XCTAssertEqual(duration, 4)
                fallback.fulfill()
            }
        ))
        await fulfillment(of: [fallback], timeout: 1)
    }

    private func assertXAICoordinatorFallback(buffer: AVAudioPCMBuffer) async {
        let session = XAIStreamingTranscriber(apiKey: "key")
        session.handleServerEvent(#"{"type":"transcript.partial","text":"plausible xai prefix","is_final":false}"#)
        session.handleServerEvent(#"{"type":"error","message":"bad audio"}"#)
        let coordinator = StreamingCoordinator(xaiSession: session)
        let fallback = expectation(description: "xAI batch fallback")
        XCTAssertTrue(coordinator.handleStopXAI(
            context: .init(duration: 4, hadSpeech: true, bufferedAudio: [buffer], streamTextEver: true),
            onSilence: { XCTFail("unexpected silence") },
            onStreamSuccess: { _ in XCTFail("failed prefix escaped as success") },
            onBatchFallback: { buffers, duration in
                XCTAssertEqual(buffers.count, 1)
                XCTAssertTrue(buffers.first === buffer)
                XCTAssertEqual(buffers.first?.frameLength, buffer.frameLength)
                XCTAssertEqual(duration, 4)
                fallback.fulfill()
            }
        ))
        await fulfillment(of: [fallback], timeout: 1)
    }

    private static func audioBuffer(seconds: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        return buffer
    }
}

/// Exercises the real sender and finalize paths with no socket or provider.
final class StreamingSenderOrderingTests: XCTestCase {
    private enum TerminalSent: Error { case stop }

    private actor Barrier {
        private var opened = false
        private var waiter: CheckedContinuation<Void, Never>?

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiter = $0 }
        }

        func open() {
            opened = true
            waiter?.resume()
            waiter = nil
        }
    }

    private final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [String] = []

        var all: [String] { lock.withLock { frames } }

        func send(_ message: URLSessionWebSocketTask.Message) throws {
            let kind: String
            switch message {
            case .data:
                kind = "audio"
            case .string(let text):
                let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
                if json["commit"] as? Bool == true || json["type"] as? String == "audio.done"
                    || json["type"] as? String == "endStream" {
                    kind = "terminal"
                } else if let realtime = json["realtimeInput"] as? [String: Any] {
                    if realtime["activityEnd"] != nil || realtime["audioStreamEnd"] != nil {
                        kind = "terminal"
                    } else if realtime["activityStart"] != nil {
                        kind = "activityStart"
                    } else {
                        kind = "audio"
                    }
                } else if json["audio_base_64"] != nil {
                    kind = "audio"
                } else {
                    kind = "setup"
                }
            @unknown default:
                kind = "unknown"
            }
            lock.withLock { frames.append(kind) }
            // End the test's finalize immediately; ordering is independent of
            // provider transcript responses and the production timeout budget.
            if kind == "terminal" { throw TerminalSent.stop }
        }
    }

    func testElevenLabsFinalizeDrainsAudioWhileStartIsPausedAfterReadiness() async throws {
        let frames = Frames()
        let session = ElevenLabsRealtimeTranscriber(apiKey: "offline", messageSender: { try frames.send($0) })
        try await assertOrdering(
            start: { try await session.start(beforeReadiness: $0, afterReadiness: $1) },
            send: session.send,
            ready: { session.handleServerEvent(#"{"message_type":"session_started"}"#) },
            finalize: { _ = await session.finalize() }, frames: frames
        )
    }

    func testXAIFinalizeDrainsAudioWhileStartIsPausedAfterReadiness() async throws {
        let frames = Frames()
        let session = XAIStreamingTranscriber(apiKey: "offline", messageSender: { try frames.send($0) })
        try await assertOrdering(
            start: { try await session.start(beforeReadiness: $0, afterReadiness: $1) },
            send: session.send,
            ready: { session.handleServerEvent(#"{"type":"transcript.created"}"#) },
            finalize: { _ = await session.finalize() }, frames: frames
        )
    }

    func testGeminiFinalizeDrainsAudioWhileStartIsPausedAfterReadiness() async throws {
        try await assertGeminiOrdering(manual: false)
    }

    func testGeminiManualFinalizeDrainsAudioWhileStartIsPausedAfterReadiness() async throws {
        try await assertGeminiOrdering(manual: true)
    }

    private func assertGeminiOrdering(manual: Bool) async throws {
        let frames = Frames()
        var options = GeminiLiveOptions.defaults
        options.vadMode = manual ? .manual : .automatic
        let session = GeminiLiveTranscriber(apiKey: "offline", liveOptions: options,
                                           messageSender: { try frames.send($0) })
        try await assertOrdering(
            start: { try await session.start(beforeReadiness: $0, afterReadiness: $1) },
            send: session.send,
            ready: { session.handleServerEvent(#"{"setupComplete":{}}"#) },
            finalize: { _ = await session.finalize() }, frames: frames,
            prefix: manual ? ["setup", "activityStart"] : ["setup"]
        )
    }

    func testMuseFinalizeDrainsAudioWhileStartIsPausedAfterReadiness() async throws {
        let frames = Frames()
        let session = MuseLiveTranscriber(apiKey: "offline", messageSender: { try frames.send($0) })
        try await assertOrdering(
            start: { try await session.start(beforeReadiness: $0, afterReadiness: $1) },
            send: session.send,
            ready: { session.handleServerEvent(#"{"sessionId":"offline"}"#) },
            finalize: { _ = await session.finalize() }, frames: frames, prefix: ["setup"]
        )
    }

    private typealias Start = (@escaping () -> Void, @escaping () async -> Void) async throws -> Void

    private func assertOrdering(
        start: @escaping Start,
        send: @escaping (AVAudioPCMBuffer) -> Void,
        ready: @escaping () -> Void,
        finalize: () async -> Void,
        frames: Frames,
        prefix: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let paused = expectation(description: "start paused after handshake")
        let barrier = Barrier()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        for index in 0..<160 { buffer.floatChannelData![0][index] = 0.1 }
        let starting = Task {
            try await start({
                send(buffer)
                send(buffer)
                XCTAssertFalse(frames.all.contains("audio"), "audio escaped before readiness", file: file, line: line)
                ready()
            }, {
                paused.fulfill()
                await barrier.wait()
            })
        }
        await fulfillment(of: [paused], timeout: 5)
        await finalize()
        XCTAssertEqual(frames.all, prefix + ["audio", "audio", "terminal"], file: file, line: line)
        await barrier.open()
        try await starting.value
    }
}
