import Foundation

/// A stable microphone identity shown in Settings and persisted as a CoreAudio
/// UID rather than the process-local `AudioDeviceID`.
struct MicrophoneDevice: Identifiable, Equatable {
    let uid: String
    let name: String

    var id: String { uid }
}

/// Pure microphone-selection and no-audio warning decisions.
enum MicHealth {
    static let noAudioWarningDelay: TimeInterval = 1.5
    static let realRMSThreshold: Float = 0.007

    /// Exclusions win before a picker considers any device.
    static func availableDevices(
        _ devices: [MicrophoneDevice],
        excluding excludedUIDs: Set<String>
    ) -> [MicrophoneDevice] {
        devices.filter { !excludedUIDs.contains($0.uid) }
    }

    /// A missing or excluded saved choice falls back to Automatic for this
    /// hold. The saved UID remains intact so reconnecting the device restores
    /// the user's choice.
    static func activePreferredUID(
        _ preferredUID: String?,
        availableDevices: [MicrophoneDevice],
        excluding excludedUIDs: Set<String>
    ) -> String? {
        guard let preferredUID,
              !excludedUIDs.contains(preferredUID),
              availableDevices.contains(where: { $0.uid == preferredUID })
        else {
            return nil
        }
        return preferredUID
    }

    /// Once the cumulative RMS crosses the speech threshold, the no-audio
    /// warning stays cleared for the rest of this hold.
    static func shouldShowNoAudioWarning(
        elapsed: TimeInterval,
        maxRMS: Float,
        engineRunning: Bool
    ) -> Bool {
        engineRunning && elapsed >= noAudioWarningDelay && maxRMS < realRMSThreshold
    }
}
