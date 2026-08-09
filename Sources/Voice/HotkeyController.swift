import AppKit
import Carbon
import Foundation
import os.log

/// Registers a global hotkey (⌃⌥⌘T) to run the manual transform pipeline:
/// rewrite the most recent history entry with the first saved transform (or
/// the user-selected default from TransformsStore) and copy the result to
/// the clipboard with a transient notification.
final class HotkeyController {

    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "hotkey")

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// Resolves the transform to run on manual hotkey press.
    var transformProvider: (() -> Transform?)?

    /// Most recent dictation text from history.
    var lastDictationProvider: (() -> String?)?

    /// Backend choice + keys for `TransformRunner`.
    var transformCredentialsProvider: (() -> TransformCredentials)?

    /// Surfaces the outcome of a hotkey run. Wired by `AppDelegate` to the
    /// recording HUD — the app's established feedback surface, and one that
    /// needs no notification authorization.
    var onResult: ((HotkeyOutcome) -> Void)?

    enum HotkeyOutcome: Equatable {
        /// Transform ran; result is on the clipboard.
        case copiedToClipboard
        case failed(String)
    }

    func start() {
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventCallback,
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )
        guard status == noErr else {
            logger.error("InstallEventHandler failed: \(status)")
            return
        }

        // ⌃⌥⌘T — transform last dictation
        let hotKeyID = EventHotKeyID(signature: OSType(0x564F4943), id: 1) // 'VOIC'
        var ref: EventHotKeyRef?
        let regStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_T),
            UInt32(controlKey | optionKey | cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard regStatus == noErr, let ref else {
            // A collision with another app's ⌃⌥⌘T lands here, and a log-only
            // failure left the user with a hotkey that silently does nothing.
            logger.error("RegisterEventHotKey failed: \(regStatus)")
            report(.failed("Transform hotkey ⌃⌥⌘T unavailable — already in use"))
            return
        }
        hotKeyRef = ref
        logger.info("Transform hotkey registered (⌃⌥⌘T)")
    }

    func stop() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    fileprivate func handleHotkey() {
        guard let transform = transformProvider?(),
              let text = lastDictationProvider?(),
              !text.isEmpty else {
            report(.failed("No dictation or transform available"))
            return
        }
        guard let credentials = transformCredentialsProvider?() else {
            report(.failed("Transform backend not configured"))
            return
        }

        Task {
            do {
                let result = try await TransformRunner.run(
                    prompt: transform.prompt,
                    over: text,
                    credentials: credentials
                )
                await MainActor.run {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(result, forType: .string)
                    self.report(.copiedToClipboard)
                }
            } catch {
                await MainActor.run {
                    self.report(.failed(error.localizedDescription))
                }
            }
        }
    }

    /// Feedback previously went through `NSUserNotification`, deprecated since
    /// macOS 11 against a macOS 26 deployment target — and it was the *only*
    /// signal this hotkey produced, so a silent no-op made success and failure
    /// indistinguishable. The HUD needs no authorization prompt (the reason the
    /// deprecated API was chosen) and already has states for both outcomes.
    private func report(_ outcome: HotkeyOutcome) {
        if Thread.isMainThread {
            onResult?(outcome)
        } else {
            DispatchQueue.main.async { [weak self] in self?.onResult?(outcome) }
        }
    }

    deinit {
        stop()
    }
}

private func hotkeyEventCallback(
    _ handlerCallRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return noErr }
    var hotKeyID = EventHotKeyID()
    GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard hotKeyID.id == 1 else { return noErr }
    let controller = Unmanaged<HotkeyController>.fromOpaque(userData).takeUnretainedValue()
    controller.handleHotkey()
    return noErr
}
