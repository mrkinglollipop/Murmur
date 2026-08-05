import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os.log

/// Watches the focused field after a confirmed inject and learns inline corrections.
final class CorrectionWatcher {

    /// Invoked on the main queue with (oldRegion, newRegion) when a learn should run.
    var onLearn: ((String, String) -> Void)?

    /// When false, `beginWatch` is a no-op and any active watch is cancelled.
    var isEnabled: Bool = true {
        didSet {
            if !isEnabled {
                cancel()
            }
        }
    }

    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "correction-watcher")
    private var logicState = CorrectionWatcherLogic.State()
    private var focusedElement: AXUIElement?
    private var idleWorkItem: DispatchWorkItem?
    private var timeoutWorkItem: DispatchWorkItem?
    private var keyTap: CFMachPort?
    private var keyTapSource: CFRunLoopSource?
    private var workspaceObserver: NSObjectProtocol?

    func beginWatch(deliveredText: String) {
        cancel()
        guard isEnabled else { return }
        guard !deliveredText.isEmpty else { return }

        guard let snapshot = Self.readFocusedField() else {
            logger.debug("beginWatch aborted — AX unreadable")
            return
        }
        if CorrectionExtractor.exceedsFieldCap(snapshot.value) {
            logger.debug("beginWatch aborted — field over cap")
            return
        }
        guard let located = CorrectionExtractor.locate(
            deliveredText: deliveredText,
            in: snapshot.value,
            caretUTF16: snapshot.caretUTF16
        ) else {
            logger.debug("beginWatch aborted — locate failed")
            return
        }

        focusedElement = snapshot.element
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let now = Date()
        let effects = CorrectionWatcherLogic.begin(
            state: &logicState,
            deliveredText: deliveredText,
            snapshotValue: snapshot.value,
            injectedUTF16Location: located.utf16Location,
            injectedUTF16Length: located.utf16Length,
            frontmostPID: pid,
            now: now
        )
        applyEffects(effects, now: now)
        installKeyTap()
        installWorkspaceObserver()
    }

    func endWatchForNewRecording() {
        let now = Date()
        let effects = CorrectionWatcherLogic.nextRecording(state: &logicState)
        applyEffects(effects, now: now)
    }

    func cancel() {
        let effects = CorrectionWatcherLogic.cancel(state: &logicState)
        applyEffects(effects, now: Date())
    }

    // MARK: - Effects

    private func applyEffects(_ effects: [CorrectionWatcherLogic.Effect], now: Date) {
        for effect in effects {
            switch effect {
            case .scheduleIdleSettle(let deadline):
                idleWorkItem?.cancel()
                let delay = max(0, deadline.timeIntervalSince(now))
                let item = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    let effects = CorrectionWatcherLogic.idleFired(state: &self.logicState)
                    self.applyEffects(effects, now: Date())
                }
                idleWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)

            case .cancelIdleSettle:
                idleWorkItem?.cancel()
                idleWorkItem = nil

            case .scheduleTimeout(let deadline):
                timeoutWorkItem?.cancel()
                let delay = max(0, deadline.timeIntervalSince(now))
                let item = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    let effects = CorrectionWatcherLogic.timeoutFired(state: &self.logicState)
                    self.applyEffects(effects, now: Date())
                }
                timeoutWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)

            case .cancelTimeout:
                timeoutWorkItem?.cancel()
                timeoutWorkItem = nil

            case .tearDown:
                tearDownInfrastructure()

            case .attemptLearn(let reason):
                attemptLearn(reason: reason, now: now)
            }
        }
    }

    private func attemptLearn(reason: CorrectionWatcherLogic.EndReason, now: Date) {
        let snapshot = logicState
        guard CorrectionWatcherLogic.shouldAttemptLearn(state: snapshot, reason: reason, now: now) else {
            logger.debug("learn aborted — stable window unmet reason=\(String(describing: reason))")
            return
        }
        guard let element = focusedElement else { return }
        guard let current = Self.readValue(of: element) else {
            logger.debug("learn aborted — AX re-read failed")
            return
        }
        if CorrectionExtractor.exceedsFieldCap(current) {
            logger.debug("learn aborted — field over cap at re-read")
            return
        }
        guard let diff = CorrectionExtractor.regionDiff(
            snapshotValue: snapshot.snapshotValue,
            injectedUTF16Location: snapshot.injectedUTF16Location,
            injectedUTF16Length: snapshot.injectedUTF16Length,
            currentValue: current
        ) else {
            return
        }
        // Counts only — never log field text.
        logger.info("learn candidate oldChars=\(diff.oldRegion.count) newChars=\(diff.newRegion.count)")
        let learn = onLearn
        DispatchQueue.main.async {
            learn?(diff.oldRegion, diff.newRegion)
        }
    }

    private func tearDownInfrastructure() {
        focusedElement = nil
        removeKeyTap()
        removeWorkspaceObserver()
        idleWorkItem?.cancel()
        idleWorkItem = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
    }

    // MARK: - Key tap

    private func installKeyTap() {
        removeKeyTap()
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        // Unretained: watcher owns tap lifetime and removes it before deinit.
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let watcher = Unmanaged<CorrectionWatcher>.fromOpaque(refcon).takeUnretainedValue()
                if type == .keyDown {
                    DispatchQueue.main.async {
                        let effects = CorrectionWatcherLogic.noteKeyDown(
                            state: &watcher.logicState,
                            now: Date()
                        )
                        watcher.applyEffects(effects, now: Date())
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            logger.debug("key tap unavailable — abort watch")
            cancel()
            return
        }
        keyTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        keyTapSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeKeyTap() {
        if let tap = keyTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = keyTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        keyTap = nil
        keyTapSource = nil
    }

    // MARK: - Workspace

    private func installWorkspaceObserver() {
        removeWorkspaceObserver()
        workspaceObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            let effects = CorrectionWatcherLogic.frontmostChanged(state: &self.logicState, newPID: pid)
            self.applyEffects(effects, now: Date())
        }
    }

    private func removeWorkspaceObserver() {
        if let workspaceObserver {
            NotificationCenter.default.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
    }

    // MARK: - AX helpers

    private struct FieldSnapshot {
        let element: AXUIElement
        let value: String
        let caretUTF16: Int
    }

    private static func readFocusedField(
        frontmostPID: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier
    ) -> FieldSnapshot? {
        guard let pid = frontmostPID else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else { return nil }
        guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let focused = focusedRef as! AXUIElement
        guard let value = readValue(of: focused) else { return nil }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success, let rangeRef,
           let caret = CaretContext.selectedTextOffset(from: rangeRef) else {
            return nil
        }
        return FieldSnapshot(element: focused, value: value, caretUTF16: caret)
    }

    private static func readValue(of element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success, let valueRef, let value = valueRef as? String else {
            return nil
        }
        return value
    }

    deinit {
        cancel()
    }
}
