import AVFoundation
import XCTest
@testable import Voice

/// Replays long ElevenLabs holds through the real send / sender / finalize
/// path with an injected transport and synthetic server events. No socket,
/// Keychain, or provider is touched.
final class ElevenLabsLongHoldCoverageTests: XCTestCase {
    private static let loud: Int16 = 3000
    private static let quiet: Int16 = 200

    /// Records every frame the sender hands to the transport.
    private final class Transport: @unchecked Sendable {
        struct Frame { let samples: Int; let commit: Bool }
        private let lock = NSLock()
        private var frames: [Frame] = []

        var all: [Frame] { lock.withLock { frames } }
        var commitOffsetsSeconds: [Double] {
            var offset = 0
            var result: [Double] = []
            for frame in all {
                offset += frame.samples
                if frame.commit { result.append(Double(offset) / 16_000) }
            }
            return result
        }

        func send(_ message: URLSessionWebSocketTask.Message) throws {
            guard case .string(let text) = message,
                  let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let base64 = json["audio_base_64"] as? String,
                  let audio = Data(base64Encoded: base64) else { return }
            let frame = Frame(samples: audio.count / 2, commit: json["commit"] as? Bool == true)
            lock.withLock { frames.append(frame) }
        }
    }

    private static func pcm(seconds: Double, amplitude: Int16) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                   channels: 1, interleaved: true)!
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.int16ChannelData![0][index] = index.isMultiple(of: 2) ? amplitude : -amplitude
        }
        return buffer
    }

    private func startedSession(
        _ transport: Transport,
        options: ElevenLabsRealtimeOptions = .defaults
    ) async throws -> ElevenLabsRealtimeTranscriber {
        let session = ElevenLabsRealtimeTranscriber(
            apiKey: "offline", realtimeOptions: options, messageSender: { try transport.send($0) }
        )
        try await session.start(beforeReadiness: {
            session.handleServerEvent(#"{"message_type":"session_started"}"#)
        })
        return session
    }

    /// Sends one-second chunks for `range` (quiet at `quietSeconds`), then
    /// waits until the sender has handed every chunk to the transport.
    private func hold(
        _ session: ElevenLabsRealtimeTranscriber,
        _ transport: Transport,
        seconds range: Range<Int>,
        quietSeconds: Set<Int>
    ) async {
        for second in range {
            session.send(Self.pcm(seconds: 1, amplitude: quietSeconds.contains(second) ? Self.quiet : Self.loud))
        }
        let deadline = Date().addingTimeInterval(2)
        while transport.all.count < range.upperBound, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(transport.all.count, range.upperBound, "sender must drain every captured chunk")
    }

    private func commit(_ session: ElevenLabsRealtimeTranscriber, _ text: String) {
        let data = try! JSONSerialization.data(withJSONObject: ["message_type": "committed_transcript", "text": text])
        session.handleServerEvent(String(decoding: data, as: UTF8.self))
    }

    private func partial(_ session: ElevenLabsRealtimeTranscriber, _ text: String) {
        let data = try! JSONSerialization.data(withJSONObject: ["message_type": "partial_transcript", "text": text])
        session.handleServerEvent(String(decoding: data, as: UTF8.self))
    }

    private static let first = "The first part of this long dictation covers the budget review for October."
    private static let second = "The second part lists the three vendors we still need to call this week."
    private static let third = "And the last part says to send it all to Dana."
    /// Quiet pauses in seconds 23 and 47 place Murmur's boundaries at 24 s and
    /// 48 s; the terminal commit covers 48–54 s.
    private static let pauses: Set<Int> = [23, 47]

    // MARK: - Proven coverage

    /// The 2026-10-15 field hold: 53.8 s on default (manual) settings, which
    /// previously always fell back to batch. Murmur now commits at the pauses,
    /// the server never needs to auto-commit, and the stream result is accepted.
    func testFiftyFourSecondHoldWithMurmurSegmentsIsAcceptedInAudioOrder() async throws {
        let transport = Transport()
        let session = try await startedSession(transport)
        await hold(session, transport, seconds: 0..<36, quietSeconds: Self.pauses)
        commit(session, Self.first)
        await hold(session, transport, seconds: 36..<54, quietSeconds: Self.pauses)
        commit(session, Self.second)
        XCTAssertEqual(transport.commitOffsetsSeconds, [24, 48])

        let coordinator = StreamingCoordinator(elevenLabsSession: session)
        let success = expectation(description: "long stream accepted")
        let buffer = Self.pcm(seconds: 1, amplitude: Self.loud)
        XCTAssertTrue(coordinator.handleStopElevenLabs(
            context: .init(duration: 53.8, hadSpeech: true, bufferedAudio: [buffer], streamTextEver: true),
            onSilence: { XCTFail("unexpected silence") },
            onStreamSuccess: { text in
                XCTAssertEqual(text, [Self.first, Self.second, Self.third].joined(separator: " "))
                success.fulfill()
            },
            onBatchFallback: { _, _ in XCTFail("proven long hold fell back to batch") }
        ))
        try? await Task.sleep(nanoseconds: 50_000_000)
        commit(session, Self.third)
        await fulfillment(of: [success], timeout: 1.5)
        XCTAssertFalse(session.requiresBufferedAudioRecovery)
        // Two mid-hold boundaries plus the empty terminal commit after 54 s.
        XCTAssertEqual(transport.commitOffsetsSeconds, [24, 48, 54])
        XCTAssertEqual(transport.all.last?.samples, 0)
    }

    /// Mid-hold events can still be in flight at release. They answer the
    /// earlier commits, must not complete finalize, and land in commit order.
    func testMidHoldCommitsAnsweredAfterReleaseKeepCommitOrder() async throws {
        let transport = Transport()
        let session = try await startedSession(transport)
        await hold(session, transport, seconds: 0..<54, quietSeconds: Self.pauses)
        let finalizer = Task { await session.finalize(recordingDuration: 54) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        commit(session, Self.first)
        try? await Task.sleep(nanoseconds: 300_000_000) // past the quiet drain
        commit(session, Self.second)
        try? await Task.sleep(nanoseconds: 300_000_000)
        commit(session, Self.third)
        let text = await finalizer.value
        XCTAssertEqual(text, [Self.first, Self.second, Self.third].joined(separator: " "))
        XCTAssertFalse(session.requiresBufferedAudioRecovery)
    }

    /// When the boundary chunk is also the last chunk, no audio follows the
    /// last mid-hold commit: that commit is terminal and no empty one is sent.
    func testCommitOnFinalChunkNeedsNoExtraTerminalCommit() async throws {
        let transport = Transport()
        let session = try await startedSession(transport)
        await hold(session, transport, seconds: 0..<24, quietSeconds: [23])
        let finalizer = Task { await session.finalize(recordingDuration: 24) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        commit(session, Self.first)
        let text = await finalizer.value
        XCTAssertEqual(text, Self.first)
        XCTAssertFalse(session.requiresBufferedAudioRecovery)
        XCTAssertEqual(transport.commitOffsetsSeconds, [24])
        XCTAssertEqual(transport.all.count, 24)
    }

    func testShortSingleSegmentHoldSendsOnlyTheTerminalCommit() async throws {
        let transport = Transport()
        let session = try await startedSession(transport)
        await hold(session, transport, seconds: 0..<8, quietSeconds: [3])
        let finalizer = Task { await session.finalize(recordingDuration: 8) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        commit(session, Self.third)
        let text = await finalizer.value
        XCTAssertEqual(text, Self.third)
        XCTAssertFalse(session.requiresBufferedAudioRecovery)
        XCTAssertEqual(transport.commitOffsetsSeconds, [8])
    }

    // MARK: - Unproven coverage still recovers from buffered audio

    /// A server-chosen commit (the old ~36 s auto-commit) cannot be placed in
    /// the audio, so the hold recovers from the recording without even sending
    /// the terminal commit.
    func testUnsolicitedServerCommitFallsBackToBufferedAudio() async throws {
        let transport = Transport()
        let session = try await startedSession(transport)
        await hold(session, transport, seconds: 0..<36, quietSeconds: Self.pauses)
        commit(session, Self.first)
        commit(session, "an automatic segment Murmur never asked for")
        await hold(session, transport, seconds: 36..<54, quietSeconds: Self.pauses)
        let startedAt = Date()
        _ = await session.finalize(recordingDuration: 54)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.0)
        XCTAssertTrue(session.requiresBufferedAudioRecovery)
        XCTAssertEqual(transport.commitOffsetsSeconds, [24, 48], "no terminal commit once coverage is disproven")
    }

    /// An extra event after the terminal one is equally unprovable.
    func testExtraCommitAfterTerminalFallsBackToBufferedAudio() async throws {
        let transport = Transport()
        let session = try await startedSession(transport)
        await hold(session, transport, seconds: 0..<8, quietSeconds: [])
        let finalizer = Task { await session.finalize(recordingDuration: 8) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        commit(session, Self.third)
        commit(session, Self.second)
        _ = await finalizer.value
        XCTAssertTrue(session.requiresBufferedAudioRecovery)
    }

    /// One Murmur segment never answered leaves a hole in the audio. The
    /// terminal answer alone must not complete finalize.
    func testMissingMiddleSegmentFallsBackToBufferedAudio() async throws {
        let transport = Transport()
        let session = try await startedSession(transport)
        await hold(session, transport, seconds: 0..<54, quietSeconds: Self.pauses)
        commit(session, Self.first)
        let startedAt = Date()
        let finalizer = Task { await session.finalize(recordingDuration: 54) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        commit(session, Self.third) // answers commit #2, not the terminal #3
        _ = await finalizer.value
        XCTAssertTrue(session.requiresBufferedAudioRecovery)
        // One unanswered mid-hold commit at release adds one bounded step.
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2.4)
    }

    func testMissingTerminalCommitWithinBudgetFallsBackToBufferedAudio() async throws {
        let transport = Transport()
        let session = try await startedSession(transport)
        await hold(session, transport, seconds: 0..<54, quietSeconds: Self.pauses)
        commit(session, Self.first)
        commit(session, Self.second)
        let startedAt = Date()
        let text = await session.finalize(recordingDuration: 54)
        let elapsed = Date().timeIntervalSince(startedAt)
        XCTAssertTrue(session.requiresBufferedAudioRecovery)
        XCTAssertGreaterThanOrEqual(elapsed, 1.4)
        XCTAssertLessThan(elapsed, 1.9)
        XCTAssertEqual(text, [Self.first, Self.second].joined(separator: " "))
        XCTAssertEqual(transport.commitOffsetsSeconds, [24, 48, 54])
    }

    /// Commit counts cannot vouch for audio: one answered 28 s segment must not
    /// pass for a 54 s recording, even though one Murmur segment "could" have
    /// spanned it under the hard limit.
    func testRecordingLongerThanStreamedAudioFallsBackDespiteAnsweredCommit() async throws {
        let transport = Transport()
        let session = try await startedSession(transport)
        await hold(session, transport, seconds: 0..<28, quietSeconds: [])
        XCTAssertEqual(transport.commitOffsetsSeconds, [28])
        commit(session, Self.first)

        let coordinator = StreamingCoordinator(elevenLabsSession: session)
        let fallback = expectation(description: "unstreamed audio recovers from the recording")
        let recording = Self.pcm(seconds: 54, amplitude: Self.loud)
        XCTAssertTrue(coordinator.handleStopElevenLabs(
            context: .init(duration: 54, hadSpeech: true, bufferedAudio: [recording], streamTextEver: true),
            onSilence: { XCTFail("unexpected silence") },
            onStreamSuccess: { _ in XCTFail("26 s of unstreamed audio accepted as covered") },
            onBatchFallback: { buffers, _ in
                XCTAssertTrue(buffers.first === recording)
                fallback.fulfill()
            }
        ))
        await fulfillment(of: [fallback], timeout: 1)
        XCTAssertTrue(session.requiresBufferedAudioRecovery)
        XCTAssertEqual(transport.commitOffsetsSeconds, [28], "the answered commit must not double as terminal")
    }

    /// The tolerance covers converter latency only (0.25 s).
    func testStreamedAudioToleranceIsAQuarterSecond() async throws {
        XCTAssertEqual(ElevenLabsRealtimeTranscriber.streamedAudioToleranceSeconds, 0.25)
        for (recording, recovers) in [(8.2, false), (8.3, true)] {
            let transport = Transport()
            let session = try await startedSession(transport)
            await hold(session, transport, seconds: 0..<8, quietSeconds: [])
            let finalizer = Task { await session.finalize(recordingDuration: recording) }
            try? await Task.sleep(nanoseconds: 50_000_000)
            commit(session, Self.third)
            _ = await finalizer.value
            XCTAssertEqual(session.requiresBufferedAudioRecovery, recovers, "recording \(recording) s")
        }
    }

    /// An empty answer after the segment showed speech must latch at once:
    /// the next segment's partial and commit erase the evidence, and the
    /// commit count still balances.
    func testEmptyAnswerToSpokenSegmentLatchesRecoveryImmediately() async throws {
        let transport = Transport()
        let session = try await startedSession(transport)
        await hold(session, transport, seconds: 0..<36, quietSeconds: Self.pauses)
        partial(session, "the first part of this long dictation covers")
        commit(session, "")
        XCTAssertTrue(session.requiresBufferedAudioRecovery)

        await hold(session, transport, seconds: 36..<54, quietSeconds: Self.pauses)
        partial(session, "the second part lists the three vendors")
        commit(session, Self.second)
        let startedAt = Date()
        let finalizer = Task { await session.finalize(recordingDuration: 54) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        commit(session, Self.third)
        _ = await finalizer.value
        XCTAssertTrue(session.requiresBufferedAudioRecovery)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.0, "disproven coverage needs no terminal wait")
    }

    /// A segment with no partial at all is silence; its empty answer still counts.
    func testEmptyAnswerToSilentSegmentStillCountsAsCovered() async throws {
        let transport = Transport()
        let session = try await startedSession(transport)
        await hold(session, transport, seconds: 0..<36, quietSeconds: Self.pauses)
        commit(session, "")
        await hold(session, transport, seconds: 36..<54, quietSeconds: Self.pauses)
        commit(session, Self.second)
        let finalizer = Task { await session.finalize(recordingDuration: 54) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        commit(session, Self.third)
        let text = await finalizer.value
        XCTAssertEqual(text, [Self.second, Self.third].joined(separator: " "))
        XCTAssertFalse(session.requiresBufferedAudioRecovery)
    }

    /// Audio the tap delivers after finalize closed the queue never reaches
    /// the server; the result must recover from the recording.
    func testAudioCapturedAfterFinalizeBeganLatchesRecovery() async throws {
        let transport = Transport()
        let session = try await startedSession(transport)
        await hold(session, transport, seconds: 0..<8, quietSeconds: [])
        let finalizer = Task { await session.finalize(recordingDuration: 8) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        session.send(Self.pcm(seconds: 1, amplitude: Self.loud))
        commit(session, Self.third)
        _ = await finalizer.value
        XCTAssertTrue(session.requiresBufferedAudioRecovery)
        XCTAssertEqual(transport.all.count, 9, "eight audio chunks and the terminal commit; the late chunk was not sent")
    }

    func testVADStrategyNeverPlacesMurmurCommitsAndStillRecovers() async throws {
        var options = ElevenLabsRealtimeOptions.defaults
        options.commitStrategy = .vad
        let transport = Transport()
        let session = try await startedSession(transport, options: options)
        await hold(session, transport, seconds: 0..<30, quietSeconds: [23])
        XCTAssertEqual(transport.commitOffsetsSeconds, [])
        _ = await session.finalize(recordingDuration: 30)
        XCTAssertTrue(session.requiresBufferedAudioRecovery)
    }

    // MARK: - Boundary rule

    func testBoundaryRuleWaitsForSoftLimitPrefersPauseAndForcesHardLimit() {
        let soft = ElevenLabsRealtimeTranscriber.segmentSoftCommitSamples
        let hard = ElevenLabsRealtimeTranscriber.segmentHardCommitSamples
        XCTAssertFalse(ElevenLabsRealtimeTranscriber.shouldCommitSegment(
            samplesSinceCommit: soft - 1, chunkRMS: 0, segmentMeanRMS: 3000))
        XCTAssertTrue(ElevenLabsRealtimeTranscriber.shouldCommitSegment(
            samplesSinceCommit: soft, chunkRMS: 200, segmentMeanRMS: 3000))
        XCTAssertFalse(ElevenLabsRealtimeTranscriber.shouldCommitSegment(
            samplesSinceCommit: hard - 1, chunkRMS: 3000, segmentMeanRMS: 3000))
        XCTAssertTrue(ElevenLabsRealtimeTranscriber.shouldCommitSegment(
            samplesSinceCommit: hard, chunkRMS: 3000, segmentMeanRMS: 3000))
        // The hard limit stays well under the server's ~36 s auto-commit.
        XCTAssertLessThanOrEqual(hard, 30 * 16_000)
    }

    func testContinuousSpeechIsForcedIntoSegmentsAtHardLimit() async throws {
        let transport = Transport()
        let session = try await startedSession(transport)
        await hold(session, transport, seconds: 0..<60, quietSeconds: [])
        XCTAssertEqual(transport.commitOffsetsSeconds, [28, 56])
        session.cancel()
    }
}
