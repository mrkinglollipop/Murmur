import Foundation
import CoreAudio

/// A stable microphone identity shown in Settings and persisted as a CoreAudio
/// UID rather than the process-local `AudioDeviceID`.
struct MicrophoneDevice: Identifiable, Equatable {
    let uid: String
    let name: String

    var id: String { uid }
}

/// Pure microphone-selection and no-audio warning decisions.
enum MicHealth {
    enum ZeroBufferAction: Equatable {
        case ignore
        case restart
        case fail
    }

    static func zeroBufferAction(
        generationMatches: Bool,
        stillWanted: Bool,
        tapInstalled: Bool,
        buffersSeen: Int,
        alreadyRetried: Bool
    ) -> ZeroBufferAction {
        guard generationMatches, stillWanted, tapInstalled, buffersSeen == 0 else {
            return .ignore
        }
        return alreadyRetried ? .fail : .restart
    }

    enum InputRerouteAction: Equatable {
        case keepCapture
        case rebuild(excluding: AudioDeviceID?)
    }

    static func inputRerouteAction(
        lastBound: AudioDeviceID?,
        currentDefault: AudioDeviceID?,
        boundUID: String?,
        preferredUID: String?,
        boundIsHealthy: Bool,
        engineRunning: Bool
    ) -> InputRerouteAction {
        // A stopped engine cannot keep a live tap, even if HAL reports the
        // same healthy device. Rebuild the graph without blacklisting it.
        guard engineRunning else { return .rebuild(excluding: nil) }
        // An unrelated Sound Input change does not invalidate a live explicit choice.
        if boundIsHealthy, let preferredUID, boundUID == preferredUID {
            return .keepCapture
        }
        guard let lastBound, let currentDefault, lastBound != currentDefault else {
            return .keepCapture
        }
        return .rebuild(excluding: lastBound)
    }

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


/// Main-thread warning evaluation, independent of audio-buffer delivery.
/// A nil snapshot ends observation of this hold.
final class MicHealthWarningMonitor {
    struct Snapshot {
        let elapsed: TimeInterval
        let maxRMS: Float
        let engineRunning: Bool
        let deviceName: String
    }

    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
    private let snapshot: () -> Snapshot?
    private let warning: (String?) -> Void
    private let schedule: Schedule

    init(
        snapshot: @escaping () -> Snapshot?,
        warning: @escaping (String?) -> Void,
        schedule: @escaping Schedule = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    ) {
        self.snapshot = snapshot
        self.warning = warning
        self.schedule = schedule
        scheduleEvaluation()
    }

    private func scheduleEvaluation() {
        schedule(0.25) { [weak self] in
            guard let self, self.evaluate() else { return }
            self.scheduleEvaluation()
        }
    }

    @discardableResult
    func evaluate() -> Bool {
        guard let state = snapshot() else { return false }
        if MicHealth.shouldShowNoAudioWarning(
            elapsed: state.elapsed,
            maxRMS: state.maxRMS,
            engineRunning: state.engineRunning
        ) {
            warning(state.deviceName)
        } else if state.maxRMS >= MicHealth.realRMSThreshold {
            warning(nil)
        }
        return true
    }
}
