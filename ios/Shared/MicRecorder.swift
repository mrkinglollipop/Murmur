import AVFoundation
import Foundation

/// Owns one foreground-activated input graph. During a valid lease the graph stays
/// active, but samples are written only while an explicit dictation segment is open.
final class MicRecorder: NSObject {
    private let stateLock = NSLock()
    private var engine: AVAudioEngine?
    private var inputFormat: AVAudioFormat?
    private var segmentFile: AVAudioFile?
    private var segmentURL: URL?
    private var segmentPaused = false
    private var segmentWriteFailed = false
    private var smoothedMeterLevel: Double = 0
    private var latestMeterLevel: Double = 0
    private var sessionActive = false

    var onSessionUnavailable: (() -> Void)?

    override init() {
        super.init()
        let session = AVAudioSession.sharedInstance()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionInterrupted(_:)),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(routeChanged(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: session
        )
    }

    var isRecording: Bool {
        stateLock.withLock { segmentFile != nil && !segmentPaused }
    }

    var canResume: Bool {
        stateLock.withLock { segmentFile != nil && segmentPaused }
    }

    /// Arms AVAudioSession + AVAudioEngine without opening a segment file.
    /// Buffers are discarded until `start()` opens a sink (listen-gate).
    func armInputGraph() throws {
        try ensureInputGraph()
    }

    var isInputGraphArmed: Bool {
        stateLock.withLock { engine?.isRunning == true && sessionActive }
    }

