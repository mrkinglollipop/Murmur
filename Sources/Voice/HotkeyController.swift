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

    /// BYO OpenAI key for cloud fallback in `TransformRunner`.
    var openAIKeyProvider: (() -> String?)?

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
            logger.error("RegisterEventHotKey failed: \(regStatus)")
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
            notify(title: "Murmur", body: "No dictation or transform available.")
            return
        }

        Task {
            do {
                let result = try await TransformRunner.run(
                    prompt: transform.prompt,
                    over: text,
                    openAIKey: openAIKeyProvider?()
                )
                await MainActor.run {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(result, forType: .string)
                    notify(title: "Transform copied", body: transform.name)
                }
            } catch {
                await MainActor.run {
                    notify(title: "Transform failed", body: error.localizedDescription)
                }
            }
        }
    }

    private func notify(title: String, body: String) {
        // UNUserNotificationCenter needs user authorization and would add a
        // first-run permission prompt for a low-stakes transform toast.
        // NSUserNotification is deprecated but still delivers without that
        // gate on macOS for this Developer-ID menu-bar app — keep until a
        // dedicated notifications entitlement/UX pass lands.
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        NSUserNotificationCenter.default.deliver(notification)
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
