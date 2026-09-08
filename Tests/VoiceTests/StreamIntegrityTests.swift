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
