import XCTest
import AVFoundation
import AudioToolbox
@testable import Voice

final class VoiceIsolationTests: XCTestCase {

    private enum Step: Equatable {
        case enableVoiceProcessing
        case ducking
        case setCurrentDevice(AudioUnitElement)
        case prepare
    }

    private struct EnableFailed: Error {}

    private func operations(
        log: @escaping (Step) -> Void,
        enableThrows: Bool = false,
        deviceStatus: OSStatus? = noErr
    ) -> AudioRecorder.MicBindOperations {
        AudioRecorder.MicBindOperations(
            enableVoiceProcessing: {
                log(.enableVoiceProcessing)
                if enableThrows { throw EnableFailed() }
            },
            configureOtherAudioDucking: { log(.ducking) },
            setCurrentDevice: { element in
                log(.setCurrentDevice(element))
                return deviceStatus
            },
            prepare: { log(.prepare) }
        )
    }

    // MARK: - Bind ordering

    func testPlainBindKeepsCurrentDeviceBeforePrepareOnElementZero() {
        var steps: [Step] = []
        let outcome = AudioRecorder.performMicBind(voiceProcessing: false, operations(log: { steps.append($0) }))
        XCTAssertEqual(outcome, .bound)
        XCTAssertEqual(steps, [.setCurrentDevice(0), .prepare])
    }

    func testVoiceProcessingIsEnabledBeforeCurrentDeviceWhichStaysBeforePrepare() {
        var steps: [Step] = []
        let outcome = AudioRecorder.performMicBind(voiceProcessing: true, operations(log: { steps.append($0) }))
        XCTAssertEqual(outcome, .bound)
        // VoiceProcessingIO takes the input device on element 1; element 0
        // is its output device.
        XCTAssertEqual(steps, [.enableVoiceProcessing, .ducking, .setCurrentDevice(1), .prepare])
    }

    func testVoiceProcessingEnableFailureStopsBeforeTouchingTheDevice() {
        var steps: [Step] = []
        let outcome = AudioRecorder.performMicBind(
            voiceProcessing: true,
            operations(log: { steps.append($0) }, enableThrows: true)
        )
        XCTAssertEqual(outcome, .voiceProcessingFailed)
        XCTAssertEqual(steps, [.enableVoiceProcessing])
    }

    func testCurrentDeviceFailureNeverPrepares() {
        for voiceProcessing in [false, true] {
            var steps: [Step] = []
            let outcome = AudioRecorder.performMicBind(
                voiceProcessing: voiceProcessing,
                operations(log: { steps.append($0) }, deviceStatus: kAudioUnitErr_InvalidProperty)
            )
            XCTAssertEqual(outcome, .setCurrentDeviceFailed(kAudioUnitErr_InvalidProperty))
            XCTAssertFalse(steps.contains(.prepare))

            steps = []
            let missing = AudioRecorder.performMicBind(
                voiceProcessing: voiceProcessing,
                operations(log: { steps.append($0) }, deviceStatus: nil)
            )
            XCTAssertEqual(missing, .inputUnitUnavailable)
            XCTAssertFalse(steps.contains(.prepare))
        }
    }

    // MARK: - Input node stays inside the exception catcher

    func testDefaultOffBindFirstTouchesInputNodeInsideTheCatcher() throws {
        // Default off never replaces the engine before binding, and that
        // decision reads no input-node state.
        XCTAssertFalse(AudioRecorder.plainBindNeedsFreshEngine(
            wantsVoiceProcessing: false, engineHasVoiceProcessing: false))
        XCTAssertTrue(AudioRecorder.plainBindNeedsFreshEngine(
            wantsVoiceProcessing: false, engineHasVoiceProcessing: true))
        XCTAssertFalse(AudioRecorder.plainBindNeedsFreshEngine(
            wantsVoiceProcessing: true, engineHasVoiceProcessing: true))

        let node = FakeMicInputNode()
        var steps: [String] = []
        let (result, format) = AudioRecorder.catchingMicBind(
            deviceID: 42,
            voiceProcessing: false,
            inputNode: { node.resolutions.append(node.insideCatcher); return node },
            prepare: { steps.append("prepare(inside=\(node.insideCatcher))") },
            catcher: node.catcher
        )
        XCTAssertEqual(try result.get(), .bound)
        XCTAssertNil(format, "The plain path reads no format inside the bind")
        XCTAssertEqual(node.resolutions, [true], "First inputNode access must be inside the catcher")
        XCTAssertEqual(node.calls, ["setCurrentDevice(42, 0)"])
        XCTAssertEqual(steps, ["prepare(inside=true)"])
    }

