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
        pcm(samples: Int(16_000 * seconds), amplitude: amplitude)
    }

    private static func pcm(samples: Int, amplitude: Int16) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                   channels: 1, interleaved: true)!
        let frames = AVAudioFrameCount(samples)
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

    /// Commit counts cannot vouch for audio: one answered 33 s segment must not
    /// pass for a 54 s recording, even though one Murmur segment "could" have
    /// spanned it under the hard limit.
    func testRecordingLongerThanStreamedAudioFallsBackDespiteAnsweredCommit() async throws {
        let transport = Transport()
        let session = try await startedSession(transport)
        await hold(session, transport, seconds: 0..<33, quietSeconds: [])
        XCTAssertEqual(transport.commitOffsetsSeconds, [33])
        commit(session, Self.first)

        let coordinator = StreamingCoordinator(elevenLabsSession: session)
        let fallback = expectation(description: "unstreamed audio recovers from the recording")
        let recording = Self.pcm(seconds: 54, amplitude: Self.loud)
        XCTAssertTrue(coordinator.handleStopElevenLabs(
            context: .init(duration: 54, hadSpeech: true, bufferedAudio: [recording], streamTextEver: true),
            onSilence: { XCTFail("unexpected silence") },
            onStreamSuccess: { _ in XCTFail("21 s of unstreamed audio accepted as covered") },
            onBatchFallback: { buffers, _ in
                XCTAssertTrue(buffers.first === recording)
                fallback.fulfill()
            }
        ))
        await fulfillment(of: [fallback], timeout: 1)
        XCTAssertTrue(session.requiresBufferedAudioRecovery)
        XCTAssertEqual(transport.commitOffsetsSeconds, [33], "the answered commit must not double as terminal")
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

    // MARK: - Converter tail

    /// 48 kHz float, the shape the mic tap delivers.
    private static func micBuffer(frames: Int, offset: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames {
            buffer.floatChannelData![0][index] = sin(Float(offset + index) * 0.05) * 0.5
        }
        return buffer
    }

    /// The resampler keeps samples back until end-of-stream. Finalize must
    /// flush them as audio, counted as sent, before the terminal commit.
    func testResamplerTailWithheldUntilEndOfStreamIsSentBeforeTerminalCommit() async throws {
        let transport = Transport()
        let session = try await startedSession(transport)
        let chunks = 10, frames = 4096
        for chunk in 0..<chunks {
            session.send(Self.micBuffer(frames: frames, offset: chunk * frames))
        }
        let deadline = Date().addingTimeInterval(2)
        while transport.all.count < chunks, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let expected = Int((Double(chunks * frames) / 3).rounded())
        let streamedBeforeFinalize = transport.all.reduce(0) { $0 + $1.samples }
        XCTAssertLessThan(streamedBeforeFinalize, expected, "fixture premise: the converter withholds a tail")

        let finalizer = Task { await session.finalize(recordingDuration: Double(chunks * frames) / 48_000) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        commit(session, Self.third)
        let text = await finalizer.value
        XCTAssertEqual(text, Self.third)
        XCTAssertFalse(session.requiresBufferedAudioRecovery)

        let sent = transport.all
        XCTAssertEqual(sent.count, chunks + 2, "audio chunks, the drained tail, then the terminal commit")
        XCTAssertEqual(sent[chunks].samples, expected - streamedBeforeFinalize)
        XCTAssertFalse(sent[chunks].commit)
        XCTAssertEqual(sent.last?.commit, true)
        XCTAssertEqual(sent.last?.samples, 0)
        XCTAssertEqual(sent.reduce(0) { $0 + $1.samples }, expected)
    }

    func testFailedConverterDrainLatchesRecoveryWithoutTerminalCommit() async throws {
        let transport = Transport()
        let session = try await startedSession(transport)
        session.drainConverterTail = { _, _ in nil }
        await hold(session, transport, seconds: 0..<8, quietSeconds: [])
        let finalizer = Task { await session.finalize(recordingDuration: 8) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        commit(session, Self.third)
        _ = await finalizer.value
        XCTAssertTrue(session.requiresBufferedAudioRecovery)
        XCTAssertEqual(transport.commitOffsetsSeconds, [], "an unsent tail cannot be answered by a commit")
    }

    // MARK: - In-flight conversion at release

    /// Holds one `send(_:)` between conversion and enqueue.
    private final class ConversionGate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var armed = false

        func arm() { lock.withLock { armed = true } }
        func pass() {
            let wait = lock.withLock { () -> Bool in
                defer { armed = false }
                return armed
            }
            guard wait else { return }
            entered.signal()
            release.wait()
        }

        /// Starts a send on another thread and returns once it is converting.
        func sendHeld(_ session: ElevenLabsRealtimeTranscriber, _ buffer: AVAudioPCMBuffer) async {
            arm()
            DispatchQueue.global().async { session.send(buffer) }
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    self.entered.wait()
                    done.resume()
                }
            }
        }
    }

    /// The final buffer is mid-conversion when finalize starts. Finalize must
    /// wait for it and send it ahead of the terminal commit.
    func testFinalizeWaitsForInFlightConversionBeforeTerminalCommit() async throws {
        let transport = Transport()
        let session = try await startedSession(transport)
        let gate = ConversionGate()
        session.afterConversionHook = { gate.pass() }
        await hold(session, transport, seconds: 0..<8, quietSeconds: [])
        await gate.sendHeld(session, Self.pcm(seconds: 1, amplitude: Self.loud))

        let finalizer = Task { await session.finalize(recordingDuration: 9) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.all.count, 8, "no terminal commit while a conversion is in flight")
        gate.release.signal()
        try? await Task.sleep(nanoseconds: 50_000_000)
        commit(session, Self.third)
        let text = await finalizer.value
        XCTAssertEqual(text, Self.third)
        XCTAssertFalse(session.requiresBufferedAudioRecovery)
        XCTAssertEqual(transport.commitOffsetsSeconds, [9], "the held second is streamed before the terminal commit")
    }

    /// A conversion outlasting the settle bound latches recovery before the
    /// result is returned, and its late completion cannot clear it.
    func testConversionOutlastingSettleBoundLatchesRecovery() async throws {
        let transport = Transport()
        let session = try await startedSession(transport)
        let gate = ConversionGate()
        session.afterConversionHook = { gate.pass() }
        await hold(session, transport, seconds: 0..<8, quietSeconds: [])
        await gate.sendHeld(session, Self.pcm(seconds: 1, amplitude: Self.loud))

        let startedAt = Date()
        let finalizer = Task { await session.finalize(recordingDuration: 9) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        commit(session, Self.third) // a prompt reply must not complete finalize
        _ = await finalizer.value
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 0.2)
        XCTAssertTrue(session.requiresBufferedAudioRecovery)
        XCTAssertEqual(transport.commitOffsetsSeconds, [])

        gate.release.signal()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(session.requiresBufferedAudioRecovery)
        XCTAssertEqual(transport.all.count, 8, "the late conversion never reached the transport")
    }

    /// Finalize's state reset must not reopen the late-audio window; only a
    /// user cancel discards it.
    func testAudioAfterResolvedFinalizeLatchesButNotAfterCancel() async throws {
        let transport = Transport()
        let session = try await startedSession(transport)
        await hold(session, transport, seconds: 0..<8, quietSeconds: [])
        let finalizer = Task { await session.finalize(recordingDuration: 8) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        commit(session, Self.third)
        _ = await finalizer.value
        XCTAssertFalse(session.requiresBufferedAudioRecovery)
        session.send(Self.pcm(seconds: 1, amplitude: Self.loud))
        XCTAssertTrue(session.requiresBufferedAudioRecovery)

        let cancelled = try await startedSession(Transport())
        cancelled.cancel()
        cancelled.send(Self.pcm(seconds: 1, amplitude: Self.loud))
        XCTAssertFalse(cancelled.requiresBufferedAudioRecovery)
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

    private typealias Boundary = ElevenLabsRealtimeTranscriber.SegmentBoundary

    /// Feeds `chunks` (samples, RMS) and returns the segment-relative end
    /// offset, in samples, of every chunk that carried a commit.
    private static func boundaries(_ chunks: [(Int, Double)]) -> [Int] {
        var rule = Boundary()
        var offset = 0
        var commits: [Int] = []
        for (samples, rms) in chunks {
            offset += samples
            if rule.admit(samples: samples, rms: rms) { commits.append(offset) }
        }
        return commits
    }

    /// Exactly one commit, on the chunk that crossed the hard limit.
    private static func assertForcedAtHardLimit(
        _ commits: [Int], chunk: Int = 1_365, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(commits.count, 1, "commits: \(commits)", file: file, line: line)
        guard let commit = commits.first else { return }
        XCTAssertGreaterThanOrEqual(commit, Boundary.hardSamples, file: file, line: line)
        XCTAssertLessThan(commit, Boundary.hardSamples + chunk, file: file, line: line)
    }

    /// Repeating tap-sized chunks of steady speech, `seconds` long.
    private static func speech(seconds: Double, sizes: [Int] = [1_365], rms: Double = 3000) -> [(Int, Double)] {
        var chunks: [(Int, Double)] = []
        var total = 0
        let target = Int(seconds * 16_000)
        var index = 0
        while total < target {
            let size = min(sizes[index % sizes.count], target - total)
            chunks.append((size, rms))
            total += size
            index += 1
        }
        return chunks
    }

    func testSingleQuietChunkMidSpeechDoesNotCommit() {
        // The field failure: 21.2 s, one ~85 ms dip between words.
        let chunks = Self.speech(seconds: 21.2) + [(1_365, 200)] + Self.speech(seconds: 14)
        Self.assertForcedAtHardLimit(Self.boundaries(chunks))
    }

    func testSustainedPauseAfterSoftLimitCommitsWhereThePauseIsProven() {
        let speech = Self.speech(seconds: 21)
        let pause = Array(repeating: (1_365, 150.0), count: 6)
        let commits = Self.boundaries(speech + pause + Self.speech(seconds: 5))
        // 4 x 1365 = 5460 is the first run at or past 4800 samples (300 ms).
        XCTAssertEqual(commits, [21 * 16_000 + 4 * 1_365])
    }

    func testPauseBeforeSoftLimitDoesNotCommitButOneSpanningItDoes() {
        let early = Self.speech(seconds: 15) + [(8_000, 150)] + Self.speech(seconds: 4)
        let spanning = early + [(6_000, 150), (6_000, 150)] + Self.speech(seconds: 5)
        // The 15 s pause is ignored. The run starting at 19.5 s is already
        // 375 ms long by 19.875 s but too early; the commit rides on its next
        // chunk, the first past 20 s, still inside the pause.
        XCTAssertEqual(Self.boundaries(spanning), [20 * 16_000 + 4_000])
    }

    func testPauseIsMeasuredInSamplesNotChunks() {
        let speech = Self.speech(seconds: 22, sizes: [512, 4_096, 1_365, 2_000])
        let offset = speech.reduce(0) { $0 + $1.0 }
        // Ten small quiet chunks are only 2560 samples (160 ms): no pause.
        let shortRun = Array(repeating: (256, 100.0), count: 10)
        // Then varied sizes: 1000, 2000, 3000, 4000, 4700 (short), 5000.
        let longRun: [(Int, Double)] = [(1_000, 100), (1_000, 100), (1_000, 100), (1_000, 100), (700, 100), (300, 100), (2_000, 100)]
        let chunks = speech + shortRun + Self.speech(seconds: 1, sizes: [4_096, 512]) + longRun + Self.speech(seconds: 5)
        XCTAssertEqual(Self.boundaries(chunks), [offset + 2_560 + 16_000 + 5_000])
        // One large quiet buffer is a full pause by itself.
        XCTAssertEqual(Self.boundaries(speech + [(4_800, 100)]), [offset + 4_800])
    }

    func testQuietIsRelativeToTheSegmentLevel() {
        // A soft passage (-6 dB) is still speech, not a pause.
        let soft = Self.speech(seconds: 21) + Self.speech(seconds: 2, rms: 1_500) + Self.speech(seconds: 12)
        Self.assertForcedAtHardLimit(Self.boundaries(soft))
    }

    func testNoPauseCommitsAtTheQuietestPointAfterTheLastResortWindowOpens() {
        // Steady speech with ordinary dips to 2000 while observing 30-31 s,
        // then one deeper dip at 31.5 s.
        let observed = Self.speech(seconds: 30) + Self.speech(seconds: 0.5) + [(1_600, 2_000)]
            + Self.speech(seconds: 0.4)
        let lead = observed.reduce(0) { $0 + $1.0 }
        let chunks = observed + Self.speech(seconds: 0.5) + [(1_365, 1_800)] + Self.speech(seconds: 3)
        XCTAssertEqual(Self.boundaries(chunks), [lead + 8_000 + 1_365])
    }

    func testNoPauseAndNoDeeperDipForcesTheHardLimit() {
        let hard = Boundary.hardSamples
        Self.assertForcedAtHardLimit(Self.boundaries(Self.speech(seconds: 40)))
        // The forced segment stays under the ~36 s auto-commit even when the
        // crossing chunk is a full second long.
        XCTAssertEqual(Self.boundaries(Self.speech(seconds: 32.5) + [(16_000, 3000)]), [hard + 8_000])
        XCTAssertLessThanOrEqual(hard + 16_000, 35 * 16_000)
        XCTAssertEqual(ElevenLabsRealtimeTranscriber.segmentSoftCommitSamples, 20 * 16_000)
        XCTAssertEqual(ElevenLabsRealtimeTranscriber.segmentHardCommitSamples, 33 * 16_000)
    }

    func testEmptyChunksNeverCommit() {
        let chunks = Self.speech(seconds: 32) + Array(repeating: (0, 0.0), count: 5)
        XCTAssertEqual(Self.boundaries(chunks), [])
    }

    func testContinuousSpeechIsForcedIntoSegmentsAtHardLimit() async throws {
        let transport = Transport()
        let session = try await startedSession(transport)
        await hold(session, transport, seconds: 0..<70, quietSeconds: [])
        XCTAssertEqual(transport.commitOffsetsSeconds, [33, 66])
        session.cancel()
    }

    /// Through the real send path with tap-sized buffers: a dip between
    /// words at 21 s stays inside the segment; the 300 ms pause at 24 s
    /// carries the commit.
    func testTapSizedBuffersCommitAtTheRealPauseNotTheDip() async throws {
        let transport = Transport()
        let session = try await startedSession(transport)
        func chunk(_ samples: Int, _ amplitude: Int16) {
            session.send(Self.pcm(samples: samples, amplitude: amplitude))
        }
        var sent = 0
        func speak(seconds: Double) {
            let target = sent + Int(seconds * 16_000)
            while sent < target {
                let size = min(1_365, target - sent)
                chunk(size, Self.loud)
                sent += size
            }
        }
        speak(seconds: 21)
        chunk(1_365, Self.quiet); sent += 1_365
        speak(seconds: 3)
        let pauseStart = sent
        for _ in 0..<6 { chunk(1_365, Self.quiet); sent += 1_365 }
        speak(seconds: 2)
        let deadline = Date().addingTimeInterval(2)
        while transport.all.reduce(0, { $0 + $1.samples }) < sent, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(transport.commitOffsetsSeconds, [Double(pauseStart + 4 * 1_365) / 16_000])
        session.cancel()
    }
}
