import Foundation
import CoreAudio

/// A stable microphone identity shown in Settings and persisted as a CoreAudio
/// UID rather than the process-local `AudioDeviceID`.
struct MicrophoneDevice: Identifiable, Equatable {
    let uid: String
    let name: String

    var id: String { uid }
}

/// Pure microphone-selection and microphone warning decisions.
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
    /// Full scale is 1.0. Speech evidence must precede a low-level judgment.
    static let lowLevelWarningDelay: TimeInterval = 2.0
    static let lowLevelWarningThresholdDBFS: Float = -40
    static let lowLevelWarningCooldown: TimeInterval = 600
    static let levelFrameDuration: TimeInterval = 0.1
    static let roomFloorPercentile: Double = 0.1
    static let speechLevelPercentile: Double = 0.9
    static let speechAboveFloorDB: Float = 6
    static let minimumSpeechDuration: TimeInterval = 1.0
    /// Ignore only floating-point summation error at duration boundaries.
    static let durationTolerance: TimeInterval = 1e-9

    /// Each tap buffer supplies one RMS frame, weighted by delivered duration.
    /// Nominal buffers are ~100 ms; short tails and larger taps retain their
    /// actual weight rather than counting as a whole nominal frame.
    struct LevelFrame {
        let rms: Float
        let duration: TimeInterval
    }

    struct SpeechLevel {
        let duration: TimeInterval
        let p90DBFS: Float
    }

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

    static func decibelsFullScale(forRMS rms: Float) -> Float {
        20 * log10(max(rms, Float.leastNonzeroMagnitude))
    }

    /// Duration-weighted nearest-rank percentile, evaluated off the audio thread.
    static func percentileRMS(_ frames: [LevelFrame], percentile: Double) -> Float? {
        let ordered = frames.filter {
            $0.duration > 0 && $0.duration.isFinite && $0.rms >= 0 && $0.rms.isFinite
        }.sorted { $0.rms < $1.rms }
        guard !ordered.isEmpty else { return nil }
        let target = ordered.reduce(0) { $0 + $1.duration } * percentile
        var cumulative: TimeInterval = 0
        for frame in ordered {
            cumulative += frame.duration
            if cumulative + durationTolerance >= target { return frame.rms }
        }
        return ordered.last?.rms
    }

    /// Room tone establishes the floor; only frames at least 6 dB above it
    /// contribute to speech duration and loud-part level. Uniform noise (or
    /// speech without any observed floor) cannot establish speech evidence.
    static func speechLevel(in frames: [LevelFrame]) -> SpeechLevel? {
        guard let floorRMS = percentileRMS(frames, percentile: roomFloorPercentile) else { return nil }
        let speechThreshold = decibelsFullScale(forRMS: floorRMS) + speechAboveFloorDB
        let speech = frames.filter {
            $0.duration > 0 && $0.duration.isFinite && $0.rms >= 0 && $0.rms.isFinite
                && decibelsFullScale(forRMS: $0.rms) >= speechThreshold
        }
        guard let p90 = percentileRMS(speech, percentile: speechLevelPercentile) else { return nil }
        return SpeechLevel(duration: speech.reduce(0) { $0 + $1.duration },
                           p90DBFS: decibelsFullScale(forRMS: p90))
    }

    static func shouldShowLowLevelWarning(
        deliveredSeconds: TimeInterval,
        maxRMS: Float,
        speechLevel: SpeechLevel?,
        engineRunning: Bool,
        secondsSincePreviousWarning: TimeInterval?,
        previousHoldShowedWarning: Bool,
        currentHoldAlreadyShowedWarning: Bool
    ) -> Bool {
        guard engineRunning,
              deliveredSeconds + durationTolerance >= lowLevelWarningDelay,
              maxRMS >= realRMSThreshold,
              let speechLevel,
              speechLevel.duration + durationTolerance >= minimumSpeechDuration,
              speechLevel.p90DBFS < lowLevelWarningThresholdDBFS,
              !previousHoldShowedWarning,
              !currentHoldAlreadyShowedWarning
        else {
            return false
        }
        return secondsSincePreviousWarning.map { $0 >= lowLevelWarningCooldown } ?? true
    }
}


/// Main-thread warning evaluation, independent of audio-buffer delivery.
/// A nil snapshot ends observation of this hold.
final class MicHealthWarningMonitor {
    enum Warning: Equatable {
        case noAudio(deviceName: String)
        case lowLevel
    }

    struct Snapshot {
        let elapsed: TimeInterval
        let deliveredSeconds: TimeInterval
        let maxRMS: Float
        let engineRunning: Bool
        let deviceName: String
        let levelFrames: [MicHealth.LevelFrame]
        let secondsSincePreviousLowLevelWarning: TimeInterval?
        let previousHoldShowedLowLevelWarning: Bool

        init(
            elapsed: TimeInterval,
            deliveredSeconds: TimeInterval = 0,
            maxRMS: Float,
            engineRunning: Bool,
            deviceName: String,
            levelFrames: [MicHealth.LevelFrame] = [],
            secondsSincePreviousLowLevelWarning: TimeInterval? = nil,
            previousHoldShowedLowLevelWarning: Bool = false
        ) {
            self.elapsed = elapsed
            self.deliveredSeconds = deliveredSeconds
            self.maxRMS = maxRMS
            self.engineRunning = engineRunning
            self.deviceName = deviceName
            self.levelFrames = levelFrames
            self.secondsSincePreviousLowLevelWarning = secondsSincePreviousLowLevelWarning
            self.previousHoldShowedLowLevelWarning = previousHoldShowedLowLevelWarning
        }
    }

    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
    private let snapshot: () -> Snapshot?
    private let warning: (Warning?) -> Void
    private let schedule: Schedule
    private var didShowLowLevelWarning = false

    init(
        snapshot: @escaping () -> Snapshot?,
        warning: @escaping (Warning?) -> Void,
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
        let speechLevel = MicHealth.speechLevel(in: state.levelFrames)
        if MicHealth.shouldShowNoAudioWarning(
            elapsed: state.elapsed,
            maxRMS: state.maxRMS,
            engineRunning: state.engineRunning
        ) {
            warning(.noAudio(deviceName: state.deviceName))
        } else if MicHealth.shouldShowLowLevelWarning(
            deliveredSeconds: state.deliveredSeconds,
            maxRMS: state.maxRMS,
            speechLevel: speechLevel,
            engineRunning: state.engineRunning,
            secondsSincePreviousWarning: state.secondsSincePreviousLowLevelWarning,
            previousHoldShowedWarning: state.previousHoldShowedLowLevelWarning,
            currentHoldAlreadyShowedWarning: didShowLowLevelWarning
        ) {
            didShowLowLevelWarning = true
            warning(.lowLevel)
        } else if state.maxRMS >= MicHealth.realRMSThreshold,
                  (!didShowLowLevelWarning || speechLevel.map {
                      $0.p90DBFS >= MicHealth.lowLevelWarningThresholdDBFS
                  } == true) {
            warning(nil)
        }
        return true
    }
}