    func testVoiceProcessingBindReadsFormatInsideTheCatcher() throws {
        let node = FakeMicInputNode()
        let (result, format) = AudioRecorder.catchingMicBind(
            deviceID: 42,
            voiceProcessing: true,
            inputNode: { node.resolutions.append(node.insideCatcher); return node },
            prepare: {},
            catcher: node.catcher
        )
        XCTAssertEqual(try result.get(), .bound)
        XCTAssertEqual(format?.channelCount, 9)
        XCTAssertFalse(node.resolutions.isEmpty)
        XCTAssertTrue(node.resolutions.allSatisfy { $0 }, "Every inputNode access must be inside the catcher")
        XCTAssertEqual(node.calls, ["enable", "ducking", "setCurrentDevice(42, 1)", "format"])
    }

    func testCaughtExceptionReportsFailureWithoutFormat() {
        let node = FakeMicInputNode()
        let (result, format) = AudioRecorder.catchingMicBind(
            deviceID: 42,
            voiceProcessing: true,
            inputNode: { node },
            prepare: {},
            catcher: { _ in .failure(NSError(domain: "NSException", code: 0)) }
        )
        guard case .failure = result else { return XCTFail("Expected the caught exception") }
        XCTAssertNil(format)
    }

    func testVoiceProcessingOnlyForBuiltInStoppedUnsuppressedWithSettingOn() {
        XCTAssertTrue(AudioRecorder.shouldEnableVoiceProcessing(
            settingOn: true, deviceIsBuiltIn: true, suppressed: false, engineRunning: false))
        XCTAssertFalse(AudioRecorder.shouldEnableVoiceProcessing(
            settingOn: false, deviceIsBuiltIn: true, suppressed: false, engineRunning: false))
        XCTAssertFalse(AudioRecorder.shouldEnableVoiceProcessing(
            settingOn: true, deviceIsBuiltIn: false, suppressed: false, engineRunning: false))
        XCTAssertFalse(AudioRecorder.shouldEnableVoiceProcessing(
            settingOn: true, deviceIsBuiltIn: true, suppressed: true, engineRunning: false))
        XCTAssertFalse(AudioRecorder.shouldEnableVoiceProcessing(
            settingOn: true, deviceIsBuiltIn: true, suppressed: false, engineRunning: true))
    }

    // MARK: - Format and diagnostics helpers

