import AppKit
import AudioToolbox
import AVFoundation
import Carbon
import CoreAudio
import os.log

/// Captures microphone audio via AVAudioEngine while the push-to-talk key
/// is held.  On release, writes the buffer to a temp .caf file, then passes
/// it to the selected ASR engine for transcription.

final class AudioRecorder {

    /// Engine selector — change `selectedModel` to switch models/backends.
    let asrSelector = ASREngineSelector()

    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "audio")

    private var engine = AVAudioEngine()
    private var pcmBuffers: [AVAudioPCMBuffer] = []
    private let pcmBuffersLock = NSLock()
    /// Guarded by `pcmBuffersLock`. `pcmBuffers` is only cleared when a hold's
    /// mic capture begins, so buffers seen at stop while this is false belong
    /// to an earlier hold and must never be transcribed again.
    private var micCaptureBeganThisHold = false
    private var startTime: Date?
    private var isSetUp = false

    /// Set when the engine's device graph may be stale — a configuration-change
    /// notification, a dead input format, or a zero-buffer watchdog trip. The
    /// next capture start replaces the engine instance instead of reusing it.
    /// Main-thread confined, like the rest of the control state here.
    ///
    /// The wedge this heals (observed 2026-08-09 via VOICE_DEBUG): another
    /// app's voice session reroutes the input device; the long-lived engine
    /// then "starts" without error but its tap delivers zero buffers for the
    /// entire hold (log: `max RMS 0.0000 … buffers=0`), so the hold dies on
    /// the silence guard. A fresh AVAudioEngine rebinds the device correctly.
    private var engineNeedsRebuild = false

    /// Last HAL device ID successfully bound onto the input AU. Used to
    /// exclude a ghost on the one allowed rebuild so we do not re-pick it.
    private var lastBoundInputDeviceID: AudioDeviceID?

    /// User-facing name for the last successful binding. Kept alongside the
    /// ephemeral ID so the no-audio hint can name the device without persisting
    /// that ID across launches.
    private var lastBoundInputDeviceName = "Microphone"

    /// Avoid repeating the unavailable-preference diagnostic on every
    /// recovery bind in the same hold.
    private var loggedUnavailablePreferredUID: String?

    /// Device to exclude on the *next* `startMicCapture` bind/rebuild.
    /// Timeout, in-flight abandon, and fail-closed paths record a known ghost
    /// here because `doStart` calls `startMicCapture()` with `excluding: nil`.
    /// Cleared after a successful start, or when bind lands on a different ID.
    private var excludeOnNextStartDeviceID: AudioDeviceID?

    /// Instance-scoped observation of `AVAudioEngineConfigurationChange` —
    /// must be re-registered whenever `engine` is replaced.
    private var engineConfigObserver: NSObjectProtocol?

    /// HAL default-input listener. `AVAudioEngineConfigurationChange` is
    /// engine-scoped and can miss a Bluetooth unplug while idle/App Nap
    /// (observed 2026-08-16: ghost device 261, `'nope'` /
    /// `kAudioHardwareBadDeviceError`, fn tap frozen on main inside
    /// `engine.start()`). This listener is on the system object so the next
    /// hold rebuilds even when the engine stayed quiet.
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?

    /// Bumped at each capture start so the zero-buffer watchdog can verify the
    /// take it armed for is still the live one before acting.
    private var captureGeneration: UInt64 = 0

    /// One watchdog restart per hold: a genuinely dead input device must not
    /// loop rebuilds — after one retry the hold is left to fail visibly on
    /// the silence guard.
    private var watchdogRetriedThisTake = false

    /// Tink + HUD once the tap is actually live. `doStart` used to fire both
    /// before `engine.start`, so the pill's idle bars looked like "listening"
    /// while the first ~200ms of speech hit a dying or not-yet-started tap.
    private var didAnnounceListeningThisTake = false

    init() {
        registerEngineConfigObserver()
        registerDefaultInputDeviceListener()
    }

    deinit {
        if let engineConfigObserver {
            NotificationCenter.default.removeObserver(engineConfigObserver)
        }
        unregisterDefaultInputDeviceListener()
    }

    private func registerEngineConfigObserver() {
        if let engineConfigObserver {
            NotificationCenter.default.removeObserver(engineConfigObserver)
        }
        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleEngineConfigurationChange()
        }
    }

    /// `engine.start()` itself posts `AVAudioEngineConfigurationChange`.
    /// Flagging rebuild during an in-flight start makes every successful
    /// start look stale — one retry, then fail-closed "input changed during
    /// start after retry" (2026-08-17 10:18:20).
    static func shouldFlagRebuildOnConfigChange(startInFlight: Bool) -> Bool {
        !startInFlight
    }

    /// Mid-hold, a configuration change means the tap is now feeding from a
    /// dead or rerouted device — waiting for the next hold loses everything
    /// the user says from here on (observed 2026-08-09: the change fired 2 s
    /// into a 33 s hold; the remaining 31 s of speech never reached the mic).
    /// Restart capture immediately, keeping the buffers already captured.
    /// Idle, just flag the rebuild for the next capture start.
    private func handleEngineConfigurationChange() {
        guard Self.shouldRestartCaptureOnConfigChange(
            stillWanted: wantsRecording,
            tapInstalled: isSetUp,
            alreadyRetried: watchdogRetriedThisTake,
            startInFlight: engineStartInFlight
        ) else {
            if Self.shouldFlagRebuildOnConfigChange(startInFlight: engineStartInFlight) {
                vlog("audio engine configuration change — flagging engine rebuild")
                engineNeedsRebuild = true
            } else {
                vlog("audio engine configuration change during engine.start — ignored")
            }
            return
        }
        let currentDefault = Self.halDefaultInputDeviceID()
        let preferredUID = preferredInputDeviceUIDProvider?()
        let boundUID = lastBoundInputDeviceID.map {
            Self.audioDeviceCFString($0, kAudioDevicePropertyDeviceUID)
        }
        let boundIsHealthy = lastBoundInputDeviceID.map {
            Self.isAudioDeviceAlive($0) && !Self.audioDeviceInputFormatLooksDead($0)
                && !(excludedInputDeviceUIDsProvider?() ?? []).contains(boundUID ?? "")
        } ?? false
        let action = MicHealth.inputRerouteAction(
            lastBound: lastBoundInputDeviceID,
            currentDefault: currentDefault,
            boundUID: boundUID,
            preferredUID: preferredUID,
            boundIsHealthy: boundIsHealthy,
            engineRunning: engine.isRunning
        )
        guard case .rebuild(let failedID) = action else {
            vlog("audio engine configuration change MID-HOLD — keeping live tap")
            return
        }
        watchdogRetriedThisTake = true
        vlog("audio engine configuration change MID-HOLD — rebuilding engine, restarting capture")
        teardownMicEngine()
        rebuildEngine(excluding: failedID)
        startMicCapture(isWatchdogRetry: true, excluding: failedID)
    }

    private static var defaultInputPropertyAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func registerDefaultInputDeviceListener() {
        guard defaultInputListenerBlock == nil else { return }
        var address = Self.defaultInputPropertyAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleEngineConfigurationChange()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        if status == noErr {
            defaultInputListenerBlock = block
            return
        }
        logger.error(
            "Failed to listen for default input device changes: \(status) — retrying once"
        )
        let retry = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        if retry == noErr {
            defaultInputListenerBlock = block
        } else {
            logger.error(
                "Failed to listen for default input device changes after retry: \(retry)"
            )
        }
    }

    private func unregisterDefaultInputDeviceListener() {
        guard let block = defaultInputListenerBlock else { return }
        var address = Self.defaultInputPropertyAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        defaultInputListenerBlock = nil
    }

    /// Point the input AU at a device HAL still considers alive with a live
    /// input format. A new `AVAudioEngine()` rebinds to the *current default*,
    /// which can still be a ghost Bluetooth ID after unplug — that is not enough.
    private func bindAliveInputDevice(excluding failedDeviceID: AudioDeviceID? = nil) -> AudioDeviceID? {
        let defaultID = Self.halDefaultInputDeviceID()
        let defaultAlive = defaultID.map(Self.isAudioDeviceAlive) ?? false
        let defaultFormatDead = defaultID.map(Self.audioDeviceInputFormatLooksDead) ?? true
        let configuredExcludedUIDs = excludedInputDeviceUIDsProvider?() ?? []
        let allCandidates = Self.halInputDeviceCandidates()
        // Filter before calculating last-resort IDs or running any picker
        // branch. A device in Never use may not become a fallback later.
        let allowedUIDs = Set(MicHealth.availableDevices(
            allCandidates.map { MicrophoneDevice(uid: $0.uid, name: $0.name) },
            excluding: configuredExcludedUIDs
        ).map(\.uid))
        let candidates = allCandidates.filter { allowedUIDs.contains($0.uid) }
        let lastResortIDs = Set(candidates.filter(\.isLastResort).map(\.id))
        var excluded = Set<AudioDeviceID>()
        if let failedDeviceID {
            excluded.insert(failedDeviceID)
        }
        if let defaultID,
           configuredExcludedUIDs.contains(Self.audioDeviceCFString(defaultID, kAudioDevicePropertyDeviceUID)) {
            // The built-in/default ghost fallback below can exist outside the
            // enumerated candidates. Its UID must still respect Never use.
            excluded.insert(defaultID)
        }
        let preferredUID = preferredInputDeviceUIDProvider?()
        let activePreferredUID = MicHealth.activePreferredUID(
            preferredUID,
            availableDevices: candidates.map { MicrophoneDevice(uid: $0.uid, name: $0.name) },
            excluding: configuredExcludedUIDs
        )
        let preferredCandidate = activePreferredUID.flatMap { uid in
            candidates.first { $0.uid == uid }
        }
        if let preferredUID, loggedUnavailablePreferredUID != preferredUID {
            let isAvailable = preferredCandidate.map { $0.isAlive && !$0.formatLooksDead } ?? false
            if !isAvailable {
                logger.warning("Configured microphone unavailable for this hold; using Automatic")
                vlog("configured microphone UID unavailable or excluded — using Automatic")
                loggedUnavailablePreferredUID = preferredUID
            }
        }
        while true {
            let preferredID = preferredCandidate.flatMap { candidate -> AudioDeviceID? in
                candidate.isAlive && !candidate.formatLooksDead && !excluded.contains(candidate.id)
                    ? candidate.id
                    : nil
            }
            // An explicit choice may be Continuity or virtual even when the
            // automatic last-resort fallback remains off. Exclusions always win.
            let picked = preferredID ?? Self.pickAliveInputDevice(
                defaultID: defaultID,
                defaultIsAlive: defaultAlive,
                defaultFormatLooksDead: defaultFormatDead,
                defaultIsBuiltIn: defaultID.map(Self.audioDeviceIsBuiltIn) ?? false,
                candidates: candidates.map {
                    (id: $0.id, isAlive: $0.isAlive, isBuiltIn: $0.isBuiltIn, formatLooksDead: $0.formatLooksDead)
                },
                excluding: excluded,
                lastResortIDs: lastResortIDs,
                allowLastResortFallback: allowLastResortInputFallbackProvider?() ?? false
            )
            guard let picked else {
                lastBoundInputDeviceID = nil
                logger.error("No alive input device to bind")
                vlog("bindAliveInputDevice: none alive")
                return nil
            }
            if defaultID != picked {
                logger.warning(
                    "Rebinding input away from dead/default \(defaultID ?? 0) → \(picked)"
                )
                vlog("bindAliveInputDevice: \(defaultID ?? 0) (alive=\(defaultAlive) formatDead=\(defaultFormatDead)) → \(picked)")
            }
            let bound = bindInputNode(to: picked)
            if bound {
                lastBoundInputDeviceID = picked
                let name = candidates.first(where: { $0.id == picked })?.name
                    ?? Self.audioDeviceCFString(picked, kAudioObjectPropertyName)
                lastBoundInputDeviceName = name.isEmpty ? "Microphone" : name
                return picked
            }
            logger.error("bindInputNode failed for \(picked) — excluding and replacing engine")
            vlog("bindAliveInputDevice: bind failed for \(picked), excluding")
            excluded.insert(picked)
            if Self.shouldReplaceEngineAfterFailedBind(bound) {
                // NSException from prepare() can leave this graph unusable.
                // Retry the next HAL candidate on a fresh AVAudioEngine —
                // do not recurse into rebuildEngine / bindAliveInputDevice
                // (rebuildEngine calls bindAliveInputDevice).
                engine.stop()
                engine = AVAudioEngine()
                registerEngineConfigObserver()
            }
        }
    }

    /// After `bindInputNode` fails, the next candidate must not reuse this
    /// engine: `prepare()` NSException can leave the graph unusable.
    static func shouldReplaceEngineAfterFailedBind(_ bindSucceeded: Bool) -> Bool {
        !bindSucceeded
    }

    /// Bind the input AU to `deviceID`. Must not abort: `-[AVAudioEngine prepare]`
    /// can raise NSException (`AVAudioEngineGraph::Initialize`) on a ghost/0ch
    /// HAL default — 0.1.36 SIGABRT on every hold (IPS 2026-08-17 10:07).
    private func bindInputNode(to deviceID: AudioDeviceID) -> Bool {
        var bound = false
        var auWasNil = false
        var setStatus: OSStatus = noErr
        switch ObjCExceptionCatcher.run({
            // Set CurrentDevice *before* prepare(). 0.1.36 prepared first and
            // Initialize aborted on the ghost HAL default. Skipping prepare
            // left inputNode at 0ch, so we excluded the built-in and started
            // Continuity iPhone instead (2026-08-17 10:17–10:18).
            guard let audioUnit = self.engine.inputNode.audioUnit else {
                auWasNil = true
                return
            }
            var id = deviceID
            setStatus = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard setStatus == noErr else { return }
            self.engine.prepare()
            bound = true
        }) {
        case .failure(let error):
            logger.error(
                "bindInputNode: NSException device \(deviceID): \(error.localizedDescription)"
            )
            return false
        case .success:
            if auWasNil {
                logger.error("bindInputNode: input AU is nil (device \(deviceID))")
                return false
            }
            if !bound {
                logger.error(
                    "AudioUnitSetProperty CurrentDevice failed: OSStatus \(setStatus) (device \(deviceID))"
                )
                return false
            }
            return true
        }
    }

    private static func isAudioDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID != kAudioObjectUnknown, deviceID != 0 else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive)
        return status == noErr && alive != 0
    }

    private static func halDefaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultInputPropertyAddress
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown, deviceID != 0 else {
            return nil
        }
        return deviceID
    }

    private static func audioDeviceInputFormatLooksDead(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID != kAudioObjectUnknown, deviceID != 0 else { return true }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return true }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &asbd)
        guard status == noErr else { return true }
        return inputFormatLooksDead(
            sampleRate: asbd.mSampleRate,
            channelCount: asbd.mChannelsPerFrame
        )
    }

    private static func halInputDeviceCandidates() -> [(
        id: AudioDeviceID,
        isAlive: Bool,
        isBuiltIn: Bool,
        formatLooksDead: Bool,
        isLastResort: Bool,
        uid: String,
        name: String
    )] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &devices) == noErr else {
            return []
        }
        return devices.compactMap { id -> (
            id: AudioDeviceID,
            isAlive: Bool,
            isBuiltIn: Bool,
            formatLooksDead: Bool,
            isLastResort: Bool,
            uid: String,
            name: String
        )? in
            guard Self.audioDeviceHasInputStreams(id) else { return nil }
            return (
                id,
                Self.isAudioDeviceAlive(id),
                Self.audioDeviceIsBuiltIn(id),
                Self.audioDeviceInputFormatLooksDead(id),
                Self.audioDeviceIsLastResortInput(id),
                Self.audioDeviceCFString(id, kAudioDevicePropertyDeviceUID),
                Self.audioDeviceCFString(id, kAudioObjectPropertyName)
            )
        }
    }

    /// Live input choices for Settings. CoreAudio IDs change across launches;
    /// Settings persists only the stable UID returned here.
    static func availableInputDevices() -> [MicrophoneDevice] {
        var seenUIDs = Set<String>()
        return halInputDeviceCandidates().compactMap { candidate in
            guard !candidate.uid.isEmpty, seenUIDs.insert(candidate.uid).inserted else { return nil }
            return MicrophoneDevice(
                uid: candidate.uid,
                name: candidate.name.isEmpty ? "Microphone" : candidate.name
            )
        }
    }

    private static func audioDeviceHasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }

    private static func audioDeviceIsBuiltIn(_ deviceID: AudioDeviceID) -> Bool {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else {
            return false
        }
        return transport == kAudioDeviceTransportTypeBuiltIn
    }

    /// Continuity Capture (iPhone mic) and virtual devices (Jump Desktop)
    /// report alive with a live format, then wedge or time out `engine.start()`.
    /// Honor them when they are the user's Sound Input default; do not pick
    /// them as fallback when a hardware mic exists.
    static func isLastResortInputTransport(_ transport: UInt32) -> Bool {
        transport == kAudioDeviceTransportTypeVirtual
            || transport == kAudioDeviceTransportTypeContinuityCaptureWired
            || transport == kAudioDeviceTransportTypeContinuityCaptureWireless
    }

    private static func audioDeviceIsLastResortInput(_ deviceID: AudioDeviceID) -> Bool {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr,
           isLastResortInputTransport(transport)
        {
            return true
        }
        // Continuity iPhone mic can report transport Unknown (system_profiler
        // 2026-08-19) — the FourCC last-resort list misses it, so 145 won as
        // a "live non-last-resort" device.
        return isLastResortInputUID(audioDeviceCFString(deviceID, kAudioDevicePropertyDeviceUID))
            || isLastResortInputUID(audioDeviceCFString(deviceID, kAudioObjectPropertyName))
    }

    private static func audioDeviceCFString(
        _ deviceID: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0
        else { return "" }
        var cfValue: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfValue) == noErr else {
            return ""
        }
        // HAL GetProperty copies a +1 CFString; takeRetainedValue consumes it.
        guard let unmanaged = cfValue else { return "" }
        return unmanaged.takeRetainedValue() as String
    }

    /// UID / name fragments for Continuity and Jump when transport is Unknown.
    /// `iphone` is a whole letter-token so USB UIDs like XiphoneUSB do not match.
    static func isLastResortInputUID(_ uid: String) -> Bool {
        let folded = uid.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if folded.contains("continuity") || folded.contains("jump desktop") {
            return true
        }
        return folded.split { !$0.isLetter }.contains { $0 == "iphone" }
    }

    /// Pure decision (unit-tested): restart mid-hold only while the hold is
    /// live with a tap installed, engine start has settled (a pending start
    /// must not be torn down and re-issued), and only once per hold (shared
    /// budget with the zero-buffer watchdog so the two recovery paths cannot
    /// ping-pong). `isSetUp` stays true after tap install so teardown can
    /// still remove the tap; in-flight start is a separate guard.
    static func shouldRestartCaptureOnConfigChange(
        stillWanted: Bool,
        tapInstalled: Bool,
        alreadyRetried: Bool,
        startInFlight: Bool
    ) -> Bool {
        stillWanted && tapInstalled && !alreadyRetried && !startInFlight
    }

    /// Replaces the engine (input-node device binding included) and
    /// re-registers the instance-scoped observer. Call only between captures
    /// or after `teardownMicEngine()` — never with a live tap installed.
    /// Returns the bound device ID, or nil when bind failed (fail closed).
    @discardableResult
    private func rebuildEngine(excluding failedDeviceID: AudioDeviceID? = nil) -> AudioDeviceID? {
        engine.stop()
        engine = AVAudioEngine()
        registerEngineConfigObserver()
        engineNeedsRebuild = false
        return bindAliveInputDevice(excluding: failedDeviceID)
    }

    /// A CoreAudio device in transition can report a zero format; installing a
    /// tap against it "succeeds" and never fires.
    static func inputFormatLooksDead(sampleRate: Double, channelCount: UInt32) -> Bool {
        sampleRate == 0 || channelCount == 0
    }

    /// FourCC `'nope'` / missing AudioObject — `engine.start()` against this
    /// on the main run loop (where the fn tap also lives) is the 2026-08-16
    /// force-quit hang.
    static func isGhostInputStartStatus(_ status: OSStatus) -> Bool {
        status == kAudioHardwareBadDeviceError
            || status == kAudioHardwareBadObjectError
    }

    /// Walk `NSUnderlyingErrorKey` a bounded depth — AVFoundation often wraps
    /// the HAL `'nope'` more than one level down.
    private static let ghostUnderlyingErrorWalkDepth = 8

    static func isGhostInputStartError(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let ns = current, depth < ghostUnderlyingErrorWalkDepth {
            if ns.domain == ObjCExceptionCatcher.errorDomain { return true }
            if isGhostInputStartStatus(OSStatus(ns.code)) { return true }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    /// Prefer a live HAL default whose input format is usable; if that ID is
    /// dead, format-dead, or excluded, take a built-in mic (healthy, then
    /// format-dead-but-alive, then the built-in default even if `!isAlive`,
    /// then any built-in before Continuity). Other live non-last-resort
    /// devices come after that so a Bluetooth aggregate cannot beat the
    /// MacBook mic. Last-resort Continuity/virtual is opt-in
    /// (`allowLastResortFallback`); nil = no usable device.
    static func pickAliveInputDevice(
        defaultID: AudioDeviceID?,
        defaultIsAlive: Bool,
        defaultFormatLooksDead: Bool = false,
        defaultIsBuiltIn: Bool = false,
        candidates: [(id: AudioDeviceID, isAlive: Bool, isBuiltIn: Bool, formatLooksDead: Bool)],
        excluding: Set<AudioDeviceID> = [],
        lastResortIDs: Set<AudioDeviceID> = [],
        allowLastResortFallback: Bool = false
    ) -> AudioDeviceID? {
        func isPickable(id: AudioDeviceID, isAlive: Bool, formatLooksDead: Bool) -> Bool {
            isAlive && !formatLooksDead && !excluding.contains(id)
        }
        if let defaultID, isPickable(
            id: defaultID,
            isAlive: defaultIsAlive,
            formatLooksDead: defaultFormatLooksDead
        ) {
            return defaultID
        }
        if let builtIn = candidates.first(where: {
            $0.isBuiltIn && isPickable(
                id: $0.id,
                isAlive: $0.isAlive,
                formatLooksDead: $0.formatLooksDead
            )
        }) {
            return builtIn.id
        }
        // HAL can report the built-in as 0ch/"dead" while System Settings
        // still lists it as the default. Bind will throw if it is truly dead;
        // skipping it here falls through to Continuity and ruins the take.
        if let builtIn = candidates.first(where: {
            $0.isBuiltIn && $0.isAlive && !excluding.contains($0.id)
        }) {
            return builtIn.id
        }
        // Sound Input is the built-in, but HAL marked it dead/0ch — or
        // omitted it from candidates (0 input streams). Try that ID before
        // any other live device. `defaultIsBuiltIn` is the HAL transport on
        // the default ID itself; candidate membership is a fallback so
        // existing tests that only mark `isBuiltIn` on the tuple still pass.
        // Bind still throws if it is truly dead.
        if let defaultID,
           !excluding.contains(defaultID),
           defaultIsBuiltIn
            || candidates.contains(where: { $0.id == defaultID && $0.isBuiltIn })
        {
            return defaultID
        }
        if let preferred = candidates.first(where: {
            !lastResortIDs.contains($0.id) && isPickable(
                id: $0.id,
                isAlive: $0.isAlive,
                formatLooksDead: $0.formatLooksDead
            )
        }) {
            return preferred.id
        }
        // DeviceIsAlive false-negative on a built-in that is not the default
        // must still beat Continuity. Do not pick a dead USB mic here.
        if let builtIn = candidates.first(where: {
            $0.isBuiltIn && !excluding.contains($0.id)
        }) {
            return builtIn.id
        }
        return candidates.first(where: {
            isPickable(id: $0.id, isAlive: $0.isAlive, formatLooksDead: $0.formatLooksDead)
                && (allowLastResortFallback || !lastResortIDs.contains($0.id))
        })?.id
    }

    /// Next bind/rebuild exclude: an explicit watchdog/config/ghost-throw ID
    /// wins; otherwise the persisted last-failed ID from a prior timeout
    /// (or abandoned in-flight start) so hold 2 does not re-pick the ghost.
    static func excludeOnNextMicStart(
        explicit: AudioDeviceID?,
        persistedFailedID: AudioDeviceID?
    ) -> AudioDeviceID? {
        explicit ?? persistedFailedID
    }

    /// Mid-hold HAL/config reroute: exile lastBound only when it is no
    /// longer Sound Input. Continuity Capture appearing leaves default 81
    /// in place; treating 81 as failed is what rebound 81 → 145 after a
    /// successful `engine.start` on 0.1.39.
    /// `currentDefault == nil` is a transient HAL miss (Continuity
    /// ~80ms config-change window), not "81 is gone" — do not exile.
    static func excludeAfterInputReroute(
        lastBound: AudioDeviceID?,
        currentDefault: AudioDeviceID?
    ) -> AudioDeviceID? {
        guard let lastBound, let currentDefault else { return nil }
        if lastBound == currentDefault { return nil }
        return lastBound
    }

    /// Tear down + restart capture only when lastBound is a *different*
    /// concrete device than Sound Input. Same-default (Continuity appearing)
    /// and nil HAL default must not clip a live take.
    static func shouldRebuildCaptureAfterInputReroute(
        lastBound: AudioDeviceID?,
        currentDefault: AudioDeviceID?
    ) -> Bool {
        excludeAfterInputReroute(lastBound: lastBound, currentDefault: currentDefault) != nil
    }

    /// Drop the persisted exclude once bind landed on a different device.
    static func persistedExcludeAfterBind(
        boundID: AudioDeviceID,
        persistedExclude: AudioDeviceID?
    ) -> AudioDeviceID? {
        guard let persistedExclude else { return nil }
        return boundID == persistedExclude ? persistedExclude : nil
    }

    /// Fail-closed persist: keep a known ghost ID for the next hold's bind.
    /// A nil candidate must not wipe an existing persist (timeout / abandon
    /// may already have recorded one). Format-dead rebuild can nil
    /// `lastBoundInputDeviceID` before fail — callers pass the captured ID.
    static func persistedExcludeOnFailClosed(
        candidate: AudioDeviceID?,
        existing: AudioDeviceID?
    ) -> AudioDeviceID? {
        candidate ?? existing
    }

    /// Config-change during pending start only flags `engineNeedsRebuild`.
    /// Success must rebuild once rather than promote caret on the old binding.
    static func shouldRestartCaptureAfterStartSuccess(
        engineNeedsRebuild: Bool,
        alreadyRetried: Bool
    ) -> Bool {
        engineNeedsRebuild && !alreadyRetried
    }

    /// Shared one-retry budget already used — fail closed instead of promoting
    /// on a binding we know is stale (avoids a config-change restart loop).
    static func shouldFailClosedAfterStartSuccessWithPendingRebuild(
        engineNeedsRebuild: Bool,
        alreadyRetried: Bool
    ) -> Bool {
        engineNeedsRebuild && alreadyRetried
    }

    /// Bind returned nil — do not probe format / install a tap / start.
    static func shouldFailClosedWithoutBoundInput(_ boundDeviceID: AudioDeviceID?) -> Bool {
        boundDeviceID == nil
    }

    /// After excluding the ghost and rebuilding once, a still-dead format
    /// must fail closed rather than tap-install or loop.
    static func shouldFailClosedAfterDeadFormatFallback(formatStillDead: Bool) -> Bool {
        formatStillDead
    }

    /// Pure decision for the zero-buffer watchdog (unit-tested): restart only
    /// when the armed take is still live, the tap really delivered nothing,
    /// and we have not already retried this hold.
    static func watchdogShouldRestartCapture(
        generationMatches: Bool,
        stillWanted: Bool,
        tapInstalled: Bool,
        buffersSeen: Int,
        alreadyRetried: Bool
    ) -> Bool {
        generationMatches && stillWanted && tapInstalled
            && buffersSeen == 0 && !alreadyRetried
    }

    /// A live input tap delivers a buffer roughly every 85 ms (4096 frames at
    /// 48 kHz); 400 ms with none is a dead engine, not a quiet room.
    private static let zeroBufferWatchdogDelay: TimeInterval = 0.4

    /// A hold this long that produced zero buffers did not capture quiet
    /// speech — the input device delivered nothing at all (wedged device, or
    /// another app holding the input). Comfortably above an accidental
    /// split-second tap, which must stay silent: see the tiny-tap floor
    /// shipped in 0.1.32.
    private static let deadMicMinimumHoldSeconds: TimeInterval = 1.0

    /// Whether a discarded hold should be reported as a dead microphone
    /// rather than silently dropped. Zero buffers means the tap never fired
    /// even once, which the RMS-based silence guard cannot distinguish from a
    /// genuinely quiet room.
    static func shouldReportDeadMic(buffersSeen: Int, holdDuration: TimeInterval) -> Bool {
        buffersSeen == 0 && holdDuration >= deadMicMinimumHoldSeconds
    }

    /// Wall-clock length of the hold being finished, recorded at release so
    /// the discard path can tell a dead mic from an accidental tap.
    private var lastHoldDuration: TimeInterval = 0

    /// A press→release shorter than this with no stream text is an accidental
    /// tap. Measured before the post-release capture grace, which would
    /// otherwise inflate buffered audio past the silence guard's floor.
    static let accidentalTapMaxHoldSeconds: TimeInterval = 0.3

    /// Discard the hold outright (no transcription, no injection, no history
    /// row). Unknown duration (mic never started) is left to the existing
    /// failure paths.
    static func shouldDiscardAccidentalTap(
        holdDuration: TimeInterval?,
        streamTextEver: Bool
    ) -> Bool {
        guard let holdDuration else { return false }
        return holdDuration < accidentalTapMaxHoldSeconds && !streamTextEver
    }

    /// Slack past the recording's own length before the processing HUD is
    /// force-dismissed. Covers finalize + batch upload retry + local fallback
    /// on a healthy day; a stuck hold must not outlive it.
    private static let processingHUDWatchdogBaseSeconds: TimeInterval = 20

    static func processingHUDWatchdogBound(audioDuration: TimeInterval) -> TimeInterval {
        processingHUDWatchdogBaseSeconds + (audioDuration.isFinite ? max(0, audioDuration) : 0)
    }

    /// Only the watchdog armed for the current hold may fire, and only while
    /// the HUD is still showing processing.
    static func shouldFireProcessingWatchdog(
        generation: UInt64,
        currentGeneration: UInt64,
        hudIsProcessing: Bool
    ) -> Bool {
        generation == currentGeneration && hudIsProcessing
    }

    /// Bumped whenever a processing watchdog is armed or cancelled, so a
    /// superseded timer callback no-ops instead of hiding a newer hold's HUD.
    private var processingWatchdogGeneration: UInt64 = 0
    /// Hold the armed watchdog belongs to, so a late finish for an older hold
    /// cannot cancel a newer hold's timer.
    private var processingWatchdogToken: UInt64?

    /// Tracks the most recent start/stop request. Guards against a stale
    /// permission-completion handler (fired after a later stopRecording())
    /// resurrecting a recording the caller already cancelled.
    private var wantsRecording = false

    /// True while `doStop` has claimed the current take. Prevents a second
    /// `doStop` (fn flicker / toggle-lock / tap-resync) from falling through
    /// to the file/batch path after streaming already owns the stop.
    private var isStopping = false

    /// Bumped on every `stopRecording`. Captured into the queued `doStop` so a
    /// stale stop (after a newer stop, or after re-press re-armed recording)
    /// aborts without tearing down the newer session's mic/stream/hold/cache.
    private var stopGeneration: UInt64 = 0

    /// Users release the push-to-talk key on the final syllable — the mic
    /// tap must stay installed and the engine running this much longer past
    /// a NORMAL stop so the trailing word isn't clipped mid-syllable. Not
    /// applied to the secure-input cancel/abort path, which must discard
    /// immediately. The grace buffers still ride the RMS silence guard and
    /// (for streaming engines) must finish landing before
    /// `ElevenLabsRealtimeTranscriber.finalize()` sends its commit frame —
    /// see `finishStop`. Scales up on long holds (cap 1.25s).
    /// Base listen-after-release. 500ms still clipped trailing sentences in
    /// field use; 750ms covers a short last clause after finger-off.
    private static let postReleaseCaptureGraceBase: TimeInterval = 0.750
    private static let postReleaseCaptureGraceMax: TimeInterval = 1.25
    private static let postReleaseCaptureGraceScaleStart: TimeInterval = 15.0
    private static let postReleaseCaptureGraceScalePerSecond: TimeInterval = 0.005

    /// Grace after fn-release before finalize; longer holds get more tail room.
    static func postReleaseCaptureGrace(forHoldDuration duration: TimeInterval) -> TimeInterval {
        guard duration > postReleaseCaptureGraceScaleStart else {
            return postReleaseCaptureGraceBase
        }
        let extra = (duration - postReleaseCaptureGraceScaleStart) * postReleaseCaptureGraceScalePerSecond
        return min(postReleaseCaptureGraceMax, postReleaseCaptureGraceBase + extra)
    }

    /// Read-only seam so tests can assert on the short-hold base constant.
    internal static var postReleaseCaptureGraceForTesting: TimeInterval { postReleaseCaptureGraceBase }

    /// Bumped whenever a post-release capture grace is scheduled or flushed
    /// early, so a stale `asyncAfter` callback from a superseded grace never
    /// runs `finishStop` twice.
    private var stopGraceGeneration: UInt64 = 0

    /// The deferred finalize body for the currently-pending capture grace,
    /// if any. Non-nil only between `scheduleStopGrace` and whichever of
    /// `runStopGraceIfCurrent` / `flushPendingStopGrace` runs it.
    private var stopGraceFinalize: (() -> Void)?

    /// Release-time app-targeting context, sampled once at `doStop` and
    /// carried through the capture grace into `finishStop`.
    private typealias SessionHold = (token: UInt64?, snapshot: CaretContext.Snapshot?, pid: pid_t?)

    /// Returns whether a subtle start/stop sound should play, read fresh at
    /// each call site rather than cached. Wired by `AppDelegate` to
    /// `SettingsStore.playDictationSound`.
    var playDictationSoundProvider: (() -> Bool)?

    /// Continuity / virtual last-resort fallback. Wired by `AppDelegate` to
    /// `SettingsStore.allowLastResortInputFallback`. Default off.
    var allowLastResortInputFallbackProvider: (() -> Bool)?

    /// Explicit input-device preference and Never use set, both keyed by
    /// CoreAudio UID so a device ID never leaks into persisted settings.
    var preferredInputDeviceUIDProvider: (() -> String?)?
    var excludedInputDeviceUIDsProvider: (() -> Set<String>)?

    /// Short label for the HUD key chip (e.g. "fn", "⌥"). Wired by
    /// `AppDelegate` to `SettingsStore.activationKeyOption.hudLabel`.
    var activationKeyLabelProvider: (() -> String)?

    /// Paths that must not be deleted when pruning retained recordings
    /// (failed history rows still need audio for retry). Wired by AppDelegate.
    var protectedAudioPathsProvider: (() -> [String])?

    /// Size budget (bytes) for retained recordings. Wired by AppDelegate to
    /// `SettingsStore.recordingBudgetBytes`.
    var recordingBudgetBytesProvider: (() -> Int64)?

    /// Single shared HUD instance, shown/hidden across the capture lifecycle
    /// — never recreated per recording.
    let hud = RecordingHUD()

    /// Thread-safe smoothed mic level (0...1), written from the realtime
    /// audio-tap thread and consumed on main via `publishLevel`. A simple
    /// exponential smoother keeps the value fluid without allocating on the
    /// audio thread.
    private let levelLock = NSLock()
    private var smoothedLevel: Float = 0

    /// Loudest raw per-buffer RMS seen during the current recording, updated on
    /// the audio thread inside `publishLevel` (under `levelLock`). Read at stop
    /// to gate out silent recordings BEFORE they reach the ASR: Whisper-family
    /// models were trained on subtitled video and hallucinate stock captions
    /// ("thank you", "thanks for watching") on near-silence, so a hold with no
    /// real speech must inject nothing rather than a dreamed phrase.
    private var maxLevelObserved: Float = 0

    /// A per-hold token for queued HUD updates from the audio callback. It is
    /// guarded by `levelLock` with the cumulative RMS so an old hold cannot
    /// paint a no-audio hint over a newer hold.
    private var micHealthGeneration: UInt64 = 0
    private var micHealthMonitor: MicHealthWarningMonitor?

    /// Raw-RMS speech-presence threshold. If the loudest buffer of a whole
    /// recording never crosses this, the clip is treated as silence and the
    /// transcription is skipped entirely. Room tone sits well below this and
    /// speech well above; the observed max is logged at every stop
    /// (`recordingHadSpeech`) so it can be tuned from real data.
    private static let speechRMSThreshold: Float = 0.007

    /// xAI / WhisperKit streaming session state and start/stop decisions.
    private let streamingCoordinator = StreamingCoordinator()

    /// Off-main queue for concatenating buffers, writing CAF, and retention copy.
    private let audioIOQueue = DispatchQueue(label: "com.matt.voice-dictation.audio-io", qos: .userInitiated)

    /// Invalidated when a start attempt settles, times out, or is torn down
    /// so a late completion cannot promote caret / arm the watchdog.
    private var engineStartToken: UInt64 = 0

    /// True from issuing off-main `engine.start()` until that attempt
    /// finishes, times out, or is torn down. Config-change must not treat
    /// capture as live in this window: the tap is installed (`isSetUp`) but
    /// start is still pending.
    private var engineStartInFlight = false

    /// Upper bound for off-main `engine.start()`. A ghost HAL device has
    /// been observed to block indefinitely (2026-08-16); abandon and fail
    /// closed rather than wedge the fn tap.
    private static let engineStartTimeout: TimeInterval = 2.0

    /// Speaker-gating stream processor — allocated only when gating is active
    /// (enabled setting + stored profile). Nil otherwise for zero overhead.
    /// Main sets/clears it (`updateSpeakerGating`) while the audio tap reads it,
    /// so it is published through a lock; the tap takes one retained snapshot
    /// per buffer rather than re-reading the property.
    private let voiceGateProcessorRef = LockedReference<VoiceGateStreamProcessor>()
    private var voiceGateProcessor: VoiceGateStreamProcessor? {
        get { voiceGateProcessorRef.current }
        set { voiceGateProcessorRef.current = newValue }
    }
    private lazy var voiceGateEmbeddingProvider: FluidAudioEmbeddingProvider = FluidAudioEmbeddingProvider()
    private let voiceGateProfileStore = VoiceProfileStore()
    private let voiceGateRecordingSession = VoiceGateRecordingSession()

    /// Publishes in-memory speaker-gate telemetry snapshots on the main queue.
    var voiceGateTelemetryPublisher: ((VoiceGateTelemetrySnapshot) -> Void)?

    /// Main-run-loop poll for mid-hold secure input. Must never run Carbon
    /// checks on the realtime audio-tap thread.
    private var secureInputPollTimer: Timer?

    /// Held-caret generation from `onRecordingWillStart` for this start attempt.
    /// Promoted to `activeHeldCaretToken` when capture actually starts; cleared
    /// (token-matched) on start failure / skip before promote.
    private var pendingHeldCaretToken: UInt64?

    /// Held-caret generation for the in-flight recording session after capture
    /// has started. Stop/abort/silence/empty/write-fail paths clear matching
    /// this token only — never unscoped — so a late teardown cannot wipe a
    /// newer hold from a rapid re-press.
    private var activeHeldCaretToken: UInt64?

    /// AudioRecorder-owned hold triples keyed by session token, frozen when
    /// each token is assigned. `sampleActiveSessionHold` reads this map —
    /// never a live pipeline slot that a newer will-start can steal. Per-token
    /// so session B's cache write cannot erase session A's frozen triple.
    private var cachedSessionHolds: [UInt64: (snapshot: CaretContext.Snapshot?, pid: pid_t?)] = [:]

    /// Pure decision seam for the mid-hold secure-input abort — extracted so
    /// it can be exercised in unit tests, since `IsSecureEventInputEnabled`
    /// (Carbon) cannot be forced on in a test.
    ///
    /// Returns true when an in-flight capture must be aborted: secure input
    /// became active while we were already recording.
    static func shouldAbortForSecureInput(secureInput: Bool, isRecording: Bool) -> Bool {
        secureInput && isRecording
    }

    /// Clears the held caret for this start attempt (token-matched). No-op when
    /// pending is nil — never falls back to unscoped clear (that would wipe a
    /// newer session's hold).
    private func clearPendingHeldCaretSnapshot() {
        if let token = pendingHeldCaretToken {
            asrSelector.clearHeldCaretSnapshot(matching: token)
            clearCachedSessionHold(matching: token)
        }
        pendingHeldCaretToken = nil
    }

    /// Promotes pending → active when mic/stream capture actually begins.
    /// Idempotent: a second call with nil pending (WhisperKit stream-start
    /// promote, then async fallback → `startMicCapture`) must not wipe an
    /// already-active session token.
    private func promotePendingHeldCaretToActive() {
        let next = Self.heldCaretTokensAfterPromote(
            active: activeHeldCaretToken,
            pending: pendingHeldCaretToken
        )
        activeHeldCaretToken = next.active
        pendingHeldCaretToken = next.pending
    }

    /// Async write-fail / late teardown: clear matching a token captured when
    /// the session owned the hold, then drop `active` / `pending` only if
    /// they still match that token.
    private func clearHeldCaretSnapshotMatchingSession(_ token: UInt64?) {
        guard let token else { return }
        asrSelector.clearHeldCaretSnapshot(matching: token)
        if activeHeldCaretToken == token {
            activeHeldCaretToken = nil
        }
        if pendingHeldCaretToken == token {
            pendingHeldCaretToken = nil
        }
        clearCachedSessionHold(matching: token)
    }

    /// Freeze the pipeline hold into the session cache immediately when a
    /// token is assigned (will-start → `startRecording`). Hops to main because
    /// the event-tap path may call `startRecording` off-main.
    private func cacheHoldForAssignedToken(_ token: UInt64?) {
        guard let token else { return }
        let store: () -> Void = { [weak self] in
            guard let self else { return }
            let (snapshot, pid) = self.asrSelector.copyHeldCaretMatching(token)
            self.cachedSessionHolds = Self.insertCachedSessionHold(
                into: self.cachedSessionHolds,
                token: token,
                snapshot: snapshot,
                pid: pid
            )
        }
        if Thread.isMainThread {
            store()
        } else {
            DispatchQueue.main.sync(execute: store)
        }
    }

    private func clearCachedSessionHold(matching token: UInt64) {
        cachedSessionHolds = Self.removeCachedSessionHold(
            from: cachedSessionHolds,
            token: token
        )
    }

    /// Sample this session's hold (token + snapshot + PID) on main at recording
    /// stop — before streaming finalize / audio-IO async gaps that can race a
    /// newer will-start hold. Prefers pending when both slots differ (stale
    /// active from an uncleared prior take must not win); else active, else
    /// pending (stop-before-promote). Does not re-query a live pipeline slot.
    private func sampleActiveSessionHold() -> (
        token: UInt64?,
        snapshot: CaretContext.Snapshot?,
        pid: pid_t?
    ) {
        assert(Thread.isMainThread, "sampleActiveSessionHold requires main thread")
        return Self.sampleCachedSessionHold(
            activeToken: Self.preferredSessionHoldToken(
                active: activeHeldCaretToken,
                pending: pendingHeldCaretToken
            ),
            cache: cachedSessionHolds
        )
    }

    /// Pure seam: re-anchor the session hold at hotkey release only when the
    /// release-time frontmost is known AND differs from the start-time PID.
    /// Same app (or unknown release identity) keeps the start-time hold, so
    /// the long-verified same-app path is byte-for-byte unchanged.
    internal static func shouldRetargetSessionHoldAtRelease(
        startPID: pid_t?,
        releasePID: pid_t?
    ) -> Bool {
        guard let releasePID else { return false }
        return startPID != releasePID
    }

    /// Release-time targeting: the app the user is in when the hotkey is
    /// RELEASED is the inject destination, not the app the hold started in.
    /// (2026-08-10 live abort: a hold began while switching away from
    /// another app, so a perfectly good transcript landed on the clipboard
    /// instead of the frontmost textbox.) Replaces the cached snapshot + PID
    /// with a fresh same-moment sample so caret transforms can never mix
    /// apps. The pre-insert TOCTOU guard in TranscriptionPipeline still
    /// aborts if focus changes between release and insert (cloud finalize
    /// can take seconds).
    private func retargetedSessionHoldAtRelease(
        _ startHold: (token: UInt64?, snapshot: CaretContext.Snapshot?, pid: pid_t?)
    ) -> (token: UInt64?, snapshot: CaretContext.Snapshot?, pid: pid_t?) {
        assert(Thread.isMainThread, "retargetedSessionHoldAtRelease requires main thread")
        guard startHold.token != nil else { return startHold }
        let releasePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard Self.shouldRetargetSessionHoldAtRelease(
            startPID: startHold.pid,
            releasePID: releasePID
        ) else {
            return startHold
        }
        vlog("inject target re-anchored at release — frontmost changed during hold")
        return (startHold.token, CaretContext.snapshot(frontmostPID: releasePID), releasePID)
    }

    /// After inject pipeline finishes a take: drop that take's AudioRecorder
    /// session slots + cache entry. Token-matched so a newer pending that
    /// differs from the consumed token is preserved. Does not touch the live
    /// pipeline hold (inject already cleared it on success paths).
    private func clearConsumedSessionHold(sampledToken: UInt64?) {
        let clearToken = Self.consumedSessionHoldClearToken(
            sampled: sampledToken,
            active: activeHeldCaretToken,
            pending: pendingHeldCaretToken
        )
        guard let clearToken else { return }
        let next = Self.sessionHoldStateAfterConsume(
            active: activeHeldCaretToken,
            pending: pendingHeldCaretToken,
            cache: cachedSessionHolds,
            clearToken: clearToken
        )
        activeHeldCaretToken = next.active
        pendingHeldCaretToken = next.pending
        cachedSessionHolds = next.cache
    }

    /// Testable seam: promote is a no-op when pending is nil so an already-
    /// active token survives WhisperKit fallback re-entry.
    internal static func heldCaretTokensAfterPromote(
        active: UInt64?,
        pending: UInt64?
    ) -> (active: UInt64?, pending: UInt64?) {
        guard let pending else {
            return (active, nil)
        }
        return (pending, nil)
    }

    /// Prefer pending when both slots are set and differ (newer session wins
    /// over a stale uncleared active from a prior take). Otherwise
    /// `active ?? pending` (stop-before-promote / single-slot cases).
    internal static func preferredSessionHoldToken(
        active: UInt64?,
        pending: UInt64?
    ) -> UInt64? {
        if let pending, active != nil, pending != active {
            return pending
        }
        return active ?? pending
    }

    /// Testable seam: teardown clear token selection — same preference as
    /// sample (never unscoped when a session token is known).
    internal static func teardownHeldCaretClearToken(
        active: UInt64?,
        pending: UInt64?
    ) -> UInt64? {
        preferredSessionHoldToken(active: active, pending: pending)
    }

    /// Tokens to clear on mid-hold secure abort.
    ///
    /// When active≠pending and recording was still wanted (re-press already
    /// armed a newer hold), clear **only** the aborted active capture so the
    /// pending hold survives. When not re-armed and both differ, clear both
    /// (full abort of in-flight holds). Otherwise the single preferred token
    /// from `teardownHeldCaretClearToken`.
    internal static func secureAbortClearTokens(
        active: UInt64?,
        pending: UInt64?,
        wantsRecording: Bool
    ) -> [UInt64] {
        if let active, let pending, pending != active {
            if wantsRecording {
                return [active]
            }
            return [active, pending]
        }
        if let token = teardownHeldCaretClearToken(active: active, pending: pending) {
            return [token]
        }
        return []
    }

    /// Token to clear after a take finishes inject: prefer the stop-sampled
    /// token; when sampled is nil, same preference as
    /// `preferredSessionHoldToken` (pending when active≠pending).
    internal static func consumedSessionHoldClearToken(
        sampled: UInt64?,
        active: UInt64?,
        pending: UInt64?
    ) -> UInt64? {
        if let sampled { return sampled }
        return preferredSessionHoldToken(active: active, pending: pending)
    }

    /// Pure consume: nil matching slots + remove cache entry for `clearToken`
    /// without wiping an unrelated newer pending/active that differs.
    internal static func sessionHoldStateAfterConsume(
        active: UInt64?,
        pending: UInt64?,
        cache: [UInt64: (snapshot: CaretContext.Snapshot?, pid: pid_t?)],
        clearToken: UInt64
    ) -> (
        active: UInt64?,
        pending: UInt64?,
        cache: [UInt64: (snapshot: CaretContext.Snapshot?, pid: pid_t?)]
    ) {
        (
            active == clearToken ? nil : active,
            pending == clearToken ? nil : pending,
            removeCachedSessionHold(from: cache, token: clearToken)
        )
    }

    /// Testable seam: skip a queued `doStop` when a newer stop superseded it
    /// or a re-press already re-armed `wantsRecording`. Never skip while
    /// `engine.start()` is in flight — that teardown invalidates the start
    /// token so a re-press cannot issue a second `start()` on the same engine.
    internal static func shouldSkipStaleDoStop(
        wantsRecording: Bool,
        capturedGeneration: UInt64,
        currentGeneration: UInt64,
        startInFlight: Bool = false
    ) -> Bool {
        if startInFlight { return false }
        return wantsRecording || capturedGeneration != currentGeneration
    }

    /// After tearing down an in-flight `engine.start()`, skip the rest of
    /// `doStop` when a re-press already re-armed the hold (caret/HUD/file
    /// paths would consume the newer session).
    static func shouldReturnAfterInFlightDoStopTeardown(wantsRecording: Bool) -> Bool {
        wantsRecording
    }

    /// Testable seam: one-entry cache map for a session token (mirrors the
    /// insert performed by `cacheHoldForAssignedToken`).
    internal static func makeCachedSessionHold(
        token: UInt64,
        snapshot: CaretContext.Snapshot?,
        pid: pid_t?
    ) -> [UInt64: (snapshot: CaretContext.Snapshot?, pid: pid_t?)] {
        [token: (snapshot, pid)]
    }

    /// Testable seam: insert/update one token without erasing other entries.
    internal static func insertCachedSessionHold(
        into cache: [UInt64: (snapshot: CaretContext.Snapshot?, pid: pid_t?)],
        token: UInt64,
        snapshot: CaretContext.Snapshot?,
        pid: pid_t?
    ) -> [UInt64: (snapshot: CaretContext.Snapshot?, pid: pid_t?)] {
        var next = cache
        next[token] = (snapshot, pid)
        return next
    }

    /// Testable seam: remove one token's cache entry; leave others intact.
    internal static func removeCachedSessionHold(
        from cache: [UInt64: (snapshot: CaretContext.Snapshot?, pid: pid_t?)],
        token: UInt64
    ) -> [UInt64: (snapshot: CaretContext.Snapshot?, pid: pid_t?)] {
        var next = cache
        next.removeValue(forKey: token)
        return next
    }

    /// Testable seam: stop-time sample prefers the cached triple for the
    /// active (or pending) session token over any live pipeline slot a later
    /// hold stole.
    internal static func sampleCachedSessionHold(
        activeToken: UInt64?,
        cache: [UInt64: (snapshot: CaretContext.Snapshot?, pid: pid_t?)]
    ) -> (token: UInt64?, snapshot: CaretContext.Snapshot?, pid: pid_t?) {
        guard let activeToken else {
            return (nil, nil, nil)
        }
        guard let entry = cache[activeToken] else {
            return (activeToken, nil, nil)
        }
        return (activeToken, entry.snapshot, entry.pid)
    }

    // MARK: - Public interface

    func startRecording(heldCaretToken: UInt64? = nil) {
        pendingHeldCaretToken = heldCaretToken
        // A newer hold owns the HUD now; the previous hold's watchdog must
        // not hide it. `startRecording` can arrive off-main.
        if Thread.isMainThread {
            cancelProcessingWatchdog()
        } else {
            DispatchQueue.main.async { [weak self] in self?.cancelProcessingWatchdog() }
        }
        // Freeze hold immediately while this token still owns the pipeline
        // slot — a rapid re-press can steal the live slot before stop samples.
        cacheHoldForAssignedToken(heldCaretToken)
        if IsSecureEventInputEnabled() {
            logger.info("Secure input active — refusing to start capture.")
            clearPendingHeldCaretSnapshot()
            DispatchQueue.main.async { [weak self] in
                self?.asrSelector.onFailure?(.secureInputBlocked)
            }
            return
        }
        wantsRecording = true
        isStopping = false
        pcmBuffersLock.lock()
        micCaptureBeganThisHold = false
        pcmBuffersLock.unlock()
        vlog("AudioRecorder.startRecording — requesting mic permission")
        requestMicrophonePermissionIfNeeded { [weak self] granted in
            vlog("mic permission callback — granted=\(granted)")
            guard let self = self, granted else {
                self?.logger.error("Microphone permission denied.")
                self?.clearPendingHeldCaretSnapshot()
                DispatchQueue.main.async {
                    self?.asrSelector.onFailure?(.micStartFailed)
                }
                return
            }
            DispatchQueue.main.async {
                guard self.wantsRecording else {
                    self.logger.info("Mic permission resolved after stopRecording() — skipping start.")
                    self.clearPendingHeldCaretSnapshot()
                    return
                }
                self.doStart()
            }
        }
    }

    func stopRecording() {
        wantsRecording = false
        stopGeneration &+= 1
        let generation = stopGeneration
        invalidateSecureInputPollTimer()
        endVoiceGateRecordingSession()
        DispatchQueue.main.async { [weak self] in
            self?.doStop(capturedGeneration: generation)
        }
    }

    /// Pushes live speaker-gating settings from `SettingsStore`. Active only
    /// when `enabled` is true AND a profile exists on disk.
    func updateSpeakerGating(enabled: Bool, sensitivity: VoiceGateSensitivity) {
        let profile = voiceGateProfileStore.load()
        if enabled, profile?.modelId == FluidAudioEmbeddingProvider.modelId {
            voiceGateEmbeddingProvider.retryLoadingIfNeeded()
            if voiceGateProcessor == nil {
                let gate = VoiceGate(
                    profileStore: voiceGateProfileStore,
                    embeddingProvider: voiceGateEmbeddingProvider,
                    sensitivity: sensitivity
                )
                voiceGateProcessor = VoiceGateStreamProcessor(
                    gate: gate,
                    recordingSession: voiceGateRecordingSession,
                    onTelemetryUpdate: { [weak self] in
                        guard let self else { return }
                        let snapshot = self.voiceGateRecordingSession.snapshot()
                        self.voiceGateTelemetryPublisher?(snapshot)
                    }
                )
            } else {
                voiceGateProcessor?.updateSensitivity(sensitivity)
            }
            voiceGateProcessor?.isActive = true
        } else {
            // End the shared session before dropping the processor — otherwise
            // a mid-hold Focus disable / profile clear leaves isSessionActive
            // stuck true (Settings "listening…" forever) and in-flight evals
            // can still commit.
            voiceGateProcessor?.isActive = false
            endVoiceGateRecordingSession()
            voiceGateProcessor = nil
        }
    }

    /// Ends the shared gate recording session on every teardown path, including
    /// when the stream processor is nil. Session lifetime is independent of the
    /// optional processor so Focus disable / profile clear / stop / secure-input
    /// abort cannot leave telemetry stuck active. `end()` still bumps the
    /// generation token so in-flight evaluations cannot commit.
    private func endVoiceGateRecordingSession() {
        Self.endGateRecordingSession(
            session: voiceGateRecordingSession,
            processor: voiceGateProcessor,
            onSessionEndedWithoutProcessor: { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.voiceGateTelemetryPublisher?(self.voiceGateRecordingSession.snapshot())
                }
            }
        )
    }

    /// Testable seam for gate-session teardown. Prefer the processor when
    /// present (resets latch/accumulator + publishes via its callback); otherwise
    /// end the shared session directly and invoke `onSessionEndedWithoutProcessor`.
    internal static func endGateRecordingSession(
        session: VoiceGateRecordingSession,
        processor: VoiceGateStreamProcessor?,
        onSessionEndedWithoutProcessor: (() -> Void)? = nil
    ) {
        if let processor {
            processor.endRecordingSession()
        } else {
            session.end()
            onSessionEndedWithoutProcessor?()
        }
    }

    /// Whether doStart / startMicCapture may proceed for the current hold.
    /// Keyed only on `wantsRecording`. `isStopping` is accepted so callers and
    /// tests can pass the sticky stop flag from a prior hold, but it must
    /// **not** veto — doStop on main can set it after a newer startRecording
    /// already re-armed the hold on the event-tap thread (rapid re-press).
    internal static func shouldProceedWithRecordingStart(
        wantsRecording: Bool,
        isStopping: Bool
    ) -> Bool {
        _ = isStopping
        return wantsRecording
    }

    /// Testable seam: begin a gate recording session only while the hold is
    /// still wanted. Mirrors WhisperKit's `guard wantsRecording()` before
    /// late fallback so a permission/async start that lost the race to
    /// `stopRecording` cannot re-activate telemetry "listening…".
    /// Does **not** let sticky `isStopping` block a still-wanted re-press.
    @discardableResult
    internal static func beginGateRecordingSessionIfWanted(
        wantsRecording: Bool,
        isStopping: Bool,
        begin: () -> Void
    ) -> Bool {
        guard shouldProceedWithRecordingStart(
            wantsRecording: wantsRecording,
            isStopping: isStopping
        ) else {
            return false
        }
        begin()
        return true
    }

    // MARK: - Internal

    private func doStart() {
        // Re-check after the permission hop / main dispatch — stopRecording may
        // have cleared wantsRecording on the event-tap thread already.
        // Do not veto on isStopping: doStop may have set it sticky for a prior
        // hold while this hold already re-armed wantsRecording on the tap thread.
        guard Self.shouldProceedWithRecordingStart(
            wantsRecording: wantsRecording,
            isStopping: isStopping
        ) else {
            logger.info("doStart skipped — recording no longer wanted")
            vlog("doStart skipped — wantsRecording=false")
            clearPendingHeldCaretSnapshot()
            return
        }
        // A fast re-press can land while the previous hold's post-release
        // capture grace (Self.postReleaseCaptureGrace) is still pending —
        // end it now, before touching the mic engine / streaming sessions
        // below, so the new hold never overlaps the old one's tap/session.
        flushPendingStopGrace()
        isStopping = false
        streamingCoordinator.resetStreamTextLatch()
        didAnnounceListeningThisTake = false
        startTime = Date()
        loggedUnavailablePreferredUID = nil
        levelLock.lock()
        micHealthGeneration &+= 1
        levelLock.unlock()
        startMicHealthMonitoring()

        if streamingCoordinator.tryStartXAI(asrSelector: asrSelector, startMicCapture: { [weak self] in
            self?.startMicCapture()
        }) {
            return
        }

        if streamingCoordinator.tryStartElevenLabs(asrSelector: asrSelector, startMicCapture: { [weak self] in
            self?.startMicCapture()
        }) {
            return
        }

        if streamingCoordinator.tryStartGemini(asrSelector: asrSelector, startMicCapture: { [weak self] in
            self?.startMicCapture()
        }) {
            return
        }

        if streamingCoordinator.tryStartMuse(asrSelector: asrSelector, startMicCapture: { [weak self] in
            self?.startMicCapture()
        }) {
            return
        }

        if streamingCoordinator.tryStartWhisperKit(
            asrSelector: asrSelector,
            wantsRecording: { [weak self] in self?.wantsRecording ?? false },
            levelCallback: { [weak self] level in self?.hud.pushLevel(level) },
            fallbackToFileBased: { [weak self] in self?.startMicCapture() }
        ) {
            // WhisperKit owns the mic — still poll secure input mid-hold.
            // No AVAudioEngine success callback on this path; announce now.
            announceListeningIfNeeded()
            promotePendingHeldCaretToActive()
            startSecureInputPollTimer()
            return
        }

        vlog("doStart — streaming ineligible, using file-based path")
        startMicCapture()
    }

    /// Installs the mic tap and starts the engine. The tap forks per buffer:
    /// it ALWAYS computes the RMS level for the reactive HUD waveform, then —
    /// in xAI streaming mode — converts + streams the buffer to the socket, or
    /// — in file mode — copies it into `pcmBuffers` for a post-release .caf
    /// transcribe. One mic engine backs both paths so the live pill animates
    /// identically regardless of which transcription backend is active.
    private func startMicCapture(isWatchdogRetry: Bool = false, excluding failedDeviceID: AudioDeviceID? = nil) {
        // Defense in depth for WhisperKit fallback / late doStart: do not
        // begin a gate session (or start the engine) after the hold ended.
        // Keyed on wantsRecording only — sticky isStopping from a prior
        // doStop must not block a still-wanted re-press.
        guard Self.beginGateRecordingSessionIfWanted(
            wantsRecording: wantsRecording,
            isStopping: isStopping,
            begin: { [weak self] in
                self?.voiceGateProcessor?.beginRecordingSession()
            }
        ) else {
            logger.info("startMicCapture skipped — recording no longer wanted")
            vlog("startMicCapture skipped — wantsRecording=false")
            clearPendingHeldCaretSnapshot()
            return
        }

        if defaultInputListenerBlock == nil {
            registerDefaultInputDeviceListener()
        }

        // A second start() on the same engine while HAL is still blocked
        // races the first attempt's stale finish, which may stop() the
        // engine the re-press just started. Tear down / invalidate first.
        if engineStartInFlight {
            vlog("startMicCapture — abandoning in-flight engine.start before a new start()")
            excludeOnNextStartDeviceID = lastBoundInputDeviceID
            teardownMicEngine()
            engineNeedsRebuild = true
        }

        if !isWatchdogRetry {
            watchdogRetriedThisTake = false
        }
        captureGeneration &+= 1

        vlog("startMicCapture — AVAudioEngine begins capture")
        // A recovery restart continues the SAME hold — the audio captured
        // before the device died is real speech; dumping it would trade a
        // dead tail for a dead head. Level max carries over for the same
        // reason (the silence guard judges the whole hold).
        if !isWatchdogRetry {
            pcmBuffersLock.lock()
            pcmBuffers.removeAll()
            micCaptureBeganThisHold = true
            pcmBuffersLock.unlock()

            levelLock.lock()
            maxLevelObserved = 0
            levelLock.unlock()
        }

        let exclude = Self.excludeOnNextMicStart(
            explicit: failedDeviceID,
            persistedFailedID: excludeOnNextStartDeviceID
        )

        // Heal a stale AU CurrentDevice *before* probing format / start.
        // Rebuild-alone is not enough when HAL's default is still the ghost ID.
        let boundID: AudioDeviceID?
        if engineNeedsRebuild {
            vlog("mic engine flagged stale — rebuilding before capture")
            teardownMicEngine()
            boundID = rebuildEngine(excluding: exclude)
        } else {
            boundID = bindAliveInputDevice(excluding: exclude)
        }
        if let boundID {
            excludeOnNextStartDeviceID = Self.persistedExcludeAfterBind(
                boundID: boundID,
                persistedExclude: excludeOnNextStartDeviceID
            )
        }
        if Self.shouldFailClosedWithoutBoundInput(boundID) {
            failMicStart(reason: "no alive input device to bind")
            return
        }

        // A device mid-transition can report a dead format; a tap installed
        // against it never fires. Rebuild once, excluding the failed ID.
        let probeFormat = engine.inputNode.outputFormat(forBus: 0)
        if Self.inputFormatLooksDead(
            sampleRate: probeFormat.sampleRate,
            channelCount: probeFormat.channelCount
        ) {
            let ghostID = boundID
            vlog("input format dead (\(probeFormat.sampleRate) Hz, \(probeFormat.channelCount) ch) — rebuilding engine, excluding \(ghostID ?? 0)")
            teardownMicEngine()
            let rebound = rebuildEngine(excluding: ghostID)
            if Self.shouldFailClosedWithoutBoundInput(rebound) {
                excludeOnNextStartDeviceID = Self.persistedExcludeOnFailClosed(
                    candidate: ghostID,
                    existing: excludeOnNextStartDeviceID
                )
                failMicStart(reason: "bind failed after excluding format-dead device \(ghostID ?? 0)")
                return
            }
            let retryFormat = engine.inputNode.outputFormat(forBus: 0)
            if Self.shouldFailClosedAfterDeadFormatFallback(
                formatStillDead: Self.inputFormatLooksDead(
                    sampleRate: retryFormat.sampleRate,
                    channelCount: retryFormat.channelCount
                )
            ) {
                excludeOnNextStartDeviceID = Self.persistedExcludeOnFailClosed(
                    candidate: ghostID,
                    existing: excludeOnNextStartDeviceID
                )
                failMicStart(
                    reason: "input format still dead after excluding device \(ghostID ?? 0)"
                )
                return
            }
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Avoid double-installing a tap
        if !isSetUp {
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                guard let self = self else { return }

                // Realtime-thread safe: compute smoothed RMS amplitude and
                // publish it for the HUD waveform. Only a Float + a lock — no
                // AppKit access on this thread. Done in BOTH modes.
                if let channelData = buffer.floatChannelData {
                    let frameCount = Int(buffer.frameLength)
                    if frameCount > 0 {
                        var sum: Float = 0
                        let samples = channelData[0]
                        for i in 0 ..< frameCount {
                            let s = samples[i]
                            sum += s * s
                        }
                        self.publishLevel(sqrt(sum / Float(frameCount)))
                    }
                }

                // ALWAYS copy the unmodified mic buffer before speaker gating.
                // This is the bounded recovery/history source: a false gate
                // decision must not destroy the only recording of the hold.
                // If a streaming session fails mid-utterance (socket drops,
                // handshake error), the file/batch fallback can still
                // transcribe the FULL audio instead of losing the front of it.
                // On the streaming-success path these buffers are simply
                // discarded. Cheap for typical push-to-talk holds. The copy is
                // required because `buffer` doesn't outlive this callback.
                if let copy = AVAudioPCMBuffer(
                    pcmFormat: buffer.format,
                    frameCapacity: buffer.frameLength
                ) {
                    copy.frameLength = buffer.frameLength
                    if let srcChannelData = buffer.floatChannelData,
                       let dstChannelData = copy.floatChannelData {
                        for ch in 0 ..< Int(buffer.format.channelCount) {
                            memcpy(
                                dstChannelData[ch],
                                srcChannelData[ch],
                                Int(buffer.frameLength) * MemoryLayout<Float>.size
                            )
                        }
                    }
                    self.pcmBuffersLock.lock()
                    self.pcmBuffers.append(copy)
                    self.pcmBuffersLock.unlock()
                }

                // Gate only the buffer sent to the live provider. The stream
                // processor evaluates the raw samples and snapshots its latch
                // before any async evaluation can affect this buffer.
                let gateProcessor = self.voiceGateProcessor
                gateProcessor?.processBuffer(buffer)

                // Streaming mode: ALSO convert + stream this buffer to the
                // socket (the session consumes it synchronously). Only one of
                // xAI/ElevenLabs is ever active (both gated on the same
                // single-value `cloudModel` selection), so both sends are
                // safe no-ops when their session is nil.
                self.streamingCoordinator.sendToXAI(buffer)
                self.streamingCoordinator.sendToElevenLabs(buffer)
                self.streamingCoordinator.sendToGemini(buffer)
                self.streamingCoordinator.sendToMuse(buffer)
            }
            isSetUp = true
        }

        startEngineOffMain(isWatchdogRetry: isWatchdogRetry)
    }

    /// Constraint: `AVAudioEngine.start()` can block in HAL on a ghost input
    /// (2026-08-16). The HID fn tap runs on `CFRunLoopGetMain()`, so start()
    /// must not run on the main run loop. Tap install, bind, and HUD stay on
    /// main with other engine use; only this blocking call hops off.
    /// Completion hops back to main before caret promote / watchdog arm.
    ///
    /// `start()` can also raise NSException (same Initialize path as
    /// `prepare()`). Swift `try` does not catch that — wrap in
    /// `ObjCExceptionCatcher` or the process aborts.
    ///
    /// Each start() runs on a disposable per-attempt queue. Do not serialize
    /// all starts on one forever-blockable queue: if HAL never returns, later
    /// holds would queue behind that work item and fail their 2s timeout
    /// without ever calling start(). An abandoned blocked start may still
    /// occupy its attempt queue until HAL returns; that must not starve the
    /// next hold's new engine.
    private func startEngineOffMain(isWatchdogRetry: Bool) {
        engineStartToken &+= 1
        let token = engineStartToken
        let generation = captureGeneration
        let engineToStart = engine
        engineStartInFlight = true
        let attemptQueue = DispatchQueue(
            label: "com.matt.voice-dictation.engine-start.\(token)",
            qos: .userInitiated
        )
        attemptQueue.async { [weak self] in
            var swiftError: Error?
            let catchResult = ObjCExceptionCatcher.run({
                do {
                    try engineToStart.start()
                } catch {
                    swiftError = error
                }
            })
            let result: Result<Void, Error>
            switch catchResult {
            case .failure(let nsError):
                result = .failure(nsError)
            case .success:
                if let swiftError {
                    result = .failure(swiftError)
                } else {
                    result = .success(())
                }
            }
            DispatchQueue.main.async {
                self?.handleEngineStartFinished(
                    token: token,
                    generation: generation,
                    engineToStart: engineToStart,
                    result: result,
                    isWatchdogRetry: isWatchdogRetry
                )
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.engineStartTimeout) { [weak self] in
            self?.handleEngineStartTimeout(
                token: token,
                generation: generation,
                engineToStart: engineToStart
            )
        }
    }

    private func handleEngineStartFinished(
        token: UInt64,
        generation: UInt64,
        engineToStart: AVAudioEngine,
        result: Result<Void, Error>,
        isWatchdogRetry: Bool
    ) {
        if token != engineStartToken || generation != captureGeneration {
            if engineToStart.isRunning {
                engineToStart.stop()
            }
            return
        }
        engineStartInFlight = false
        engineStartToken &+= 1
        switch result {
        case .success:
            guard wantsRecording else {
                teardownMicEngine()
                endVoiceGateRecordingSession()
                clearPendingHeldCaretSnapshot()
                return
            }
            if Self.shouldRestartCaptureAfterStartSuccess(
                engineNeedsRebuild: engineNeedsRebuild,
                alreadyRetried: watchdogRetriedThisTake
            ) {
                let currentDefault = Self.halDefaultInputDeviceID()
                if Self.shouldRebuildCaptureAfterInputReroute(
                    lastBound: lastBoundInputDeviceID,
                    currentDefault: currentDefault
                ) {
                    vlog("engine.start succeeded but input changed during start — rebuilding, excluding last-bound")
                    watchdogRetriedThisTake = true
                    let failedID = Self.excludeAfterInputReroute(
                        lastBound: lastBoundInputDeviceID,
                        currentDefault: currentDefault
                    )
                    teardownMicEngine()
                    startMicCapture(isWatchdogRetry: true, excluding: failedID)
                    return
                }
                // Continuity / same-default: a stale rebuild flag must not
                // clip this start. Keep the live tap.
                engineNeedsRebuild = false
            }
            if Self.shouldFailClosedAfterStartSuccessWithPendingRebuild(
                engineNeedsRebuild: engineNeedsRebuild,
                alreadyRetried: watchdogRetriedThisTake
            ) {
                let currentDefault = Self.halDefaultInputDeviceID()
                if Self.shouldRebuildCaptureAfterInputReroute(
                    lastBound: lastBoundInputDeviceID,
                    currentDefault: currentDefault
                ) {
                    excludeOnNextStartDeviceID = Self.persistedExcludeOnFailClosed(
                        candidate: lastBoundInputDeviceID,
                        existing: excludeOnNextStartDeviceID
                    )
                    failMicStart(reason: "input changed during start after retry")
                    return
                }
                engineNeedsRebuild = false
            }
            excludeOnNextStartDeviceID = nil
            // warning: unified log drops `info`, so the hold-start oracle
            // never saw this line (0.1.38 hold classified as NO HOLD).
            logger.warning("AVAudioEngine started — recording")
            announceListeningIfNeeded()
            promotePendingHeldCaretToActive()
            startSecureInputPollTimer()
            armZeroBufferWatchdog()
        case .failure(let error):
            logger.error("AVAudioEngine start failed: \(error.localizedDescription)")
            if !isWatchdogRetry, Self.isGhostInputStartError(error) {
                vlog("engine.start ghost device — rebinding alive input and retrying once")
                watchdogRetriedThisTake = true
                invalidateSecureInputPollTimer()
                let failedID = lastBoundInputDeviceID
                teardownMicEngine()
                engineNeedsRebuild = true
                startMicCapture(isWatchdogRetry: true, excluding: failedID)
                return
            }
            excludeOnNextStartDeviceID = Self.persistedExcludeOnFailClosed(
                candidate: lastBoundInputDeviceID,
                existing: excludeOnNextStartDeviceID
            )
            failMicStart(reason: "engine.start error")
        }
    }

    private func handleEngineStartTimeout(
        token: UInt64,
        generation: UInt64,
        engineToStart: AVAudioEngine
    ) {
        guard token == engineStartToken, generation == captureGeneration else { return }
        engineStartInFlight = false
        engineStartToken &+= 1
        logger.error(
            "AVAudioEngine start timed out after \(Self.engineStartTimeout)s — failing closed"
        )
        vlog("engine.start timed out — abandoning to keep main run loop free")
        if engineToStart.isRunning || engine === engineToStart {
            // stop() from main may unblock a HAL-wedged start() on this
            // attempt's queue; AVAudioEngine is not documented as
            // cross-thread safe — residual affinity risk. The abandoned
            // start may still occupy that queue until HAL returns.
            engineToStart.stop()
        }
        // Next hold must not call start() on this same instance while the
        // abandoned attempt is still inside HAL, and must not re-pick the
        // ghost HAL still advertises as default (`doStart` passes no exclude).
        excludeOnNextStartDeviceID = lastBoundInputDeviceID
        engineNeedsRebuild = true
        failMicStart(reason: "engine.start timed out")
    }

    private func failMicStart(reason: String) {
        logger.error("mic start failed — \(reason)")
        vlog("failMicStart — \(reason)")
        // Next hold's startMicCapture only rebuilds when this is set.
        // Bind/start failures can leave the graph unusable.
        engineNeedsRebuild = true
        invalidateSecureInputPollTimer()
        teardownMicEngine()
        endVoiceGateRecordingSession()
        clearPendingHeldCaretSnapshot()
        DispatchQueue.main.async { [weak self] in
            // onFailure flashes the error pill. hide() here would cancel it.
            self?.asrSelector.onFailure?(.micStartFailed)
        }
    }

    /// Detects the silent-wedge case the config-change notification can miss:
    /// `engine.start()` returned success but the tap never fires. One rebuild
    /// + restart per hold; the tap's always-on pcmBuffers copy is the buffer
    /// counter, so this works identically in streaming and file modes.
    private func armZeroBufferWatchdog() {
        let generation = captureGeneration
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.zeroBufferWatchdogDelay
        ) { [weak self] in
            guard let self else { return }
            self.pcmBuffersLock.lock()
            let buffersSeen = self.pcmBuffers.count
            self.pcmBuffersLock.unlock()

            let action = MicHealth.zeroBufferAction(
                generationMatches: generation == self.captureGeneration,
                stillWanted: self.wantsRecording,
                tapInstalled: self.isSetUp,
                buffersSeen: buffersSeen,
                alreadyRetried: self.watchdogRetriedThisTake
            )
            switch action {
            case .ignore:
                return
            case .fail:
                vlog("mic watchdog: still zero buffers after rebuild — ending capture")
                self.wantsRecording = false
                self.isStopping = true
                self.engineNeedsRebuild = true
                self.invalidateSecureInputPollTimer()
                self.teardownMicEngine()
                self.endVoiceGateRecordingSession()
                self.streamingCoordinator.cancelAll()
                self.clearHeldCaretSnapshotMatchingSession(self.activeHeldCaretToken)
                self.clearPendingHeldCaretSnapshot()
                self.micHealthMonitor = nil
                self.cancelProcessingWatchdog()
                // The existing failure path replaces Listening with the error
                // pill and auto-hides it; hide() here would cancel that pill.
                self.asrSelector.onFailure?(.micDeliveredNoAudio)
                return
            case .restart:
                break
            }

            self.watchdogRetriedThisTake = true
            vlog("mic watchdog: no buffers \(Int(Self.zeroBufferWatchdogDelay * 1000)) ms after engine start — rebuilding engine, restarting capture")
            let failedID = self.lastBoundInputDeviceID
            self.teardownMicEngine()
            self.rebuildEngine(excluding: failedID)
            self.startMicCapture(isWatchdogRetry: true, excluding: failedID)
        }
    }

    private func startSecureInputPollTimer() {
        invalidateSecureInputPollTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if Self.shouldAbortForSecureInput(
                secureInput: IsSecureEventInputEnabled(),
                isRecording: self.wantsRecording && !self.isStopping
            ) {
                self.abortForSecureInput()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        secureInputPollTimer = timer
    }

    private func invalidateSecureInputPollTimer() {
        secureInputPollTimer?.invalidate()
        secureInputPollTimer = nil
    }

    /// Mid-hold secure-input abort: tear down capture/stream and discard audio.
    /// Must not write a file, transcribe, or retain the recording.
    private func abortForSecureInput() {
        invalidateSecureInputPollTimer()
        // Capture before clearing wantsRecording — a re-press may already own
        // a newer pending hold that must not be wiped with the aborted active.
        let abortWantsRecording = wantsRecording
        let abortActive = activeHeldCaretToken
        let abortPending = pendingHeldCaretToken
        wantsRecording = false
        isStopping = true
        logger.info("Secure input active mid-hold — aborting capture.")
        vlog("abortForSecureInput — tearing down mic + streaming")
        endVoiceGateRecordingSession()
        teardownMicEngine()
        pcmBuffersLock.lock()
        pcmBuffers.removeAll(keepingCapacity: false)
        pcmBuffersLock.unlock()
        streamingCoordinator.cancelAll()
        for token in Self.secureAbortClearTokens(
            active: abortActive,
            pending: abortPending,
            wantsRecording: abortWantsRecording
        ) {
            clearHeldCaretSnapshotMatchingSession(token)
        }
        DispatchQueue.main.async { [weak self] in
            self?.cancelProcessingWatchdog()
            self?.hud.hide()
            self?.asrSelector.onFailure?(.secureInputBlocked)
        }
    }

    private func doStop(capturedGeneration: UInt64) {
        // Re-press may have re-armed wantsRecording (or a newer stop bumped
        // stopGeneration) before this queued stop drains — do not tear down
        // the newer session's mic/stream/hold/cache.
        if Self.shouldSkipStaleDoStop(
            wantsRecording: wantsRecording,
            capturedGeneration: capturedGeneration,
            currentGeneration: stopGeneration,
            startInFlight: engineStartInFlight
        ) {
            logger.info("doStop skipped — stale generation or recording re-armed")
            vlog("doStop skipped — wantsRecording=\(wantsRecording) gen=\(capturedGeneration)/\(stopGeneration)")
            return
        }
        // In-flight start must be token-invalidated before a re-press starts
        // another `engine.start()`. Do not run the stop pipeline while
        // re-armed — that would sample/clear the newer hold's caret.
        if engineStartInFlight {
            excludeOnNextStartDeviceID = lastBoundInputDeviceID
            teardownMicEngine()
            engineNeedsRebuild = true
            if Self.shouldReturnAfterInFlightDoStopTeardown(wantsRecording: wantsRecording) {
                vlog("doStop — torn down in-flight start; re-press owns the hold")
                return
            }
        }
        if isStopping {
            invalidateSecureInputPollTimer()
            logger.info("doStop ignored — stop already in progress")
            vlog("doStop ignored — already stopping")
            return
        }
        isStopping = true
        invalidateSecureInputPollTimer()
        // Belt-and-suspenders: a late doStart/startMicCapture that lost the
        // race to stopRecording may have re-begun the session after the
        // synchronous end in stopRecording. Re-end only when still active so
        // we do not double-publish when stopRecording already cleared it.
        if voiceGateRecordingSession.snapshot().isSessionActive {
            endVoiceGateRecordingSession()
        }

        playFeedbackSound(named: "Pop")
        hud.clearInterimText()
        // Flip to processing immediately at fn-release so the pill shows
        // "working on it" while ASR runs, rather than vanishing abruptly.
        // For the streaming path this is normally near-instant (the ASR
        // already ran during the hold) — still set for visual consistency
        // and to cover the brief finalize step.
        DispatchQueue.main.async { [weak self] in self?.hud.setProcessing() }

        // Capture hold before streaming finalize / file-IO Tasks so a rapid
        // re-press cannot poison inject with a newer will-start snapshot.
        // Then re-anchor it to the app frontmost NOW: releasing the hotkey is
        // the targeting gesture — a hold may legitimately start in one app
        // and end in the one the user wants the text in (multi-screen
        // roaming, press-while-switching). Same app or unknown release
        // identity keeps the start-time hold unchanged. Sampled immediately,
        // NOT after the capture grace below — the release is the targeting
        // gesture and must not drift to whatever app is frontmost 250ms
        // later.
        let sessionHold = retargetedSessionHoldAtRelease(sampleActiveSessionHold())
        let holdDuration = startTime.map { Date().timeIntervalSince($0) }

        armProcessingWatchdog(sessionToken: sessionHold.token, audioDuration: holdDuration ?? 0)
        scheduleStopGrace(sessionHold: sessionHold, holdDuration: holdDuration)
    }

    /// Bounds how long the processing HUD can outlive release. On expiry the
    /// HUD is hidden and the hold marked abandoned, so a late result is saved
    /// to History instead of typed into whatever app is focused by then.
    private func armProcessingWatchdog(sessionToken: UInt64?, audioDuration: TimeInterval) {
        processingWatchdogGeneration &+= 1
        let generation = processingWatchdogGeneration
        processingWatchdogToken = sessionToken
        let bound = Self.processingHUDWatchdogBound(audioDuration: audioDuration)
        DispatchQueue.main.asyncAfter(deadline: .now() + bound) { [weak self] in
            self?.fireProcessingWatchdog(generation: generation, sessionToken: sessionToken)
        }
    }

    private func cancelProcessingWatchdog() {
        processingWatchdogGeneration &+= 1
    }

    /// Cancels only when the finishing hold is the one the watchdog guards.
    private func cancelProcessingWatchdog(forToken token: UInt64?) {
        guard token == processingWatchdogToken else { return }
        cancelProcessingWatchdog()
    }

    private func fireProcessingWatchdog(generation: UInt64, sessionToken: UInt64?) {
        guard Self.shouldFireProcessingWatchdog(
            generation: generation,
            currentGeneration: processingWatchdogGeneration,
            hudIsProcessing: hud.isProcessing
        ) else { return }
        processingWatchdogGeneration &+= 1
        logger.warning("Processing HUD watchdog fired — abandoning hold.")
        vlog("processing HUD watchdog fired — hold abandoned, late result goes to History only")
        if let sessionToken {
            asrSelector.pipeline.markHoldAbandoned(sessionToken)
        }
        hud.hide()
    }

    /// Schedules `finishStop` to run after `postReleaseCaptureGrace(forHoldDuration:)`,
    /// leaving the mic tap/engine exactly as they are in the meantime so
    /// trailing buffers keep landing in `pcmBuffers` and keep streaming to
    /// the active cloud transcriber. A fast re-press ends this early via
    /// `flushPendingStopGrace()` instead of waiting out the delay.
    private func scheduleStopGrace(sessionHold: SessionHold, holdDuration: TimeInterval?) {
        stopGraceGeneration &+= 1
        let generation = stopGraceGeneration
        let grace = Self.postReleaseCaptureGrace(forHoldDuration: holdDuration ?? 0)
        stopGraceFinalize = { [weak self] in
            self?.finishStop(sessionHold: sessionHold, holdDuration: holdDuration)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [weak self] in
            self?.runStopGraceIfCurrent(generation)
        }
    }

    /// Pure guard for the scheduled `asyncAfter` grace callback: only the
    /// generation that scheduled it may run it. `flushPendingStopGrace` and
    /// a fresh `scheduleStopGrace` both bump `stopGraceGeneration`, so a
    /// superseded or already-flushed callback finds its generation stale
    /// and no-ops instead of double-running `finishStop`.
    internal static func shouldRunStopGrace(generation: UInt64, currentGeneration: UInt64) -> Bool {
        generation == currentGeneration
    }

    /// Runs the deferred finalize only if nothing already flushed it early
    /// (a fast re-press) and no newer stop superseded it.
    private func runStopGraceIfCurrent(_ generation: UInt64) {
        guard
            Self.shouldRunStopGrace(generation: generation, currentGeneration: stopGraceGeneration),
            let finalize = stopGraceFinalize
        else { return }
        stopGraceFinalize = nil
        finalize()
    }

    /// Ends a pending post-release capture grace immediately, running its
    /// finalize body right now instead of waiting out the remaining delay.
    /// Call this before a new recording starts so a fast re-press can never
    /// overlap two live holds on the same mic engine / streaming session.
    private func flushPendingStopGrace() {
        guard let finalize = stopGraceFinalize else { return }
        stopGraceFinalize = nil
        stopGraceGeneration &+= 1 // invalidate the still-pending timer callback
        finalize()
    }

    /// The stop/finalize sequence proper — unchanged from before the capture
    /// grace existed, just deferred by `postReleaseCaptureGrace` (or run
    /// early by `flushPendingStopGrace`). Tearing the mic tap down here,
    /// rather than at release, is what gives the grace window its buffers:
    /// the tap installed in `startMicCapture` keeps firing — appending to
    /// `pcmBuffers` and calling `sendToXAI`/`sendToElevenLabs`/`sendToGemini`/
    /// `sendToMuse` — for every buffer that arrives before this runs.
    private func finishStop(sessionHold: SessionHold, holdDuration: TimeInterval?) {
        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        lastHoldDuration = elapsed

        if streamingCoordinator.xaiSession != nil
            || streamingCoordinator.elevenLabsSession != nil
            || streamingCoordinator.geminiSession != nil
            || streamingCoordinator.museSession != nil {
            teardownMicEngine()
        }

        // Stop/remove the tap before taking the recovery snapshot. An
        // in-flight callback finishes under this same lock, so its final raw
        // buffer is included rather than racing the stop path.
        pcmBuffersLock.lock()
        let bufferedAudio = pcmBuffers
        pcmBuffersLock.unlock()

        let streamTextEver = streamingCoordinator.coordinatorEverHadStreamText
            || (streamingCoordinator.xaiSession?.hasEverHadNonEmptyStreamText ?? false)
            || (streamingCoordinator.elevenLabsSession?.hasEverHadNonEmptyStreamText ?? false)
            || (streamingCoordinator.geminiSession?.hasEverHadNonEmptyStreamText ?? false)
            || (streamingCoordinator.museSession?.hasEverHadNonEmptyStreamText ?? false)

        if Self.shouldDiscardAccidentalTap(
            holdDuration: holdDuration,
            streamTextEver: streamTextEver
        ) {
            finishAccidentalTap(sessionHeldToken: sessionHold.token)
            return
        }

        let xaiContext = StreamingCoordinator.XAIStopContext(
            duration: elapsed,
            hadSpeech: recordingHadSpeech(),
            bufferedAudio: bufferedAudio,
            streamTextEver: streamTextEver
        )
        if streamingCoordinator.handleStopXAI(
            context: xaiContext,
            onSilence: { [weak self] in
                self?.finishDiscardedHold(
                    reason: "silence-guard",
                    engineID: "cloud:xai-streaming",
                    sessionHeldToken: sessionHold.token
                )
            },
            onStreamSuccess: { [weak self] text in
                self?.retainStreamedAudio(buffers: bufferedAudio) { [weak self] retainedURL in
                    self?.asrSelector.logStreamedTranscription(
                        text: text,
                        engineID: "cloud:xai-streaming",
                        retainedAudioURL: retainedURL,
                        sessionHeldToken: sessionHold.token,
                        sessionHeldSnapshot: sessionHold.snapshot,
                        sessionHeldFrontmostPID: sessionHold.pid
                    ) { [weak self] result in
                        self?.finishHUDAfterPipeline(
                            result: result,
                            sessionHeldToken: sessionHold.token
                        )
                    }
                }
            },
            onBatchFallback: { [weak self] buffers, duration in
                guard let self = self else { return }
                guard !buffers.isEmpty else {
                    self.finishDiscardedHold(
                        reason: "empty-buffer-abort",
                        engineID: "cloud:xai-streaming",
                        sessionHeldToken: sessionHold.token
                    )
                    return
                }
                self.writeToFile(
                    duration: duration,
                    buffers: buffers,
                    sessionHeldToken: sessionHold.token,
                    sessionHeldSnapshot: sessionHold.snapshot,
                    sessionHeldFrontmostPID: sessionHold.pid
                )
            }
        ) {
            return
        }

        let elevenLabsContext = StreamingCoordinator.ElevenLabsStopContext(
            duration: elapsed,
            hadSpeech: recordingHadSpeech(),
            bufferedAudio: bufferedAudio,
            streamTextEver: streamTextEver
        )
        if streamingCoordinator.handleStopElevenLabs(
            context: elevenLabsContext,
            onSilence: { [weak self] in
                self?.finishDiscardedHold(
                    reason: "silence-guard",
                    engineID: "cloud:elevenlabs-streaming",
                    sessionHeldToken: sessionHold.token
                )
            },
            onStreamSuccess: { [weak self] text in
                self?.retainStreamedAudio(buffers: bufferedAudio) { [weak self] retainedURL in
                    self?.asrSelector.logStreamedTranscription(
                        text: text,
                        engineID: "cloud:elevenlabs-streaming",
                        retainedAudioURL: retainedURL,
                        sessionHeldToken: sessionHold.token,
                        sessionHeldSnapshot: sessionHold.snapshot,
                        sessionHeldFrontmostPID: sessionHold.pid
                    ) { [weak self] result in
                        self?.finishHUDAfterPipeline(
                            result: result,
                            sessionHeldToken: sessionHold.token
                        )
                    }
                }
            },
            onBatchFallback: { [weak self] buffers, duration in
                guard let self = self else { return }
                guard !buffers.isEmpty else {
                    self.finishDiscardedHold(
                        reason: "empty-buffer-abort",
                        engineID: "cloud:elevenlabs-streaming",
                        sessionHeldToken: sessionHold.token
                    )
                    return
                }
                self.writeToFile(
                    duration: duration,
                    buffers: buffers,
                    sessionHeldToken: sessionHold.token,
                    sessionHeldSnapshot: sessionHold.snapshot,
                    sessionHeldFrontmostPID: sessionHold.pid
                )
            }
        ) {
            return
        }

        let geminiContext = StreamingCoordinator.GeminiStopContext(
            duration: elapsed,
            hadSpeech: recordingHadSpeech(),
            bufferedAudio: bufferedAudio,
            streamTextEver: streamTextEver
        )
        if streamingCoordinator.handleStopGemini(
            context: geminiContext,
            onSilence: { [weak self] in
                self?.finishDiscardedHold(
                    reason: "silence-guard",
                    engineID: "cloud:gemini-streaming",
                    sessionHeldToken: sessionHold.token
                )
            },
            onStreamSuccess: { [weak self] text in
                self?.retainStreamedAudio(buffers: bufferedAudio) { [weak self] retainedURL in
                    self?.asrSelector.logStreamedTranscription(
                        text: text,
                        engineID: "cloud:gemini-streaming",
                        retainedAudioURL: retainedURL,
                        sessionHeldToken: sessionHold.token,
                        sessionHeldSnapshot: sessionHold.snapshot,
                        sessionHeldFrontmostPID: sessionHold.pid
                    ) { [weak self] result in
                        self?.finishHUDAfterPipeline(
                            result: result,
                            sessionHeldToken: sessionHold.token
                        )
                    }
                }
            },
            onBatchFallback: { [weak self] buffers, duration in
                guard let self = self else { return }
                guard !buffers.isEmpty else {
                    self.finishDiscardedHold(
                        reason: "empty-buffer-abort",
                        engineID: "cloud:gemini-streaming",
                        sessionHeldToken: sessionHold.token
                    )
                    return
                }
                self.writeToFile(
                    duration: duration,
                    buffers: buffers,
                    sessionHeldToken: sessionHold.token,
                    sessionHeldSnapshot: sessionHold.snapshot,
                    sessionHeldFrontmostPID: sessionHold.pid
                )
            }
        ) {
            return
        }

        let museContext = StreamingCoordinator.MuseStopContext(
            duration: elapsed,
            hadSpeech: recordingHadSpeech(),
            bufferedAudio: bufferedAudio,
            streamTextEver: streamTextEver
        )
        if streamingCoordinator.handleStopMuse(
            context: museContext,
            onSilence: { [weak self] in
                self?.finishDiscardedHold(
                    reason: "silence-guard",
                    engineID: "cloud:meta-streaming",
                    sessionHeldToken: sessionHold.token
                )
            },
            onStreamSuccess: { [weak self] text in
                self?.retainStreamedAudio(buffers: bufferedAudio) { [weak self] retainedURL in
                    self?.asrSelector.logStreamedTranscription(
                        text: text,
                        engineID: "cloud:meta-streaming",
                        retainedAudioURL: retainedURL,
                        sessionHeldToken: sessionHold.token,
                        sessionHeldSnapshot: sessionHold.snapshot,
                        sessionHeldFrontmostPID: sessionHold.pid
                    ) { [weak self] result in
                        self?.finishHUDAfterPipeline(
                            result: result,
                            sessionHeldToken: sessionHold.token
                        )
                    }
                }
            },
            onBatchFallback: { [weak self] buffers, duration in
                guard let self = self else { return }
                guard !buffers.isEmpty else {
                    self.finishDiscardedHold(
                        reason: "empty-buffer-abort",
                        engineID: "cloud:meta-streaming",
                        sessionHeldToken: sessionHold.token
                    )
                    return
                }
                self.writeToFile(
                    duration: duration,
                    buffers: buffers,
                    sessionHeldToken: sessionHold.token,
                    sessionHeldSnapshot: sessionHold.snapshot,
                    sessionHeldFrontmostPID: sessionHold.pid
                )
            }
        ) {
            return
        }

        if streamingCoordinator.handleStopWhisperKit(
            onEmpty: { [weak self] in
                self?.finishDiscardedHold(
                    reason: "stream-empty",
                    engineID: "whisperKit:streaming",
                    sessionHeldToken: sessionHold.token
                )
            },
            onSuccess: { [weak self] text in
                self?.asrSelector.logStreamedTranscription(
                    text: text,
                    engineID: "whisperKit:streaming",
                    sessionHeldToken: sessionHold.token,
                    sessionHeldSnapshot: sessionHold.snapshot,
                    sessionHeldFrontmostPID: sessionHold.pid
                ) { [weak self] result in
                    self?.finishHUDAfterPipeline(
                        result: result,
                        sessionHeldToken: sessionHold.token
                    )
                }
            }
        ) {
            return
        }

        stopFileBasedCapture(
            sessionHeldToken: sessionHold.token,
            sessionHeldSnapshot: sessionHold.snapshot,
            sessionHeldFrontmostPID: sessionHold.pid,
            everHadStreamText: streamTextEver
                || streamingCoordinator.coordinatorEverHadStreamText
        )
    }

    /// Teardown for the file-based (tap+buffer) path — only touches the
    /// `AVAudioEngine`/tap state if `startFileBasedCapture` actually set it
    /// up, so calling this when a streaming session was active instead is
    /// always safe.
    private func stopFileBasedCapture(
        sessionHeldToken: UInt64?,
        sessionHeldSnapshot: CaretContext.Snapshot?,
        sessionHeldFrontmostPID: pid_t?,
        everHadStreamText: Bool = false
    ) {
        pcmBuffersLock.lock()
        let bufferCountAtStop = pcmBuffers.count
        let captureBegan = micCaptureBeganThisHold
        pcmBuffersLock.unlock()
        guard !Self.shouldDiscardAsMicNotSetup(
            isSetUp: isSetUp,
            bufferCount: bufferCountAtStop,
            micCaptureBeganThisHold: captureBegan
        ) else {
            finishDiscardedHold(
                reason: "mic-not-setup",
                engineID: "file",
                sessionHeldToken: sessionHeldToken
            )
            return
        }

        teardownMicEngine()

        pcmBuffersLock.lock()
        let capturedBuffers = pcmBuffers
        pcmBuffersLock.unlock()

        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        lastHoldDuration = elapsed
        logger.info("Recording stopped — duration \(String(format: "%.2f", elapsed))s, \(capturedBuffers.count) buffers")

        guard !capturedBuffers.isEmpty else {
            logger.warning("No audio captured.")
            vlog("file path: empty-buffer abort — no pcmBuffers")
            finishDiscardedHold(
                reason: "empty-buffer-abort",
                engineID: "file",
                sessionHeldToken: sessionHeldToken
            )
            return
        }

        // Non-empty pcmBuffers always proceed to writeToFile — RMS silence
        // cancel only applies when buffers are empty (handled above). Logs
        // quiet-mic bypass for VOICE_DEBUG correlation.
        if !recordingHadSpeech() {
            vlog(
                "file path: silence bypass — buffers=\(capturedBuffers.count) everHadStream=\(everHadStreamText) maxRMS below threshold"
            )
        }

        writeToFile(
            duration: elapsed,
            buffers: capturedBuffers,
            sessionHeldToken: sessionHeldToken,
            sessionHeldSnapshot: sessionHeldSnapshot,
            sessionHeldFrontmostPID: sessionHeldFrontmostPID
        )
    }

    /// Drops a split-second tap: no transcription, no injection, no history
    /// row (a tombstone per stray fn tap would only clutter History). Tears
    /// down the mic and any open stream so nothing keeps running.
    private func finishAccidentalTap(sessionHeldToken: UInt64?) {
        vlog("accidental tap — hold under \(Self.accidentalTapMaxHoldSeconds)s with no stream text, discarding")
        streamingCoordinator.cancelAll()
        teardownMicEngine()
        clearHeldCaretSnapshotMatchingSession(sessionHeldToken)
        clearConsumedSessionHold(sampledToken: sessionHeldToken)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cancelProcessingWatchdog(forToken: sessionHeldToken)
            self.hud.hide()
        }
    }

    /// Tombstone a hold that produced nothing injectable — failed history row
    /// via existing `onTranscriptionLogged` (no parallel HistoryStore write).
    /// Display-only (nil audioPath); does not play failure sound (avoids Basso
    /// on every accidental empty hold).
    private func finishDiscardedHold(
        reason: String,
        engineID: String,
        sessionHeldToken: UInt64?
    ) {
        pcmBuffersLock.lock()
        let buffersSeen = pcmBuffers.count
        pcmBuffersLock.unlock()
        // Zero buffers over a hold long enough to have produced some is a dead
        // input device, not a quiet room — the user must be told, or every
        // dictation looks like it worked and silently vanishes.
        let deadMic = Self.shouldReportDeadMic(
            buffersSeen: buffersSeen,
            holdDuration: lastHoldDuration
        )
        vlog("discarded hold — reason=\(reason) engine=\(engineID) buffers=\(buffersSeen) deadMic=\(deadMic)")
        clearHeldCaretSnapshotMatchingSession(sessionHeldToken)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.cancelProcessingWatchdog(forToken: sessionHeldToken)
            self.asrSelector.onTranscriptionLogged?(
                "",
                engineID,
                false,
                nil,
                true,
                nil
            )
            if deadMic {
                // Routes through the standard failure path: error pill,
                // failure sound, menu-bar badge.
                self.asrSelector.onFailure?(.micDeliveredNoAudio)
            } else {
                self.hud.hide()
            }
        }
    }

    /// Stops the engine and removes the mic tap. Shared by the file path's
    /// teardown and the xAI-streaming stop (which needs the tap gone before it
    /// finalizes the socket). Safe to call when no tap is installed.
    private func teardownMicEngine() {
        engineStartToken &+= 1
        engineStartInFlight = false
        guard isSetUp else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isSetUp = false
    }

    /// Whether the just-finished recording contained real speech — i.e. its
    /// loudest buffer crossed `speechRMSThreshold`. Used to gate silent holds
    /// out of the ASR entirely (see `maxLevelObserved`). Logs the observed max
    /// each time so the threshold can be calibrated from real recordings.
    private func recordingHadSpeech() -> Bool {
        levelLock.lock()
        let maxLevel = maxLevelObserved
        levelLock.unlock()
        vlog("recording max RMS \(String(format: "%.4f", maxLevel)) (threshold \(String(format: "%.4f", Self.speechRMSThreshold)))")
        return maxLevel >= Self.speechRMSThreshold
    }

    // MARK: - Mic level publishing (audio-reactive waveform)

    /// Called from the realtime audio-tap thread with a raw per-buffer RMS.
    /// Applies a light exponential smoother, guarded by a lock (no
    /// allocation, no AppKit access), then hops to main to push the value
    /// into the HUD's waveform.
    private func publishLevel(_ rawRMS: Float) {
        levelLock.lock()
        // Track the loudest raw buffer of the recording for the silence gate
        // (see maxLevelObserved) — done here under the same lock so the audio
        // thread never takes a second lock.
        if rawRMS > maxLevelObserved { maxLevelObserved = rawRMS }
        // Fast attack / slower decay smoothing done again at the HUD layer;
        // here we just do a light single-pole smoother to de-noise the raw
        // per-buffer RMS before it crosses threads.
        let alpha: Float = rawRMS > smoothedLevel ? 0.6 : 0.3
        smoothedLevel = smoothedLevel + (rawRMS - smoothedLevel) * alpha
        let level = smoothedLevel
        let healthGeneration = micHealthGeneration
        levelLock.unlock()

        // Map smoothed RMS to a 0…1 bar level. This mic runs quiet (measured
        // speech peaks only ~0.02 raw RMS), so subtract a small noise floor to
        // keep room tone flat, then apply a high gain so normal speech clearly
        // drives the bars toward full. Tuned from logged levels; revisit if a
        // hotter mic saturates the bars instantly.
        let normalized = min(1.0, max(0, level - 0.003) * 50)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hud.pushLevel(normalized)
            guard self.wantsRecording,
                  !self.isStopping,
                  self.isCurrentMicHealthGeneration(healthGeneration)
            else { return }
            self.micHealthMonitor?.evaluate()
        }
    }

    private func startMicHealthMonitoring() {
        let generation = micHealthGeneration
        micHealthMonitor = MicHealthWarningMonitor(
            snapshot: { [weak self] in
                guard let self, self.wantsRecording, !self.isStopping else { return nil }
                self.levelLock.lock()
                let isCurrent = generation == self.micHealthGeneration
                let maxLevel = self.maxLevelObserved
                self.levelLock.unlock()
                guard isCurrent else { return nil }
                return MicHealthWarningMonitor.Snapshot(
                    elapsed: self.startTime.map { Date().timeIntervalSince($0) } ?? 0,
                    maxRMS: maxLevel,
                    engineRunning: self.engine.isRunning,
                    deviceName: self.lastBoundInputDeviceName
                )
            },
            warning: { [weak self] deviceName in
                if let deviceName {
                    self?.hud.showMicrophoneNoAudio(deviceName)
                } else {
                    self?.hud.clearMicrophoneNoAudio()
                }
            }
        )
    }

    private func isCurrentMicHealthGeneration(_ generation: UInt64) -> Bool {
        levelLock.lock()
        defer { levelLock.unlock() }
        return generation == micHealthGeneration
    }

    // MARK: - Write captured audio

    /// Concatenates tap buffers into one buffer in the FIRST buffer's format.
    /// A mid-hold device reroute reinstalls the tap in the new device's format
    /// while `pcmBuffers` keeps the pre-reroute audio, so the list can mix
    /// sample rates and channel counts; raw memcpy would play at the wrong
    /// speed or read past a mono buffer's single channel. Non-conforming
    /// buffers go through `AVAudioConverter`; one that cannot convert is
    /// dropped rather than written as garbage. Nil when there is nothing
    /// usable (empty input, non-float32 target, allocation failure).
    static func combine(buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let first = buffers.first else { return nil }
        let format = first.format
        let rate = format.sampleRate
        guard rate > 0, format.channelCount > 0, !format.isInterleaved,
              format.commonFormat == .pcmFormatFloat32 else { return nil }

        var converters: [AVAudioFormat: AVAudioConverter] = [:]
        var segments: [AVAudioPCMBuffer] = []
        var totalFrames: AVAudioFrameCount = 0
        for buffer in buffers {
            guard buffer.frameLength > 0 else { continue }
            let segment: AVAudioPCMBuffer
            if buffer.format == format {
                segment = buffer
            } else {
                guard buffer.format.sampleRate > 0, buffer.format.channelCount > 0 else { continue }
                let converter: AVAudioConverter
                if let cached = converters[buffer.format] {
                    converter = cached
                } else if let made = AVAudioConverter(from: buffer.format, to: format) {
                    converters[buffer.format] = made
                    converter = made
                } else {
                    continue
                }
                let capacity = AVAudioFrameCount(
                    (Double(buffer.frameLength) * rate / buffer.format.sampleRate).rounded(.up) + 64
                )
                guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { continue }
                var supplied = false
                var error: NSError?
                let status = converter.convert(to: out, error: &error) { _, inputStatus in
                    if supplied {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    supplied = true
                    inputStatus.pointee = .haveData
                    return buffer
                }
                guard status != .error, error == nil, out.frameLength > 0 else { continue }
                segment = out
            }
            segments.append(segment)
            totalFrames += segment.frameLength
        }
        guard totalFrames > 0,
              let combined = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames),
              let dst = combined.floatChannelData else { return nil }
        var offset = 0
        for segment in segments {
            guard let src = segment.floatChannelData else { continue }
            let frames = Int(segment.frameLength)
            for ch in 0 ..< Int(format.channelCount) {
                memcpy(dst[ch].advanced(by: offset), src[ch], frames * MemoryLayout<Float>.size)
            }
            offset += frames
        }
        combined.frameLength = AVAudioFrameCount(offset)
        return combined
    }

    /// The hold is a "mic never came up" discard only when there is also no
    /// audio. A release racing a mid-hold restart's `engine.start()` tears the
    /// engine down (`isSetUp` false) while `pcmBuffers` still holds the
    /// pre-restart speech, which must be transcribed like a normal stop.
    /// Buffers left from an earlier hold (this hold's capture never began)
    /// are not this hold's audio and never rescue it.
    static func shouldDiscardAsMicNotSetup(
        isSetUp: Bool,
        bufferCount: Int,
        micCaptureBeganThisHold: Bool = true
    ) -> Bool {
        !isSetUp && (bufferCount == 0 || !micCaptureBeganThisHold)
    }

    /// Persist the raw tap snapshot for a successful cloud stream. This uses
    /// the same retention budget as batch recordings, but never feeds a
    /// second ASR path or shares the filtered provider buffer.
    private func retainStreamedAudio(
        buffers: [AVAudioPCMBuffer],
        completion: @escaping (URL?) -> Void
    ) {
        guard !buffers.isEmpty else {
            completion(nil)
            return
        }
        let buffersCopy = buffers
        audioIOQueue.async { [weak self] in
            guard let self else { return }
            guard let combined = Self.combine(buffers: buffersCopy) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let format = combined.format
            let temporaryURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("voice-\(UUID().uuidString).caf")
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            do {
                let file = try AVAudioFile(
                    forWriting: temporaryURL,
                    settings: format.settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
                try file.write(from: combined)
                let retainedURL = RecordingRetention.retain(
                    from: temporaryURL,
                    keepPaths: self.protectedAudioPathsProvider?() ?? [],
                    maxBytes: self.recordingBudgetBytesProvider?()
                        ?? Int64(RecordingRetention.defaultBudgetMB) * 1024 * 1024
                )
                DispatchQueue.main.async { completion(retainedURL) }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    private func writeToFile(
        duration: TimeInterval,
        buffers: [AVAudioPCMBuffer],
        sessionHeldToken: UInt64?,
        sessionHeldSnapshot: CaretContext.Snapshot?,
        sessionHeldFrontmostPID: pid_t?
    ) {
        guard !buffers.isEmpty else { return }
        // Snapshot buffers for the IO queue — do not touch AVAudioFile / retain on main.
        let buffersCopy = buffers
        // Hold triple was sampled at stop (before this async IO). Token alone
        // still scopes write-fail clears if a newer hold already promoted.

        audioIOQueue.async { [weak self] in
            guard let self = self else { return }

            guard let combined = Self.combine(buffers: buffersCopy) else {
                self.logger.error("Failed to combine \(buffersCopy.count) buffers")
                DispatchQueue.main.async {
                    self.clearHeldCaretSnapshotMatchingSession(sessionHeldToken)
                    self.asrSelector.onTranscriptionLogged?(
                        "",
                        "file",
                        false,
                        nil,
                        true,
                        nil
                    )
                    self.asrSelector.onFailure?(.audioWriteFailed)
                    self.hud.hide()
                }
                return
            }
            let format = combined.format

            // Write to /tmp
            let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("voice-\(UUID().uuidString).caf")

            do {
                let file = try AVAudioFile(
                    forWriting: tmpURL,
                    settings: format.settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
                try file.write(from: combined)
                self.logger.info("Audio written: \(tmpURL.path) (\(String(format: "%.2f", duration))s)")
                vlog("Audio file: \(tmpURL.path)  duration: \(String(format: "%.2f", duration))s")

                let keepPaths = self.protectedAudioPathsProvider?() ?? []
                let maxBytes = self.recordingBudgetBytesProvider?()
                    ?? Int64(RecordingRetention.defaultBudgetMB) * 1024 * 1024
                RecordingRetention.handoffForTranscription(
                    from: tmpURL,
                    keepPaths: keepPaths,
                    maxBytes: maxBytes
                ) { audioURL, retainedURL, cleanup in
                    DispatchQueue.main.async {
                        self.asrSelector.setLastRetainedRecordingURL(retainedURL)
                        self.asrSelector.transcribeAndLog(
                            audioURL: audioURL,
                            audioIsTemporary: retainedURL == nil,
                            sessionHeldToken: sessionHeldToken,
                            sessionHeldSnapshot: sessionHeldSnapshot,
                            sessionHeldFrontmostPID: sessionHeldFrontmostPID
                        ) { [weak self] result in
                            cleanup()
                            self?.finishHUDAfterPipeline(
                                result: result,
                                sessionHeldToken: sessionHeldToken
                            )
                        }
                    }
                }
            } catch {
                self.logger.error("Failed to write audio file: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.clearHeldCaretSnapshotMatchingSession(sessionHeldToken)
                    self.asrSelector.onTranscriptionLogged?(
                        "",
                        "file",
                        false,
                        nil,
                        true,
                        nil
                    )
                    self.asrSelector.onFailure?(.audioWriteFailed)
                    self.hud.hide()
                }
            }
        }
    }

    // MARK: - Feedback sound

    /// Inserted → success checkmark. Dedupe → neutral hide (no fake success).
    /// Failed → hide only when still `.processing` (onFailure may already flash).
    /// All terminal results clear the consumed session hold so the next press
    /// cannot sample a stale active token / cache entry.
    private func finishHUDAfterPipeline(
        result: TranscriptionPipeline.InjectPipelineResult,
        sessionHeldToken: UInt64?
    ) {
        clearConsumedSessionHold(sampledToken: sessionHeldToken)
        cancelProcessingWatchdog(forToken: sessionHeldToken)
        switch result {
        case .inserted:
            hud.showSuccessThenHide()
        case .savedToHistory, .deduped, .failed:
            if hud.isProcessing {
                hud.hide()
            }
        }
    }

    /// Plays the system Basso alert for terminal dictation failures.
    func playFailureSound() {
        guard playDictationSoundProvider?() == true else { return }
        NSSound(named: "Basso")?.play()
    }

    /// Plays a short, distinct built-in system sound if the user has "play
    /// dictation sound" enabled in Settings — `named` a different sound for
    /// start vs stop so the two are distinguishable by ear alone.
    private func playFeedbackSound(named name: NSSound.Name) {
        guard playDictationSoundProvider?() == true else { return }
        NSSound(named: name)?.play()
    }

    /// Tink + HUD after the mic is actually capturing. Once per hold so a
    /// real HAL reroute restart does not chirp twice.
    private func announceListeningIfNeeded() {
        guard !didAnnounceListeningThisTake else { return }
        didAnnounceListeningThisTake = true
        playFeedbackSound(named: "Tink")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.wantsRecording else { return }
            if let label = self.activationKeyLabelProvider?() {
                self.hud.setActivationKeyLabel(label)
            }
            self.hud.show()
        }
    }

    // MARK: - Permissions

    private func requestMicrophonePermissionIfNeeded(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                completion(granted)
            }
        case .denied, .restricted:
            logger.error("""
                Microphone permission denied. Go to System Settings → \
                Privacy & Security → Microphone and enable Murmur.
                """)
            completion(false)
        @unknown default:
            completion(false)
        }
    }
}

/// Lock-guarded optional class reference shared between main and a realtime
/// thread. Readers get a retained snapshot, so a concurrent `nil` assignment
/// cannot release the object out from under an in-flight callback.
final class LockedReference<Value: AnyObject> {
    private let lock = NSLock()
    private var value: Value?

    init(_ value: Value? = nil) {
        self.value = value
    }

    var current: Value? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}
