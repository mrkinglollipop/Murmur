import XCTest
import Foundation
import AVFoundation
import ApplicationServices
@testable import Voice

final class MicHealthTests: XCTestCase {

    private struct CapturedSpeechEngine: ASREngine {
        let id = "captured-speech-fixture"
        let displayName = "Captured speech fixture"
        var started: XCTestExpectation? = nil
        var gate: RecoveryGate? = nil
        func transcribe(audioURL: URL) async throws -> String {
            let file = try AVAudioFile(forReading: audioURL)
            let audio = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 160))
            try file.read(into: audio)
            XCTAssertEqual(audio.frameLength, 160)
            XCTAssertEqual(audio.floatChannelData![0][159], 0.0001, accuracy: 0.000001)
            started?.fulfill()
            await gate?.wait()
            return "Recovered speech."
        }
    }

    private struct HintOnlyEngine: ASREngine {
        let id = "hint-only-fixture"
        let displayName = "Hint-only fixture"
        func transcribe(audioURL: URL) async throws -> String { "" }
    }

    private struct LowLevelSpeechEngine: ASREngine {
        let id = "low-level-speech-fixture"
        let displayName = "Low-level speech fixture"
        let started: XCTestExpectation

        func transcribe(audioURL: URL) async throws -> String {
            XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
            let file = try AVAudioFile(forReading: audioURL)
            XCTAssertEqual(file.length, 32_000)
            let samples = try MicHealthTests.readAllSamples(from: file)
            XCTAssertEqual(samples.count, 32_000)
            XCTAssertEqual(try XCTUnwrap(samples.last), 0.008, accuracy: 0.000_001)
            started.fulfill()
            return "Quiet delivered speech."
        }
    }

    /// AVAudioFile can return a partial read; every delivered frame, including
    /// the final sub-1024-frame tail, must reach the synthetic engine assertion.
    private static func readAllSamples(from file: AVAudioFile) throws -> [Float] {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_024))
        var samples: [Float] = []
        while file.framePosition < file.length {
            let count = AVAudioFrameCount(min(1_024, file.length - file.framePosition))
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else {
                XCTFail("File reader stopped before the captured tail")
                break
            }
            samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0],
                                                           count: Int(buffer.frameLength)))
        }
        return samples
    }

    private actor RecoveryGate {
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private final class RecoveryObserver: TextInjectionObserver {
        var observedUTF16Units = 0
        var observedPasteChordCount = 0
        var keycodeZeroKeyDownCount = 0
        var canaryObservedCount = 0
        var wentBlind = false
        func resetObservedCount() { observedUTF16Units = 0 }
        func resetCanaryCount() { canaryObservedCount = 0 }
        func stop() {}
    }

    @MainActor
    func testTerminalRecoverySavesCapturedSpeechWithoutInjectingAfterSelectionChanges() async throws {
        XCTAssertTrue(isTestHost, "Recorder defaults must use the isolated test data directory")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mic-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = RecordingRetention.recordingsDirectoryOverride
        RecordingRetention.recordingsDirectoryOverride = directory
        defer {
            RecordingRetention.recordingsDirectoryOverride = previous
            try? FileManager.default.removeItem(at: directory)
            TextInjector.resetDedupeStateForTesting()
        }
        for bindFailure in [false, true] {
            for switchedTarget in [false, true] {
                TextInjector.resetDedupeStateForTesting()
                let clock = MicHealthTestClock()
                let hooks = AudioRecorder.MicCaptureTestHooks(schedule: clock.schedule, now: { clock.date })
                let recorder = AudioRecorder(micCaptureTestHooks: hooks)
                let pipeline = recorder.asrSelector.pipeline
                let started = expectation(description: "Recovery ASR started")
                let gate = RecoveryGate()
                pipeline.localEngineProvider = { CapturedSpeechEngine(started: started, gate: gate) }
                let history = HistoryStore(fileURL: directory.appendingPathComponent("history-\(UUID().uuidString).json"))
                let held = CaretContext.Snapshot(value: "", location: 0, selectionLength: .readable(0),
                    precedingChar: .startOfField, isUnknown: false,
                    focusedElement: AXUIElementCreateApplication(42))
                let token = pipeline.test_holdSnapshot(held, frontmostPID: 42)
                recorder.test_prepareHold(token: token)
                recorder.test_seedCachedSessionHold(token: token, snapshot: held, pid: 42)
                let board = NSPasteboard(name: .init("mic-recovery-\(UUID().uuidString)"))
                defer { board.releaseGlobally() }
                board.setString("Existing clipboard", forType: .string)
                let observer = RecoveryObserver()
                var delivered = ""
                var liveSnapshot = held
                var snapshotReads = 0
                pipeline.deliveryHooks = .init(injector: .init(
                    pasteboard: board,
                    target: { .init(secureInput: false, pid: switchedTarget ? 43 : 42, bundleIdentifier: "fixture") },
                    createObserver: { observer },
                    postUnicode: { _ in XCTFail("Use real chunk delivery"); return 0 },
                    postPasteChord: { XCTFail("No paste fallback expected"); return false },
                    postCanary: { false },
                    waitForConfirmation: { _, _ in observer.observedUTF16Units },
                    postUnicodeChunk: { units in
                        delivered += String(decoding: units, as: UTF16.self)
                        observer.observedUTF16Units += units.count
                    }), snapshot: { snapshotReads += 1; return liveSnapshot })
                var failures: [DictationFailure] = []
                recorder.asrSelector.onFailure = { failures.append($0) }
                var rows = 0
                let logged = expectation(description: "Captured audio reaches History: bind=\(bindFailure), switched=\(switchedTarget)")
                pipeline.onTranscriptionLogged = { text, engine, injected, path, failed, _ in
                    XCTAssertEqual(text, "Recovered speech.")
                    XCTAssertEqual(engine, "captured-speech-fixture")
                    XCTAssertFalse(injected, "Terminal recovery must never replace the user's selection")
                    XCTAssertFalse(failed)
                    XCTAssertNotNil(path)
                    XCTAssertTrue(path.map { FileManager.default.fileExists(atPath: $0) } ?? false)
                    history.append(text: text, engine: engine, injected: injected, audioPath: path, failed: failed)
                    rows += 1
                    logged.fulfill()
                }
                pipeline.onAbandonedHoldSaved = { text, engine, path in
                    XCTAssertEqual(text, "Recovered speech.")
                    XCTAssertEqual(engine, "captured-speech-fixture")
                    history.append(text: text, engine: engine, injected: false, audioPath: path, savedWithoutInsertion: true)
                    rows += 1
                    logged.fulfill()
                }
                recorder.beginMicCaptureForTesting()
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: hooks.format, frameCapacity: 160))
                buffer.frameLength = 160
                for frame in 0..<160 { buffer.floatChannelData![0][frame] = 0.0001 }
                try XCTUnwrap(hooks.receiveBuffer)(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
                clock.advance(to: 0.4)
                hooks.engineRunning = false
                if bindFailure { hooks.boundDeviceID = nil }
                recorder.microphoneConfigurationChangedForTesting()
                clock.advance(to: 0.8)
                XCTAssertFalse(recorder.micCaptureStateForTesting.wanted)
                XCTAssertTrue(recorder.micCaptureStateForTesting.stopping)
                XCTAssertEqual(failures, [.micDeliveredNoAudio])
                recorder.stopRecording() // Physical release after terminal failure must not duplicate delivery.
                await fulfillment(of: [started], timeout: 3)
                XCTAssertTrue(pipeline.test_abandonedHoldTokens.contains(token), "Abandon before handing audio to asynchronous ASR")
                recorder.hud.hide()
                liveSnapshot = CaretContext.Snapshot(value: "Unrelated text", location: 0,
                    selectionLength: .readable(14), precedingChar: .startOfField,
                    isUnknown: false, focusedElement: held.focusedElement)
                await gate.release()
                await fulfillment(of: [logged], timeout: 3)
                XCTAssertEqual(rows, 1)
                XCTAssertEqual(delivered, "")
                XCTAssertEqual(snapshotReads, 0, "Abandoned recovery must bypass delivery entirely")
                XCTAssertEqual(board.string(forType: .string), "Existing clipboard")
                XCTAssertFalse(pipeline.test_abandonedHoldTokens.contains(token), "Completion consumes the abandoned token")
                let entry = try XCTUnwrap(history.entries.first)
                XCTAssertEqual(history.entries.count, 1)
                XCTAssertEqual(entry.text, "Recovered speech.")
                XCTAssertFalse(entry.injected)
                XCTAssertTrue(entry.savedWithoutInsertion)
                XCTAssertFalse(entry.failed)
                let audioPath = try XCTUnwrap(entry.audioPath)
                XCTAssertTrue(FileManager.default.fileExists(atPath: audioPath))
                let audio = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
                XCTAssertEqual(audio.length, 160)
                XCTAssertTrue(recorder.test_cachedSessionHoldTokens.isEmpty)
                recorder.hud.hide()
            }
        }
    }

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
        var visibleWarning: MicHealthWarningMonitor.Warning?
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
        XCTAssertEqual(visibleWarning, .noAudio(deviceName: "Fallback microphone"))
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
        var visibleWarning: MicHealthWarningMonitor.Warning?
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
        XCTAssertEqual(visibleWarning, .noAudio(deviceName: "USB A"))
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

    private func frames(_ rms: Float, count: Int) -> [MicHealth.LevelFrame] {
        Array(repeating: .init(rms: rms, duration: MicHealth.levelFrameDuration), count: count)
    }

    private func signal(speechRMS: Float, floorRMS: Float = pow(10, -53 / 20),
                        speechFrames: Int = 10, floorFrames: Int = 10) -> [MicHealth.LevelFrame] {
        frames(floorRMS, count: floorFrames) + frames(speechRMS, count: speechFrames)
    }

    private func isolateHintRecorder(_ recorder: AudioRecorder) {
        recorder.asrSelector.cloudModel = nil
        recorder.asrSelector.apiKeyProvider = { _ in nil }
        recorder.asrSelector.pipeline.localEngineProvider = { HintOnlyEngine() }
    }

    private func deliverFrames(_ levels: [Float], hooks: AudioRecorder.MicCaptureTestHooks) throws {
        let receive = try XCTUnwrap(hooks.receiveBuffer)
        for level in levels {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: hooks.format, frameCapacity: 1_600))
            buffer.frameLength = 1_600
            for frame in 0..<1_600 { buffer.floatChannelData![0][frame] = level }
            receive(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
        }
    }

    func testRoomNoiseWithoutSpeechEvidenceNeverShowsLowLevelHint() {
        var warnings: [MicHealthWarningMonitor.Warning?] = []
        let monitor = MicHealthWarningMonitor(
            snapshot: {
                .init(elapsed: 5, deliveredSeconds: 5, maxRMS: 0.02,
                      engineRunning: true, deviceName: "Fixture microphone",
                      levelFrames: self.frames(pow(10, -47 / 20), count: 50))
            },
            warning: { warnings.append($0) },
            schedule: { _, _ in }
        )
        monitor.evaluate()
        XCTAssertFalse(warnings.contains(.lowLevel), "Room noise cannot establish speech, even after an earlier peak")
    }

    func testLessThanOneSecondOfSpeechNeverShowsLowLevelHint() {
        var warnings: [MicHealthWarningMonitor.Warning?] = []
        let monitor = MicHealthWarningMonitor(
            snapshot: {
                .init(elapsed: 2, deliveredSeconds: 2, maxRMS: 0.008,
                      engineRunning: true, deviceName: "Fixture microphone",
                      levelFrames: self.signal(speechRMS: pow(10, -43 / 20), speechFrames: 9, floorFrames: 11))
            },
            warning: { warnings.append($0) },
            schedule: { _, _ in }
        )
        monitor.evaluate()
        XCTAssertFalse(warnings.contains(.lowLevel), "Nine speech frames are insufficient")
    }

    func testQuietDeliveredAudioShowsLowMicrophoneHintAfterTwoSeconds() {
        let clock = MicHealthTestClock()
        var visibleWarning: MicHealthWarningMonitor.Warning?
        let monitor = MicHealthWarningMonitor(
            snapshot: {
                .init(elapsed: clock.now, deliveredSeconds: 2,
                      maxRMS: 0.008, engineRunning: true,
                      deviceName: "Fixture microphone",
                      levelFrames: self.signal(speechRMS: 0.008))
            },
            warning: { visibleWarning = $0 },
            schedule: clock.schedule
        )

        clock.advance(to: 2.1)

        XCTAssertEqual(
            visibleWarning,
            .lowLevel
        )
        withExtendedLifetime(monitor) {}
    }

    func testLowLevelWarningStaysLatchedUntilTheLevelBecomesHealthy() {
        let clock = MicHealthTestClock()
        var levelFrames = signal(speechRMS: 0.008)
        var warnings: [MicHealthWarningMonitor.Warning?] = []
        let monitor = MicHealthWarningMonitor(
            snapshot: {
                .init(elapsed: clock.now, deliveredSeconds: 2, maxRMS: 0.02,
                      engineRunning: true, deviceName: "Fixture microphone", levelFrames: levelFrames)
            },
            warning: { warnings.append($0) },
            schedule: clock.schedule
        )

        clock.advance(to: 3)
        XCTAssertEqual(warnings, [.lowLevel], "The low-level warning must not flash then clear")
        levelFrames = signal(speechRMS: 0.02)
        monitor.evaluate()
        XCTAssertNil(warnings.last!)
        withExtendedLifetime(monitor) {}
    }

    func testLowLevelWarningDecisionTruthTable() {
        let quiet: Float = 0.0099 // just below -40 dBFS
        let threshold: Float = 0.01 // exactly -40 dBFS
        let base = (maxRMS: Float(0.02), speechLevel: MicHealth.speechLevel(in: signal(speechRMS: quiet)), engineRunning: true)

        XCTAssertFalse(MicHealth.shouldShowLowLevelWarning(
            deliveredSeconds: 1.99, maxRMS: base.maxRMS, speechLevel: base.speechLevel,
            engineRunning: base.engineRunning, secondsSincePreviousWarning: nil,
            previousHoldShowedWarning: false, currentHoldAlreadyShowedWarning: false
        ), "Too little delivered audio must not hint")
        XCTAssertFalse(MicHealth.shouldShowLowLevelWarning(
            deliveredSeconds: 2, maxRMS: 0.006, speechLevel: base.speechLevel,
            engineRunning: true, secondsSincePreviousWarning: nil,
            previousHoldShowedWarning: false, currentHoldAlreadyShowedWarning: false
        ), "Existing silent-hold behavior owns below-threshold samples")
        XCTAssertFalse(MicHealth.shouldShowLowLevelWarning(
            deliveredSeconds: 2, maxRMS: base.maxRMS, speechLevel: MicHealth.speechLevel(in: signal(speechRMS: threshold)),
            engineRunning: true, secondsSincePreviousWarning: nil,
            previousHoldShowedWarning: false, currentHoldAlreadyShowedWarning: false
        ), "Exactly -40 dBFS is not below the low-level threshold")
        XCTAssertFalse(MicHealth.shouldShowLowLevelWarning(
            deliveredSeconds: 2, maxRMS: base.maxRMS, speechLevel: MicHealth.speechLevel(in: signal(speechRMS: 0.0101)),
            engineRunning: true, secondsSincePreviousWarning: nil,
            previousHoldShowedWarning: false, currentHoldAlreadyShowedWarning: false
        ), "Above -40 dBFS is healthy")
        XCTAssertFalse(MicHealth.shouldShowLowLevelWarning(
            deliveredSeconds: 2, maxRMS: base.maxRMS, speechLevel: MicHealth.speechLevel(in: []),
            engineRunning: true, secondsSincePreviousWarning: nil,
            previousHoldShowedWarning: false, currentHoldAlreadyShowedWarning: false
        ), "No completed RMS frames cannot establish a low level")
        XCTAssertFalse(MicHealth.shouldShowLowLevelWarning(
            deliveredSeconds: 2, maxRMS: base.maxRMS, speechLevel: base.speechLevel,
            engineRunning: false, secondsSincePreviousWarning: nil,
            previousHoldShowedWarning: false, currentHoldAlreadyShowedWarning: false
        ))
        XCTAssertTrue(MicHealth.shouldShowLowLevelWarning(
            deliveredSeconds: 2, maxRMS: base.maxRMS, speechLevel: base.speechLevel,
            engineRunning: true, secondsSincePreviousWarning: nil,
            previousHoldShowedWarning: false, currentHoldAlreadyShowedWarning: false
        ))
        XCTAssertFalse(MicHealth.shouldShowLowLevelWarning(
            deliveredSeconds: 2, maxRMS: base.maxRMS, speechLevel: base.speechLevel,
            engineRunning: true, secondsSincePreviousWarning: 599,
            previousHoldShowedWarning: false, currentHoldAlreadyShowedWarning: false
        ))
        XCTAssertTrue(MicHealth.shouldShowLowLevelWarning(
            deliveredSeconds: 2, maxRMS: base.maxRMS, speechLevel: base.speechLevel,
            engineRunning: true, secondsSincePreviousWarning: 600,
            previousHoldShowedWarning: false, currentHoldAlreadyShowedWarning: false
        ))
        XCTAssertFalse(MicHealth.shouldShowLowLevelWarning(
            deliveredSeconds: 700, maxRMS: base.maxRMS, speechLevel: base.speechLevel,
            engineRunning: true, secondsSincePreviousWarning: 700,
            previousHoldShowedWarning: true, currentHoldAlreadyShowedWarning: false
        ), "A low-level hint may not repeat on consecutive holds")
        XCTAssertFalse(MicHealth.shouldShowLowLevelWarning(
            deliveredSeconds: 700, maxRMS: base.maxRMS, speechLevel: base.speechLevel,
            engineRunning: true, secondsSincePreviousWarning: 700,
            previousHoldShowedWarning: false, currentHoldAlreadyShowedWarning: true
        ))
    }

    func testNinetiethPercentileUsesSyntheticRMSFrames() throws {
        let levels = (1...10).map { MicHealth.LevelFrame(rms: Float($0) / 1_000, duration: 0.1) }
        XCTAssertEqual(try XCTUnwrap(MicHealth.percentileRMS(levels, percentile: 0.9)), 0.009, accuracy: 0.000_001)
        XCTAssertEqual(MicHealth.decibelsFullScale(forRMS: 0.01), -40, accuracy: 0.000_001)
    }

    @MainActor
    func testTapAccumulatesDurationWeightedRMSFramesWithoutDroppingPartialBuffers() throws {
        let clock = MicHealthTestClock()
        let hooks = AudioRecorder.MicCaptureTestHooks(schedule: clock.schedule, now: { clock.date })
        let recorder = AudioRecorder(micCaptureTestHooks: hooks)
        isolateHintRecorder(recorder)
        recorder.beginMicCaptureForTesting()
        let receive = try XCTUnwrap(hooks.receiveBuffer)

        func deliver(_ frames: AVAudioFrameCount, amplitude: Float) throws {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: hooks.format, frameCapacity: frames))
            buffer.frameLength = frames
            for frame in 0..<Int(frames) { buffer.floatChannelData![0][frame] = amplitude }
            receive(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
        }

        try deliver(800, amplitude: 0.008)
        try deliver(800, amplitude: 0.008)
        var snapshot = recorder.micLevelFramesForTesting
        XCTAssertEqual(snapshot.frames.count, 2, "Each tap buffer is a duration-weighted level frame")
        XCTAssertEqual(snapshot.frames[0].rms, 0.008, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.deliveredSeconds, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.frames[0].duration, 0.05, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.frames[1].duration, 0.05, accuracy: 0.000_001)
        XCTAssertLessThan(
            MicHealth.decibelsFullScale(forRMS: try XCTUnwrap(MicHealth.percentileRMS(snapshot.frames, percentile: 0.9))),
            MicHealth.lowLevelWarningThresholdDBFS
        )

        try deliver(3_200, amplitude: 0.02)
        snapshot = recorder.micLevelFramesForTesting
        XCTAssertEqual(snapshot.frames.count, 3, "Every delivered tap buffer contributes one level frame")
        XCTAssertEqual(snapshot.deliveredSeconds, 0.3, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.frames[2].duration, 0.2, accuracy: 0.000_001)
        XCTAssertGreaterThan(
            MicHealth.decibelsFullScale(forRMS: try XCTUnwrap(MicHealth.percentileRMS(snapshot.frames, percentile: 0.9))),
            MicHealth.lowLevelWarningThresholdDBFS
        )
        recorder.stopRecording()
    }

    func testSpeechEvidenceUsesDurationWeightingAndSixDecibelBoundary() throws {
        let floorRMS: Float = 0.001
        let below = floorRMS * pow(10, 5.99 / 20)
        let above = floorRMS * pow(10, 6.01 / 20)
        XCTAssertNil(MicHealth.speechLevel(in: signal(speechRMS: below, floorRMS: floorRMS)))
        let level = try XCTUnwrap(MicHealth.speechLevel(in: signal(speechRMS: above, floorRMS: floorRMS)))
        XCTAssertEqual(level.duration, 1, accuracy: 0.000_001)

        let weighted = [MicHealth.LevelFrame(rms: floorRMS, duration: 2),
                        .init(rms: 0.008, duration: 0.9)]
        let shortSpeech = try XCTUnwrap(MicHealth.speechLevel(in: weighted))
        XCTAssertEqual(shortSpeech.duration, 0.9, accuracy: 0.000_001)
        XCTAssertFalse(MicHealth.shouldShowLowLevelWarning(
            deliveredSeconds: 2.9, maxRMS: 0.008, speechLevel: shortSpeech,
            engineRunning: true, secondsSincePreviousWarning: nil,
            previousHoldShowedWarning: false, currentHoldAlreadyShowedWarning: false
        ))
        XCTAssertEqual(try XCTUnwrap(MicHealth.percentileRMS(weighted, percentile: 0.1)), floorRMS)
        XCTAssertNil(MicHealth.speechLevel(in: frames(0, count: 50)))
    }

    @MainActor
    func testPauseThenQuietSpeechShowsHintButNormalSpeechDoesNot() throws {
        for (floorDB, speechDB, expectsHint) in [(-53.0, -43.0, true), (-47.0, -35.0, false)] {
            let clock = MicHealthTestClock()
            let hooks = AudioRecorder.MicCaptureTestHooks(schedule: clock.schedule, now: { clock.date })
            let hud = RecordingHUD(presentsWindows: false)
            let recorder = AudioRecorder(micCaptureTestHooks: hooks, hud: hud)
            isolateHintRecorder(recorder)
            hud.show()
            recorder.beginMicCaptureForTesting()
            try deliverFrames(frames(Float(pow(10, floorDB / 20)), count: 20).map(\.rms), hooks: hooks)
            clock.advance(to: 2.1)
            XCTAssertNotEqual(hud.currentState, .microphoneLowLevel, "Thinking before speech must not produce a low-level hint")
            try deliverFrames(frames(Float(pow(10, speechDB / 20)), count: 15).map(\.rms), hooks: hooks)
            clock.advance(to: 3.6)
            XCTAssertEqual(hud.currentState == .microphoneLowLevel, expectsHint)
            XCTAssertTrue(recorder.micCaptureStateForTesting.wanted)
            recorder.stopRecording()
            hud.hide()
        }
    }

    func testRecordingHandoffPreservesThePartialReadTail() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("open-caf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = RecordingRetention.recordingsDirectoryOverride
        RecordingRetention.recordingsDirectoryOverride = directory
        defer {
            RecordingRetention.recordingsDirectoryOverride = previous
            try? FileManager.default.removeItem(at: directory)
        }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000))
        buffer.frameLength = 32_000
        for frame in 0..<32_000 { buffer.floatChannelData![0][frame] = 0.008 }
        let source = directory.appendingPathComponent("source.caf")
        var writer: AVAudioFile? = try AVAudioFile(forWriting: source, settings: format.settings,
                                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        try XCTUnwrap(writer).write(from: buffer)
        XCTAssertEqual(writer?.length, 32_000)
        // Exercise the same open-writer handoff used by AudioRecorder.
        var retained: URL?
        RecordingRetention.handoffForTranscription(from: source) { url, retainedURL, _ in
            retained = retainedURL
            XCTAssertEqual(try? AVAudioFile(forReading: url).length, 32_000)
        }
        writer = nil
        let retainedFile = try AVAudioFile(forReading: XCTUnwrap(retained))
        XCTAssertEqual(retainedFile.length, 32_000)
        let samples = try Self.readAllSamples(from: retainedFile)
        XCTAssertEqual(samples.count, 32_000)
        XCTAssertEqual(try XCTUnwrap(samples.last), 0.008, accuracy: 0.000_001)
    }

    @MainActor
    func testLowLevelHoldContinuesThroughNormalStopAndTranscription() async throws {
        XCTAssertTrue(isTestHost, "Audio writes must stay in the isolated test host")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("low-level-hold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousDirectory = RecordingRetention.recordingsDirectoryOverride
        RecordingRetention.recordingsDirectoryOverride = directory
        defer {
            RecordingRetention.recordingsDirectoryOverride = previousDirectory
            try? FileManager.default.removeItem(at: directory)
        }

        let clock = MicHealthTestClock()
        let hooks = AudioRecorder.MicCaptureTestHooks(schedule: clock.schedule, now: { clock.date })
        let hud = RecordingHUD(presentsWindows: false)
        let recorder = AudioRecorder(micCaptureTestHooks: hooks, hud: hud)
        isolateHintRecorder(recorder)
        let pipeline = recorder.asrSelector.pipeline
        let transcribed = expectation(description: "quiet hold reaches local transcription")
        let logged = expectation(description: "quiet hold completes isolated delivery")
        pipeline.localEngineProvider = { LowLevelSpeechEngine(started: transcribed) }
        let held = CaretContext.Snapshot(
            value: "", location: 0, selectionLength: .readable(0),
            precedingChar: .startOfField, isUnknown: false,
            focusedElement: AXUIElementCreateApplication(42)
        )
        let board = NSPasteboard(name: .init("low-level-delivery-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let observer = RecoveryObserver()
        var delivered = ""
        pipeline.deliveryHooks = .init(
            injector: .init(
                pasteboard: board,
                target: { .init(secureInput: false, pid: 42, bundleIdentifier: "fixture") },
                createObserver: { observer },
                postUnicode: { _ in XCTFail("Use chunk delivery"); return 0 },
                postPasteChord: { XCTFail("No paste fallback expected"); return false },
                postCanary: { false },
                waitForConfirmation: { _, _ in observer.observedUTF16Units },
                postUnicodeChunk: { units in
                    delivered += String(decoding: units, as: UTF16.self)
                    observer.observedUTF16Units += units.count
                }
            ),
            snapshot: { held }
        )
        pipeline.onTranscriptionLogged = { text, engine, injected, _, failed, _ in
            XCTAssertEqual(text, "Quiet delivered speech.")
            XCTAssertEqual(engine, "low-level-speech-fixture")
            XCTAssertTrue(injected)
            XCTAssertFalse(failed)
            logged.fulfill()
        }
        let token = pipeline.test_holdSnapshot(held, frontmostPID: 42)
        recorder.test_prepareHold(token: token, active: true)
        recorder.test_seedCachedSessionHold(token: token, snapshot: held, pid: 42)
        hud.claimHold(token)
        hud.show()

        recorder.beginMicCaptureForTesting()
        try deliverFrames(signal(speechRMS: 0.008).map(\.rms), hooks: hooks)
        let captured = recorder.micCaptureStateForTesting.buffers
        XCTAssertEqual(captured.reduce(0) { $0 + Int($1.frameLength) }, 32_000)
        let combined = try XCTUnwrap(AudioRecorder.combine(buffers: captured))
        XCTAssertEqual(combined.frameLength, 32_000)
        XCTAssertEqual(combined.floatChannelData![0][31_999], 0.008, accuracy: 0.000_001)
        clock.advance(to: 2.1)
        XCTAssertEqual(hud.currentState, .microphoneLowLevel)
        XCTAssertTrue(recorder.micCaptureStateForTesting.wanted)

        recorder.stopRecording()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        recorder.test_flushStopGrace()
        await fulfillment(of: [transcribed, logged], timeout: 5)
        XCTAssertEqual(delivered, "Quiet delivered speech.")
        hud.hide()
    }

    @MainActor
    func testRecorderSkipsConsecutiveLowHintsThenAllowsOneAfterCooldown() throws {
        let clock = MicHealthTestClock()
        let hooks = AudioRecorder.MicCaptureTestHooks(schedule: clock.schedule, now: { clock.date })
        let hud = RecordingHUD(presentsWindows: false)
        let recorder = AudioRecorder(micCaptureTestHooks: hooks, hud: hud)
        isolateHintRecorder(recorder)
        func deliverQuietHold() throws {
            recorder.beginMicCaptureForTesting()
            try deliverFrames(signal(speechRMS: 0.008).map(\.rms), hooks: hooks)
        }

        hud.show()
        try deliverQuietHold()
        clock.advance(to: 2.1)
        XCTAssertEqual(hud.currentState, .microphoneLowLevel)

        hud.show()
        try deliverQuietHold()
        clock.advance(to: 4.2)
        XCTAssertEqual(hud.currentState, .listening, "Consecutive holds may not repeat the hint")

        hud.show()
        try deliverQuietHold()
        clock.advance(to: 603)
        XCTAssertEqual(hud.currentState, .microphoneLowLevel, "Cooldown expiry permits a non-consecutive hold")
        recorder.stopRecording()
        hud.hide()
    }

    @MainActor
    func testLowLevelHUDPresentsAccessibleTwoLineHint() {
        let hud = RecordingHUD(presentsWindows: false)
        hud.show()
        hud.showMicrophoneLowLevel()
        XCTAssertEqual(hud.currentState, .microphoneLowLevel)
        XCTAssertEqual(
            hud.currentState.accessibilityAnnouncement,
            "Mic level is very low. Move closer or raise input volume"
        )
        hud.clearMicrophoneWarning()
        XCTAssertEqual(hud.currentState, .listening)
        hud.hide()
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
