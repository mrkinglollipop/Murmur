import XCTest
import Foundation
import AVFoundation
@testable import Voice

final class MicHealthTests: XCTestCase {

    @MainActor
    func testRecoveryWithoutReplacementBuffersFailsAndPreservesEarlierSpeech() throws {
        let clock = MicHealthTestClock()
        let hooks = AudioRecorder.MicCaptureTestHooks(schedule: clock.schedule, now: { clock.date })
        let recorder = AudioRecorder(micCaptureTestHooks: hooks)
        var failures: [String] = []
        recorder.asrSelector.onFailure = { failures.append($0.message) }
        recorder.beginMicCaptureForTesting()
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: hooks.format, frameCapacity: 160))
        buffer.frameLength = 160
        for frame in 0..<160 { buffer.floatChannelData![0][frame] = 0.1 }
        let receive = try XCTUnwrap(hooks.receiveBuffer)
        receive(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
        clock.advance(to: 0.4)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(recorder.micCaptureStateForTesting.buffers.count, 1)

        hooks.engineRunning = false
        recorder.microphoneConfigurationChangedForTesting()
        XCTAssertEqual(hooks.successfulStarts, 2)
        clock.advance(to: 0.8)

        XCTAssertEqual(failures.count, 1, "Replacement tap delivered no buffers for 400 ms")
        XCTAssertFalse(recorder.micCaptureStateForTesting.wanted)
        let saved = try XCTUnwrap(AudioRecorder.combine(buffers: recorder.micCaptureStateForTesting.buffers))
        XCTAssertEqual(saved.frameLength, 160)
        XCTAssertEqual(saved.floatChannelData![0][159], 0.1, accuracy: 0.0001)
        XCTAssertGreaterThan(recorder.micCaptureStateForTesting.maxRMS, 0.09)
    }

    @MainActor
    func testExhaustedToggleCaptureAllowsNextOrdinaryHold() {
        let clock = MicHealthTestClock()
        let hooks = AudioRecorder.MicCaptureTestHooks(schedule: clock.schedule, now: { clock.date })
        let recorder = AudioRecorder(micCaptureTestHooks: hooks)
        let activation = ActivationController(recorder: recorder)
        lockToggle(activation, clock: clock)
        recorder.beginMicCaptureForTesting()
        clock.advance(to: 0.8)
        XCTAssertEqual(hooks.successfulStarts, 2)
        XCTAssertFalse(recorder.micCaptureStateForTesting.wanted)
        XCTAssertFalse(activation.fnStateForTesting.isToggleLocked)
        XCTAssertFalse(activation.fnStateForTesting.isRecording)
        XCTAssertTrue(activation.fnStateForTesting.fnPhysicallyDown, "Failure must preserve physical key state")
        XCTAssertNil(activation.fnStateForTesting.firstTapAnchor)
        XCTAssertNil(activation.fnStateForTesting.holdDeadline)
        XCTAssertEqual(activation.fnTransitionForTesting(down: true, now: clock.date), [], "Repeated down is not a new press")
        _ = activation.fnTransitionForTesting(down: false, now: clock.date)
        clock.advance(to: 1)
        let effects = activation.fnTransitionForTesting(down: true, now: clock.date)
        XCTAssertEqual(effects, [.scheduleHoldTimer(deadline: clock.date.addingTimeInterval(FnActivationLogic.holdThreshold))])
        clock.advance(to: 1.2)
        let timerEffects = activation.fnHoldTimerForTesting(now: clock.date)
        XCTAssertEqual(timerEffects, [.startRecording])
        if timerEffects.contains(.startRecording) { recorder.beginMicCaptureForTesting() }
        XCTAssertEqual(hooks.successfulStarts, 3)
        XCTAssertTrue(recorder.micCaptureStateForTesting.wanted)
        // Leave the controller idle so deinit cannot enter a real stop pipeline.
        _ = activation.fnTransitionForTesting(down: false, now: clock.date)
    }

    @MainActor
    func testRecoveryBindFailureEndsCloudToggleCaptureAndWarningPolling() {
        let clock = MicHealthTestClock()
        let hooks = AudioRecorder.MicCaptureTestHooks(schedule: clock.schedule, now: { clock.date })
        let session = XAIStreamingTranscriber(apiKey: "dummy", messageSender: { _ in XCTFail("No network frames expected") })
        session.handleServerEvent(#"{"type":"transcript.partial","text":"earlier speech","is_final":false}"#)
        XCTAssertEqual(session.joinedTranscriptSnapshot(), "earlier speech")
        let streaming = StreamingCoordinator(xaiSession: session)
        let recorder = AudioRecorder(micCaptureTestHooks: hooks, streamingCoordinator: streaming)
        let activation = ActivationController(recorder: recorder)
        lockToggle(activation, clock: clock)
        var failures: [String] = []
        recorder.asrSelector.onFailure = { failures.append($0.message) }
        recorder.beginMicCaptureForTesting()
        hooks.boundDeviceID = nil
        clock.advance(to: 0.4)

        XCTAssertEqual(hooks.successfulStarts, 1)
        XCTAssertEqual(failures.count, 1)
        XCTAssertFalse(recorder.micCaptureStateForTesting.wanted)
        XCTAssertTrue(recorder.micCaptureStateForTesting.stopping)
        XCTAssertFalse(recorder.micCaptureStateForTesting.tapInstalled)
        XCTAssertNil(streaming.xaiSession)
        XCTAssertEqual(session.joinedTranscriptSnapshot(), "", "Cancellation must reach the retained cloud session")
        XCTAssertFalse(activation.fnStateForTesting.isToggleLocked)
        clock.advance(to: 2)
        XCTAssertEqual(clock.pendingCount, 0, "Terminal failure must stop the warning poll")
        XCTAssertEqual(failures.count, 1)
        _ = activation.fnTransitionForTesting(down: false, now: clock.date)
        _ = activation.fnTransitionForTesting(down: true, now: clock.date)
        _ = activation.fnTransitionForTesting(down: false, now: clock.date)
        // Baseline failures must not leave a real stop/network operation in deinit.
        session.cancel()
    }

    @MainActor
    private func lockToggle(_ activation: ActivationController, clock: MicHealthTestClock) {
        _ = activation.fnTransitionForTesting(down: true, now: clock.date.addingTimeInterval(-0.2))
        _ = activation.fnTransitionForTesting(down: false, now: clock.date.addingTimeInterval(-0.1))
        XCTAssertTrue(activation.fnTransitionForTesting(down: true, now: clock.date).contains(.startRecording))
        XCTAssertTrue(activation.fnStateForTesting.isToggleLocked)
    }

    func testZeroBufferWatchdogIgnoresStaleStoppedOrUntappedCapture() {
        for alreadyRetried in [false, true] {
            for state in [(false, true, true), (true, false, true), (true, true, false)] {
                XCTAssertEqual(
                    MicHealth.zeroBufferAction(
                        generationMatches: state.0, stillWanted: state.1,
                        tapInstalled: state.2, buffersSeen: 0,
                        alreadyRetried: alreadyRetried
                    ), .ignore
                )
            }
        }
    }

    func testZeroBufferWatchdogPreservesDeliveredAudioBeforeAndAfterRetry() {
        for alreadyRetried in [false, true] {
            XCTAssertEqual(
                MicHealth.zeroBufferAction(
                    generationMatches: true, stillWanted: true,
                    tapInstalled: true, buffersSeen: 1,
                    alreadyRetried: alreadyRetried
                ), .ignore
            )
        }
    }

    func testHealthyExplicitMicrophoneSurvivesUnrelatedDefaultInputChange() {
        // USB A stays selected while Sound Input moves from B to C.
        for systemDefault: UInt32 in [145, 200] {
            XCTAssertEqual(
                MicHealth.inputRerouteAction(
                    lastBound: 81, currentDefault: systemDefault,
                    boundUID: "usb-a", preferredUID: "usb-a",
                    boundIsHealthy: true, engineRunning: true
                ),
                .keepCapture
            )
        }
    }

    func testAutomaticOrUnavailablePreferenceStillFollowsDefaultReroute() {
        for preference: String? in [nil, "missing-usb"] {
            XCTAssertEqual(
                MicHealth.inputRerouteAction(
                    lastBound: 81, currentDefault: 145,
                    boundUID: "usb-a", preferredUID: preference,
                    boundIsHealthy: true, engineRunning: true
                ),
                .rebuild(excluding: 81)
            )
        }
        XCTAssertEqual(
            MicHealth.inputRerouteAction(
                lastBound: 81, currentDefault: 145,
                boundUID: "usb-a", preferredUID: "usb-a",
                boundIsHealthy: false, engineRunning: true
            ),
            .rebuild(excluding: 81)
        )
    }

    func testZeroCallbacksWarnAfterSuccessfulStartAndRecovery() {
        let clock = MicHealthTestClock()
        var engineRunning = false
        var active = true
        var maxRMS: Float = 0
        var device = "USB A"
        var visibleWarning: String?
        let monitor = MicHealthWarningMonitor(
            snapshot: {
                guard active else { return nil }
                return .init(elapsed: clock.now, maxRMS: maxRMS,
                             engineRunning: engineRunning, deviceName: device)
            },
            warning: { visibleWarning = $0 },
            schedule: clock.schedule
        )
        engineRunning = true
        clock.advance(to: 0.4)
        engineRunning = false
        clock.advance(to: 0.6)
        device = "Fallback microphone"
        engineRunning = true
        clock.advance(to: 1.49)
        XCTAssertNil(visibleWarning)
        // Neither successful start delivered a buffer callback.
        clock.advance(to: 1.6)
        XCTAssertEqual(visibleWarning, "Fallback microphone")
        maxRMS = 0.02
        monitor.evaluate()
        XCTAssertNil(visibleWarning)
        active = false
        clock.advance(to: 2)
        XCTAssertEqual(clock.pendingCount, 0)
    }

    func testWarningPollSurvivesRecoveryAcrossWarningDeadline() {
        let clock = MicHealthTestClock()
        var engineRunning = false
        var visibleWarning: String?
        let monitor = MicHealthWarningMonitor(
            snapshot: {
                .init(elapsed: clock.now, maxRMS: 0,
                      engineRunning: engineRunning, deviceName: "USB A")
            },
            warning: { visibleWarning = $0 },
            schedule: clock.schedule
        )
        clock.advance(to: 1.6)
        XCTAssertNil(visibleWarning)
        engineRunning = true
        clock.advance(to: 2)
        XCTAssertEqual(visibleWarning, "USB A")
        withExtendedLifetime(monitor) {}
    }

    func testEndedHoldCannotPublishOrContinuePolling() {
        let clock = MicHealthTestClock()
        var active = true
        var warningCount = 0
        let monitor = MicHealthWarningMonitor(
            snapshot: {
                active ? .init(elapsed: clock.now, maxRMS: 0,
                               engineRunning: true, deviceName: "Old hold") : nil
            },
            warning: { _ in warningCount += 1 },
            schedule: clock.schedule
        )
        clock.advance(to: 1)
        active = false
        clock.advance(to: 3)
        XCTAssertEqual(warningCount, 0)
        XCTAssertEqual(clock.pendingCount, 0)
        withExtendedLifetime(monitor) {}
    }

    func testStoppedEngineRebuildsEvenWhenDeviceIDIsUnchanged() {
        for preference: String? in [nil, "usb-a"] {
            XCTAssertEqual(
                MicHealth.inputRerouteAction(
                    lastBound: 81, currentDefault: 81,
                    boundUID: "usb-a", preferredUID: preference,
                    boundIsHealthy: true, engineRunning: false
                ),
                .rebuild(excluding: nil)
            )
        }
    }

    func testRunningSameDefaultAndTransientMissingDefaultKeepTap() {
        for systemDefault: UInt32? in [81, nil] {
            XCTAssertEqual(
                MicHealth.inputRerouteAction(
                    lastBound: 81, currentDefault: systemDefault,
                    boundUID: "usb-a", preferredUID: nil,
                    boundIsHealthy: true, engineRunning: true
                ),
                .keepCapture
            )
        }
    }

    func testExclusionsRemoveDevicesBeforeSelection() {
        let builtIn = MicrophoneDevice(uid: "builtin", name: "MacBook Microphone")
        let continuity = MicrophoneDevice(uid: "continuity", name: "iPhone Microphone")

        XCTAssertEqual(
            MicHealth.availableDevices([builtIn, continuity], excluding: ["continuity"]),
            [builtIn]
        )
        XCTAssertNil(
            MicHealth.activePreferredUID(
                "continuity",
                availableDevices: [builtIn],
                excluding: ["continuity"]
            )
        )
        XCTAssertEqual(
            MicHealth.activePreferredUID(
                "builtin",
                availableDevices: [builtIn],
                excluding: []
            ),
            "builtin"
        )
    }

    func testAbsentChosenDeviceUsesAutomaticForThisHold() {
        let builtIn = MicrophoneDevice(uid: "builtin", name: "MacBook Microphone")

        XCTAssertNil(
            MicHealth.activePreferredUID(
                "unplugged-usb",
                availableDevices: [builtIn],
                excluding: []
            )
        )
    }

    @MainActor
    func testMicrophoneUIDPreferencesRoundTripThroughInjectedDefaults() throws {
        let suite = "murmur.mic-health.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-mic-health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousDirectory = RecordingRetention.recordingsDirectoryOverride
        RecordingRetention.recordingsDirectoryOverride = directory
        defer {
            RecordingRetention.recordingsDirectoryOverride = previousDirectory
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let store = SettingsStore(
            defaults: defaults,
            profileDirectory: directory,
            apiKeyLookup: { _ in nil }
        )
        store.preferredInputDeviceUID = "usb-uid"
        store.excludedInputDeviceUIDs = ["continuity-uid", "virtual-uid"]

        let reloaded = SettingsStore(
            defaults: defaults,
            profileDirectory: directory,
            apiKeyLookup: { _ in nil }
        )
        XCTAssertEqual(reloaded.preferredInputDeviceUID, "usb-uid")
        XCTAssertEqual(reloaded.excludedInputDeviceUIDs, ["continuity-uid", "virtual-uid"])
        XCTAssertNil(defaults.object(forKey: "voice.settings.preferredInputDeviceID"))
    }

    func testInitialSilenceDoesNotWarnBeforeOnePointFiveSeconds() {
        XCTAssertFalse(
            MicHealth.shouldShowNoAudioWarning(elapsed: 1.4, maxRMS: 0, engineRunning: true)
        )
    }

    func testInitialSilenceWarnsAfterOnePointFiveSeconds() {
        XCTAssertTrue(
            MicHealth.shouldShowNoAudioWarning(elapsed: 1.6, maxRMS: 0, engineRunning: true)
        )
        XCTAssertFalse(
            MicHealth.shouldShowNoAudioWarning(elapsed: 1.6, maxRMS: 0, engineRunning: false)
        )
    }

    func testLoudEarlySampleNeverWarnsLaterInTheHold() {
        for elapsed in [1.0, 1.6, 3.0] {
            XCTAssertFalse(
                MicHealth.shouldShowNoAudioWarning(elapsed: elapsed, maxRMS: 0.02, engineRunning: true)
            )
        }
    }

    func testLoudSampleClearsAnExistingNoAudioHint() {
        XCTAssertTrue(
            MicHealth.shouldShowNoAudioWarning(elapsed: 1.6, maxRMS: 0, engineRunning: true)
        )
        XCTAssertFalse(
            MicHealth.shouldShowNoAudioWarning(elapsed: 1.7, maxRMS: 0.02, engineRunning: true)
        )
    }
}


private final class MicHealthTestClock {
    private(set) var now: TimeInterval = 0
    var date: Date { Date(timeIntervalSince1970: now) }
    private var pending: [(deadline: TimeInterval, action: () -> Void)] = []
    var pendingCount: Int { pending.count }

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
