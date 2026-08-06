import AppKit
import CoreGraphics
import Foundation
import os.log

// MARK: - Diagnostic file sink

/// Appends a line to `NSTemporaryDirectory()/voice-debug.log` via FileHandle
/// (written immediately, no stdio buffering, survives GUI-app reparenting) so
/// diagnostics are readable regardless of how the app was launched. File mode
/// is `0o600` (owner-only).
///
/// Debug-only: silent unless `VOICE_DEBUG` is set in the environment, so a
/// shipped app never writes the log. Enable during development by launching
/// with the variable set (e.g. `VOICE_DEBUG=1 /Applications/Murmur.app/Contents/MacOS/Murmur`).
/// Never pass user-dictated transcript text to this function — content stays private.
///
/// File-sink writes are serialized: `TextInjector.log` and activation paths can
/// call `vlog` concurrently; FileHandle seek+write is not thread-safe alone.
private let vlogFileLock = NSLock()

func vlog(_ message: String) {
    guard ProcessInfo.processInfo.environment["VOICE_DEBUG"] != nil else { return }
    let ts = String(format: "%.3f", Date().timeIntervalSince1970)
    let line = "[\(ts)] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("voice-debug.log")
    vlogFileLock.lock()
    defer { vlogFileLock.unlock() }
    let fm = FileManager.default
    if !fm.fileExists(atPath: path) {
        fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    guard let handle = FileHandle(forWritingAtPath: path) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
}

// MARK: - Activation key

/// Which modifier key triggers push-to-talk.
enum ActivationKey {
    /// fn / Globe key (held).  Detected via `.maskSecondaryFn` on a
    /// `.cghidEventTap` + `.defaultTap` (active) tap — the same HID layer that
    /// Karabiner-Elements uses.  This IS reliable with Input Monitoring granted.
    ///
    /// When `consumeFnEvents` is true (the default), standalone fn press/release
    /// events are consumed (callback returns nil) so the OS never triggers the
    /// emoji/dictation picker.  fn+key combos (F-keys, arrows, Delete) pass
    /// through unconsumed.
    case fnGlobe

    /// Right Option key (key code 61).  Fallback / user preference.
    case rightOption
}

// MARK: - Controller

/// Manages global push-to-talk activation via a CGEvent tap.
///
/// ACTIVATION APPROACH — fn / Globe key (default):
///
/// The fn key is visible at the HID event tap level (`.cghidEventTap`) with
/// `.defaultTap` (active) and `.headInsertEventTap`.  The flag is
/// `.maskSecondaryFn`.  This is the same approach used by Karabiner-Elements
/// and confirmed against its open-source callback.
///
/// The earlier comment claiming fn is invisible to CGEvent taps was testing
/// `.cgSessionEventTap` with `.defaultTap` — that level does not receive fn
/// because the system consumes it before coalescing.  `.cghidEventTap` fires
/// BEFORE system coalescing and sees the raw HID event.
///
/// FN-CONSUMPTION (suppressing the Globe/emoji picker):
///
/// By default (`consumeFnEvents == true`) the callback returns `nil` for
/// *standalone* fn `.flagsChanged` transitions, consuming the event so the OS
/// never fires the emoji/dictation picker.  Only pure fn transitions are
/// consumed; the callback never touches `.keyDown`/`.keyUp` events, and it
/// never consumes a `.flagsChanged` event when other modifier flags are
/// simultaneously active (ensuring fn+Shift, fn+Ctrl etc. pass through).
/// Ordinary fn+F-key / fn+arrow / fn+Delete combos generate their own
/// `.keyDown` events which are not in our event mask, so they are never
/// intercepted.
///
/// FALLBACK — if fn-consumption causes misbehaviour on an unusual keyboard
/// layout, set `consumeFnEvents = false`.  The tap then reverts to listen-only
/// behaviour and you must set System Settings → Keyboard →
/// "Press 🌐 (Globe) key to: Do Nothing" manually.
///
/// Right Option (key code 61) is available as `ActivationKey.rightOption` and
/// can be set via `activationKey` for users who prefer it (listen-only, no
/// consumption needed).

final class ActivationController {

    /// Pure guard for scheduled hold-timer work items — rejects stale/cancelled
    /// timers and fires after `stop()` tears down the event tap.
    static func shouldFireHoldTimer(
        work: DispatchWorkItem,
        current: DispatchWorkItem?,
        tapAlive: Bool
    ) -> Bool {
        guard tapAlive, let current, !work.isCancelled, current === work else {
            return false
        }
        return true
    }

    // MARK: - Configuration

    /// Change this to `.rightOption` to use Right Option instead of fn/Globe.
    var activationKey: ActivationKey = .fnGlobe

    /// When `true` (default), standalone fn press/release events are consumed
    /// so the OS never triggers the emoji/dictation picker.  No System Settings
    /// change is required.
    ///
    /// Set to `false` to revert to listen-only behaviour; you must then set
    /// System Settings → Keyboard → "Press 🌐 key to: Do Nothing" manually.
    var consumeFnEvents: Bool = true

    // MARK: - Private state

    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "activation")

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var fnLogicState = FnActivationLogic.State()

    /// Right Option PTT recording — separate from fn toggle-lock state machine.
    private var rightOptionRecording = false

    /// Read fresh from Settings — enables double-tap fn toggle-lock mode.
    var useToggleLockProvider: (() -> Bool)?

    private var holdTimer: DispatchWorkItem?

    /// Previous `.flagsChanged` state, normalized (`.maskNonCoalesced` stripped),
    /// captured at the end of every callback invocation.  Used to compute the
    /// delta (symmetric difference) driving fn-consumption — see
    /// `handleFlagsChanged`.
    private var lastFlags: CGEventFlags = []

    /// Retained pointer to self — released if tap creation fails.
    private var selfPtr: Unmanaged<ActivationController>?

    private let recorder = AudioRecorder()

    /// Read-only access to the underlying recorder (and, via it, the ASR
    /// selector) for UI wiring — e.g. Settings needs to reach the live
    /// `ASREngineSelector`, and AppDelegate wires History/Dictionary capture
    /// into `ASREngineSelector`'s transcription hooks. Does not touch any
    /// fn-detection/recording logic.
    var audioRecorder: AudioRecorder { recorder }

    // MARK: - Start / stop

    func start() {
        checkInputMonitoringPermission()
        installEventTap()
    }

    func stop() {
        holdTimer?.cancel()
        holdTimer = nil

        if fnLogicState.isRecording || rightOptionRecording {
            recorder.stopRecording()
        }
        fnLogicState = FnActivationLogic.State()
        rightOptionRecording = false

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        // Release the retained self pointer if it was never released by a tap failure.
        selfPtr?.release()
        selfPtr = nil
    }

    // MARK: - Input Monitoring permission

    private func checkInputMonitoringPermission() {
        // Input Monitoring access is checked implicitly when tapCreate fires.
        // Log accessibility trust for diagnostics; it is separate from IM.
        let trusted = AXIsProcessTrusted()
        logger.info("Accessibility trusted: \(trusted) (separate from Input Monitoring)")
    }

    // MARK: - CGEvent tap installation

    private func installEventTap() {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        // Bridge self into a C-compatible refcon.  Released in stop() or on failure.
        let ptr = Unmanaged.passRetained(self)
        selfPtr = ptr

        // .cghidEventTap — fires at the HID layer, before system coalescing.
        // This is the only level at which .maskSecondaryFn (fn/Globe) is visible.
        //
        // .defaultTap (active) — allows the callback to return nil to consume
        // events.  We only consume standalone fn flagsChanged events when
        // consumeFnEvents is true; all other events are passed through.
        //
        // .headInsertEventTap — insert at the head of the tap chain so we see
        // events before any other tap (e.g. Karabiner-Elements).
        // An ACTIVE tap (.defaultTap) is required to CONSUME the standalone fn
        // press (suppressing the emoji/dictation picker) — but active taps
        // require ACCESSIBILITY permission. A LISTEN-ONLY tap only needs Input
        // Monitoring. Try the active tap first when we want to consume; if it
        // fails (Accessibility not granted), fall back to listen-only so the
        // app still works with just Input Monitoring — fn is detected, just not
        // suppressed (the user then needs Globe→"Do Nothing", or can grant
        // Accessibility to restore suppression).
        let wantConsume = consumeFnEvents && activationKey == .fnGlobe
        var tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: wantConsume ? .defaultTap : .listenOnly,
            eventsOfInterest: mask,
            callback: activationEventCallback,
            userInfo: ptr.toOpaque()
        )

        if tap == nil && wantConsume {
            vlog("Active tap failed — Accessibility not granted. Falling back to listen-only; fn consumption OFF.")
            consumeFnEvents = false
            tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: activationEventCallback,
                userInfo: ptr.toOpaque()
            )
        }

        guard let tap = tap else {
            logger.error("""
                CGEvent tap creation failed — Input Monitoring permission \
                not granted.  Go to System Settings → Privacy & Security → \
                Input Monitoring and enable Murmur, then relaunch.
                """)
            vlog("TAP INSTALL FAILED — tapCreate returned nil (Input Monitoring not effective for this process)")
            showInputMonitoringAlert()
            ptr.release()
            selfPtr = nil
            return
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = src

        // Seed the delta baseline from the live modifier state so the first
        // event after launch is classified correctly (e.g. Caps Lock already
        // on, or fn already held while the app starts).
        lastFlags = CGEventSource.flagsState(.combinedSessionState)
            .subtracting(.maskNonCoalesced)

        if case .fnGlobe = activationKey {
            // Restart does not start recording; only syncs physical-down for correct edges.
            let fnHeld = lastFlags.contains(.maskSecondaryFn)
            FnActivationLogic.reconcilePhysicalDownAfterRestart(
                state: &fnLogicState,
                fnHeld: fnHeld
            )
        }

        let keyName: String
        switch activationKey {
        case .fnGlobe:
            let consumeNote = consumeFnEvents ? ", consuming standalone fn" : ", listen-only (set Globe→Do Nothing)"
            keyName = "fn / Globe (held)\(consumeNote)"
        case .rightOption:
            keyName = "Right Option (held)"
        }
        logger.info("CGEvent tap installed at HID level — push-to-talk: \(keyName)")
        vlog("TAP INSTALLED — \(keyName)")
    }

    // MARK: - Flag-change handling (called from C callback below)

    // MARK: - Fn consumption + recording hooks

    private func onRecordingWillStart() -> UInt64 {
        let hop: () -> UInt64 = { [weak self] in
            guard let self else { return 0 }
            let token = self.recorder.asrSelector.holdCaretSnapshotFromRecordingWillStart()
            self.recorder.asrSelector.onRecordingStart?()
            return token
        }
        if Thread.isMainThread {
            return hop()
        } else {
            return DispatchQueue.main.sync(execute: hop)
        }
    }

    private func applyFnEffects(_ effects: [FnActivationLogic.Effect]) {
        for effect in effects {
            switch effect {
            case .startRecording:
                let heldToken = onRecordingWillStart()
                recorder.startRecording(heldCaretToken: heldToken)
            case .stopRecording:
                recorder.stopRecording()
            case .scheduleHoldTimer(let deadline):
                holdTimer?.cancel()
                var work: DispatchWorkItem!
                work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    guard Self.shouldFireHoldTimer(
                        work: work,
                        current: self.holdTimer,
                        tapAlive: self.eventTap != nil
                    ) else {
                        return
                    }
                    let now = Date()
                    let useToggleLock = self.useToggleLockProvider?() ?? false
                    let timerEffects = FnActivationLogic.handleHoldTimerFired(
                        state: &self.fnLogicState,
                        useToggleLock: useToggleLock,
                        now: now
                    )
                    self.applyFnEffects(timerEffects)
                    if timerEffects.contains(.startRecording) {
                        if useToggleLock {
                            self.logger.info("Toggle-lock: hold past threshold → PTT recording")
                            vlog("fn HOLD → startRecording()")
                        } else {
                            self.logger.info("Push-to-talk: hold past threshold → starting recording")
                            vlog("fn DOWN → startRecording()")
                        }
                    }
                }
                holdTimer = work
                let delay = max(0, deadline.timeIntervalSinceNow)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            case .cancelHoldTimer:
                holdTimer?.cancel()
                holdTimer = nil
            }
        }
    }

    /// Returns nil to consume a standalone fn transition when configured.
    private func consumeFnIfNeeded(event: CGEvent, normalizedCurrent: CGEventFlags) -> Unmanaged<CGEvent>? {
        let delta = CGEventFlags(rawValue: lastFlags.rawValue ^ normalizedCurrent.rawValue)
        let isPureFnTransition = delta.rawValue == CGEventFlags.maskSecondaryFn.rawValue
        if consumeFnEvents && isPureFnTransition {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    /// Processes a `.flagsChanged` event.  Returns `nil` to consume the event
    /// (suppressing the emoji picker) or the original event to pass it through.
    fileprivate func handleFlagsChanged(
        event: CGEvent,
        type: CGEventType
    ) -> Unmanaged<CGEvent>? {

        // Re-enable the tap if the system disabled it due to timeout or user input.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput,
           let tap = eventTap {
            let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
            logger.warning("CGEvent tap disabled by \(reason) — re-enabling.")
            CGEvent.tapEnable(tap: tap, enable: true)

            if case .fnGlobe = activationKey {
                let sessionFlags = CGEventSource.flagsState(.combinedSessionState)
                let fnHeld = sessionFlags.contains(.maskSecondaryFn)
                let resyncEffects = FnActivationLogic.resyncAfterTapReenable(
                    state: &fnLogicState,
                    fnHeld: fnHeld
                )
                for effect in resyncEffects {
                    switch effect {
                    case .cancelHoldTimer:
                        holdTimer?.cancel()
                        holdTimer = nil
                    case .stopStuckPTTRecording:
                        logger.warning("Resync after tap re-enable: fn not held — stopping stuck recording.")
                        recorder.stopRecording()
                    case .logStuckToggleLockRecording:
                        logger.warning(
                            """
                            Resync after tap re-enable: toggle-locked recording still active \
                            (fn-up is not unlock; user must tap again).
                            """
                        )
                    }
                }
            }
            if rightOptionRecording {
                let sessionFlags = CGEventSource.flagsState(.combinedSessionState)
                if !sessionFlags.contains(.maskAlternate) {
                    rightOptionRecording = false
                    logger.warning("Resync after tap re-enable: Right Option not held — stopping stuck recording.")
                    recorder.stopRecording()
                }
            }

            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags

        switch activationKey {

        case .fnGlobe:
            let fnDown = flags.contains(.maskSecondaryFn)
            let useToggleLock = useToggleLockProvider?() ?? false
            let now = Date()
            let effects = FnActivationLogic.handle(
                state: &fnLogicState,
                fnDown: fnDown,
                useToggleLock: useToggleLock,
                now: now
            )

            for effect in effects {
                switch effect {
                case .startRecording:
                    if fnLogicState.isToggleLocked {
                        logger.info("Toggle-lock: double-tap → starting locked recording")
                        vlog("fn LOCK → startRecording()")
                    } else {
                        logger.info("Push-to-talk: fn DOWN → starting recording")
                        vlog("fn DOWN → startRecording()")
                    }
                case .stopRecording:
                    if fnDown && useToggleLock {
                        logger.info("Toggle-lock: tap while locked → stopping")
                        vlog("fn LOCK TAP → stopRecording()")
                    } else {
                        logger.info("Push-to-talk: fn RELEASE → stopping recording")
                        vlog("fn RELEASE → stopRecording()")
                    }
                case .scheduleHoldTimer, .cancelHoldTimer:
                    break
                }
            }

            applyFnEffects(effects)

            let normalizedCurrent = flags.subtracting(.maskNonCoalesced)
            let result = consumeFnIfNeeded(event: event, normalizedCurrent: normalizedCurrent)
            lastFlags = normalizedCurrent
            return result

        case .rightOption:
            // Right Option: listen-only behaviour — no consumption needed.
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard keyCode == 61 else {
                return Unmanaged.passUnretained(event)
            }
            let keyDown = flags.contains(.maskAlternate)
            if keyDown && !rightOptionRecording {
                rightOptionRecording = true
                logger.info("Push-to-talk: Right Option DOWN → starting recording")
                vlog("rightOption DOWN → startRecording()")
                let heldToken = onRecordingWillStart()
                recorder.startRecording(heldCaretToken: heldToken)
            } else if !keyDown && rightOptionRecording {
                rightOptionRecording = false
                logger.info("Push-to-talk: Right Option RELEASE → stopping recording")
                vlog("rightOption RELEASE → stopRecording()")
                recorder.stopRecording()
            }
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Alerts

    private func showInputMonitoringAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Input Monitoring Permission Required"
            alert.informativeText = """
                Murmur needs Input Monitoring access to detect the \
                push-to-talk key globally.

                Go to System Settings → Privacy & Security → Input Monitoring \
                and enable "Murmur", then relaunch the app.
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Quit")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
                )
            }
            NSApp.terminate(nil)
        }
    }

    deinit {
        stop()
    }
}

// MARK: - C callback (cannot be a closure; bridged via refcon)

/// CGEvent tap callback — must be a plain C function pointer, not a closure.
/// We recover the `ActivationController` from the `userInfo` refcon.
///
/// Returns `nil` to consume the event (suppressing the emoji picker for a
/// standalone fn press) or the original event to pass it through.
private func activationEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let controller = Unmanaged<ActivationController>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    return controller.handleFlagsChanged(event: event, type: type)
}
