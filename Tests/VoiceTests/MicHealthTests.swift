import XCTest
import Foundation
@testable import Voice

final class MicHealthTests: XCTestCase {

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