    func testFirstChannelBufferCopiesChannelZeroAsMono() throws {
        // More than two channels needs an explicit layout.
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3))
        let source = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4))
        buffer.frameLength = 4
        for frame in 0..<4 {
            buffer.floatChannelData![0][frame] = Float(frame) * 0.1
            buffer.floatChannelData![1][frame] = 0.9
            buffer.floatChannelData![2][frame] = -0.9
        }
        let mono = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let out = try XCTUnwrap(AudioRecorder.firstChannelBuffer(of: buffer, format: mono))
        XCTAssertEqual(out.format.channelCount, 1)
        XCTAssertEqual(out.frameLength, 4)
        for frame in 0..<4 {
            XCTAssertEqual(out.floatChannelData![0][frame], Float(frame) * 0.1, accuracy: 0.000_001)
        }

        let wrongRate = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        XCTAssertNil(AudioRecorder.firstChannelBuffer(of: buffer, format: wrongRate))
    }

    func testSpeechLevelStatsReportPercentilesInDBFS() throws {
        XCTAssertNil(AudioRecorder.speechLevelStatsDBFS([]))
        // 0.001 = -60 dBFS, 0.1 = -20 dBFS.
        let values = [Float](repeating: 0.001, count: 5) + [Float](repeating: 0.1, count: 5)
        let stats = try XCTUnwrap(AudioRecorder.speechLevelStatsDBFS(values))
        XCTAssertEqual(stats.p90, -20, accuracy: 0.01)
        XCTAssertEqual(stats.p10, -60, accuracy: 0.01)
        XCTAssertEqual(stats.snr, 40, accuracy: 0.01)
        XCTAssertEqual(AudioRecorder.dBFS(0), -140, accuracy: 0.01, "Digital silence is floored, not -inf")
    }

    // MARK: - Recorder plumbing and fallback

    @MainActor
    func testSettingOnBindsBuiltInMicWithVoiceProcessing() {
        let clock = VoiceIsolationTestClock()
        let hooks = AudioRecorder.MicCaptureTestHooks(schedule: clock.schedule, now: { clock.date })
        let recorder = AudioRecorder(micCaptureTestHooks: hooks)
        recorder.voiceIsolationProvider = { true }
        recorder.beginMicCaptureForTesting()
        XCTAssertEqual(hooks.voiceProcessingAtStart, [true])
        XCTAssertTrue(recorder.voiceProcessingStateForTesting.active)
    }

    @MainActor
    func testSettingOffOrNonBuiltInMicKeepsStandardCapture() {
        for (setting, builtIn) in [(false, true), (true, false), (false, false)] {
            let clock = VoiceIsolationTestClock()
            let hooks = AudioRecorder.MicCaptureTestHooks(schedule: clock.schedule, now: { clock.date })
            hooks.boundDeviceIsBuiltIn = builtIn
            let recorder = AudioRecorder(micCaptureTestHooks: hooks)
            recorder.voiceIsolationProvider = { setting }
            recorder.beginMicCaptureForTesting()
            XCTAssertEqual(hooks.voiceProcessingAtStart, [false], "setting=\(setting) builtIn=\(builtIn)")
        }
    }

    @MainActor
    func testVoiceProcessingStartFailureRetriesSameHoldOnStandardPath() throws {
        let clock = VoiceIsolationTestClock()
        let hooks = AudioRecorder.MicCaptureTestHooks(schedule: clock.schedule, now: { clock.date })
        hooks.startErrors = [NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FailedInitialization))]
        let recorder = AudioRecorder(micCaptureTestHooks: hooks)
        recorder.voiceIsolationProvider = { true }
        var failures: [String] = []
        recorder.asrSelector.onFailure = { failures.append($0.message) }

        recorder.beginMicCaptureForTesting()

        XCTAssertEqual(hooks.voiceProcessingAtStart, [false], "Retry must run without voice processing")
        XCTAssertEqual(hooks.successfulStarts, 1)
        XCTAssertTrue(recorder.micCaptureStateForTesting.wanted, "A voice-processing failure must not end the hold")
        XCTAssertNotNil(recorder.voiceProcessingStateForTesting.suppressedReason)

        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: hooks.format, frameCapacity: 160))
        buffer.frameLength = 160
        for frame in 0..<160 { buffer.floatChannelData![0][frame] = 0.1 }
        try XCTUnwrap(hooks.receiveBuffer)(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
        clock.advance(to: 0.8)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(recorder.micCaptureStateForTesting.buffers.count, 1)

        // Suppression outlives the hold: the next start skips voice processing.
        recorder.beginMicCaptureForTesting()
        XCTAssertEqual(hooks.voiceProcessingAtStart, [false, false])
    }

    @MainActor
    func testSilentVoiceProcessingTapRestartsOnStandardPathWithoutExcludingTheMic() throws {
        let clock = VoiceIsolationTestClock()
        let hooks = AudioRecorder.MicCaptureTestHooks(schedule: clock.schedule, now: { clock.date })
        let recorder = AudioRecorder(micCaptureTestHooks: hooks)
        recorder.voiceIsolationProvider = { true }
        var failures: [String] = []
        recorder.asrSelector.onFailure = { failures.append($0.message) }

        recorder.beginMicCaptureForTesting()
        XCTAssertEqual(hooks.voiceProcessingAtStart, [true])
        clock.advance(to: 0.4)

        XCTAssertEqual(hooks.voiceProcessingAtStart, [true, false])
        XCTAssertNotNil(recorder.voiceProcessingStateForTesting.suppressedReason)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: hooks.format, frameCapacity: 160))
        buffer.frameLength = 160
        try XCTUnwrap(hooks.receiveBuffer)(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
        clock.advance(to: 0.8)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(recorder.micCaptureStateForTesting.wanted)
    }

    @MainActor
    func testUnextractableVoiceProcessingBufferIsDroppedAndHoldRestartsOnStandardPath() throws {
        let clock = VoiceIsolationTestClock()
        let hooks = AudioRecorder.MicCaptureTestHooks(schedule: clock.schedule, now: { clock.date })
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3))
        hooks.format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        let recorder = AudioRecorder(micCaptureTestHooks: hooks)
        recorder.voiceIsolationProvider = { true }
        var failures: [String] = []
        recorder.asrSelector.onFailure = { failures.append($0.message) }

        recorder.beginMicCaptureForTesting()
        XCTAssertEqual(hooks.voiceProcessingAtStart, [true])

        // Interleaved: channel 0 can't be copied out as a plain plane.
        let interleaved = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: true, channelLayout: layout))
        let raw = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: interleaved, frameCapacity: 480))
        raw.frameLength = 480
        let receive = try XCTUnwrap(hooks.receiveBuffer)
        receive(raw, AVAudioTime(sampleTime: 0, atRate: 48_000))
        receive(raw, AVAudioTime(sampleTime: 480, atRate: 48_000))

        XCTAssertTrue(recorder.micCaptureStateForTesting.buffers.isEmpty,
                      "Raw voice-processing channels must never be stored")
        clock.advance(to: 0.01)

        XCTAssertEqual(hooks.voiceProcessingAtStart, [true, false], "One restart, without voice processing")
        XCTAssertEqual(recorder.voiceProcessingStateForTesting.suppressedReason, "channel 0 extraction failed")
        XCTAssertFalse(recorder.voiceProcessingStateForTesting.active)
        XCTAssertTrue(recorder.micCaptureStateForTesting.wanted, "A voice-processing failure must not end the hold")
        XCTAssertTrue(failures.isEmpty)
    }
}

