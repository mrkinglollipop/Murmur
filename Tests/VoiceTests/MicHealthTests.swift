import XCTest
import Foundation
@testable import Voice

final class MicHealthTests: XCTestCase {

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