    /// Called in the foreground for the first take, then from the background only
    /// while the already-running input graph is covered by a fresh readiness lease.
    func start() throws {
        try ensureInputGraph()
        discardSegmentFile()
        guard let format = stateLock.withLock({ inputFormat }) else {
            throw RecorderError.startFailed
        }
        let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupStore.suiteName
        ) ?? FileManager.default.temporaryDirectory
        cleanupStaleSegments(in: root)
        let url = root.appendingPathComponent("murmur-\(UUID().uuidString).caf")
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        stateLock.withLock {
            segmentFile = file
            segmentURL = url
            segmentPaused = false
            segmentWriteFailed = false
            smoothedMeterLevel = 0
            latestMeterLevel = 0
        }
    }

    func pause() {
        stateLock.withLock { segmentPaused = true }
    }

    func resume() throws {
        let resumable = stateLock.withLock { () -> Bool in
            guard segmentFile != nil else { return false }
            segmentPaused = false
            return true
        }
        guard resumable else { throw RecorderError.startFailed }
    }

    /// Closes the current sink but deliberately leaves the input graph running.
    /// The tap discards subsequent buffers until the next segment starts.
    func stopKeepingInputActive() throws -> URL {
        let result = stateLock.withLock { () -> (URL?, Bool) in
            let url = segmentURL
            let failed = segmentWriteFailed
            segmentFile = nil
            segmentURL = nil
            segmentPaused = false
            segmentWriteFailed = false
            smoothedMeterLevel = 0
            latestMeterLevel = 0
            return (url, failed)
        }
        guard !result.1 else {
            if let url = result.0 { try? FileManager.default.removeItem(at: url) }
            throw RecorderError.writeFailed
        }
        guard let url = result.0 else { throw RecorderError.noAudio }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 1024 else {
            try? FileManager.default.removeItem(at: url)
            throw RecorderError.noAudio
        }
        return url
    }

    func cancel() {
        discardSegmentFile()
        deactivateSession()
    }

    func deactivateSession() {
        let stopped = stateLock.withLock { () -> (AVAudioEngine?, URL?) in
            let engine = self.engine
            let url = segmentURL
            self.engine = nil
            inputFormat = nil
            segmentFile = nil
            segmentURL = nil
            segmentPaused = false
            segmentWriteFailed = false
            smoothedMeterLevel = 0
            latestMeterLevel = 0
            sessionActive = false
            return (engine, url)
        }
        if let engine = stopped.0 {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        if let url = stopped.1 { try? FileManager.default.removeItem(at: url) }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func meterLevel() -> Double {
        stateLock.withLock { segmentFile == nil || segmentPaused ? 0 : latestMeterLevel }
    }

    private func ensureInputGraph() throws {
        let reusable = stateLock.withLock { engine?.isRunning == true && sessionActive }
        if reusable { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            if session.isOtherAudioPlaying || session.secondaryAudioShouldBeSilencedHint {
                throw RecorderError.micBusy
            }
            throw RecorderError.startFailed
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            if session.isOtherAudioPlaying {
                throw RecorderError.micBusy
            }
            throw RecorderError.startFailed
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            if session.isOtherAudioPlaying {
                throw RecorderError.micBusy
            }
            throw RecorderError.startFailed
        }
        stateLock.withLock {
            self.engine = engine
            inputFormat = format
            sessionActive = true
        }
    }

    /// The audio callback never allocates a queue or retains buffers. A narrow lock
    /// makes the active sink swap atomic; buffers are discarded when no sink exists.
    private func consume(_ buffer: AVAudioPCMBuffer) {
        stateLock.withLock {
            guard let file = segmentFile, !segmentPaused else { return }
            do {
                try file.write(from: buffer)
            } catch {
                segmentWriteFailed = true
            }
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            let count = Int(buffer.frameLength)
            var sumSquares: Float = 0
            var peak: Float = 0
            for index in 0..<count {
                let magnitude = abs(samples[index])
                sumSquares += magnitude * magnitude
                peak = max(peak, magnitude)
            }
            let rms = sqrt(Double(sumSquares) / Double(count))
            let averageDB = 20 * log10(max(rms, 0.000_01))
            let peakDB = 20 * log10(max(Double(peak), 0.000_01))
            let averageLevel = pow(min(1, max(0, (averageDB + 58) / 46)), 0.5)
            let peakLevel = pow(min(1, max(0, (peakDB + 58) / 46)), 0.6)
            let target = max(averageLevel, peakLevel * 0.9)
            let coefficient = target > smoothedMeterLevel ? 0.72 : 0.2
            smoothedMeterLevel += (target - smoothedMeterLevel) * coefficient
            latestMeterLevel = smoothedMeterLevel
        }
    }

    private func discardSegmentFile() {
        let url = stateLock.withLock { () -> URL? in
            let url = segmentURL
            segmentFile = nil
            segmentURL = nil
            segmentPaused = false
            segmentWriteFailed = false
            smoothedMeterLevel = 0
            latestMeterLevel = 0
            return url
        }
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private func cleanupStaleSegments(in directory: URL) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls.prefix(64)
        where url.lastPathComponent.hasPrefix("murmur-") && url.pathExtension == "caf" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @objc private func sessionInterrupted(_ notification: Notification) {
        guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: value) == .began else { return }
        invalidateSession()
    }

    @objc private func sessionReset() {
        invalidateSession()
    }

    @objc private func routeChanged(_ notification: Notification) {
        guard let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: value),
              reason == .oldDeviceUnavailable || reason == .noSuitableRouteForCategory else { return }
        invalidateSession()
    }

    private func invalidateSession() {
        deactivateSession()
        AppGroupStore.microphoneLevel = 0
        onSessionUnavailable?()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

enum RecorderError: Error, LocalizedError {
    case noAudio
    case startFailed
    case writeFailed
    case micBusy

    var errorDescription: String? {
        switch self {
        case .noAudio: return "No audio"
        case .startFailed:
            return "Couldn't start audio capture. Tap the mic to try again, or quit and reopen Murmur if it keeps happening."
        case .writeFailed: return "Couldn't save the recording"
        case .micBusy:
            return "Couldn't start audio capture. Another app may be using the mic (a phone call will do this). Tap the mic to try again when it's free."
        }
    }
}