private final class FakeMicInputNode: AudioRecorder.MicBindInputNode {
    var insideCatcher = false
    var resolutions: [Bool] = []
    var calls: [String] = []

    func catcher(_ body: @escaping () -> Void) -> Result<Void, NSError> {
        insideCatcher = true
        body()
        insideCatcher = false
        return .success(())
    }

    func enableVoiceProcessing() throws { calls.append("enable") }
    func setMinimumOtherAudioDucking() { calls.append("ducking") }
    func setCurrentDevice(_ deviceID: AudioDeviceID, element: AudioUnitElement) -> OSStatus? {
        calls.append("setCurrentDevice(\(deviceID), \(element))")
        return noErr
    }
    var boundOutputFormat: AVAudioFormat {
        calls.append("format")
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 9)!
        return AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
    }
}

private final class VoiceIsolationTestClock {
    private(set) var now: TimeInterval = 0
    var date: Date { Date(timeIntervalSince1970: now) }
    private var pending: [(deadline: TimeInterval, action: () -> Void)] = []

    func schedule(after delay: TimeInterval, action: @escaping () -> Void) {
        pending.append((now + delay, action))
    }

    func advance(to target: TimeInterval) {
        while let next = pending.indices.min(by: { pending[$0].deadline < pending[$1].deadline }),
              pending[next].deadline <= target {
            let event = pending.remove(at: next)
            now = event.deadline
            event.action()
        }
        now = target
    }
}
