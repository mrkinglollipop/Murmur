import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

// MARK: - TextInjector

/// Inserts recognised text at the current cursor position in the focused app.
///
/// Primary lane: clipboard + single Cmd-V chord (Wispr Flow style) — two synthetic
/// events instead of dozens of unicode key events through Tahoe's WindowServer filter.
/// Fallback: CGEvent unicode typing with delivery confirmation, retry, and postToPid.
/// Clipboard+Cmd-V without confirmation previously delivered `text+text` in every app
/// (one `insert` call, two pastes); this implementation posts exactly one chord and
/// verifies delivery before restoring the user's pasteboard.
final class TextInjector {

    private static let dedupeLock = NSLock()
    private static let dedupeWindow: TimeInterval = 1.0
    private static var lastDeliveredText: String?
    private static var lastDeliveredAt: Date?

    typealias DeliveryLane = (String) -> Bool
    internal static var deliveryLaneForTesting: DeliveryLane?

    static func shouldSuppressDuplicateInsert(
        candidate: String,
        lastDeliveredText: String?,
        lastDeliveredAt: Date?,
        now: Date,
        window: TimeInterval
    ) -> Bool {
        guard let prev = lastDeliveredText,
              let at = lastDeliveredAt,
              prev == candidate,
              now.timeIntervalSince(at) < window else {
            return false
        }
        return true
    }

    static func resetDedupeStateForTesting() {
        dedupeLock.lock()
        lastDeliveredText = nil
        lastDeliveredAt = nil
        dedupeLock.unlock()
    }

    /// UTF-16 units per CGEvent. Apple's keyboardSetUnicodeString documents
    /// a practical ceiling around this size; chunk longer transcripts.
    private static let unicodeChunkSize = 16

    private static let confirmationTimeout: TimeInterval = 0.4
    private static let pasteConsumerDelay: TimeInterval = 0.25
    private static let pasteChordTarget = 1
    private static let virtualKeyV: CGKeyCode = 9 // kVK_ANSI_V

    static let concealedPasteboardType = NSPasteboard.PasteboardType(
        rawValue: "org.nspasteboard.ConcealedType"
    )

    enum InsertDeliveryPath: String, Equatable {
        case confirmed
        case confirmedOnRetry
        case unverifiedFallback
        case clipboard
    }

    enum SavedPasteboardRestoreDecision: Equatable {
        case restoreSaved
        case deferRestore
        case doNotRestoreLeaveTranscript
    }

    /// Pure fallback ordering for verified unicode insert attempts.
    static func resolveOutcome(
        confirmed: Bool,
        retryConfirmed: Bool,
        pidFallbackSucceeded: Bool
    ) -> (path: InsertDeliveryPath, shouldReturnTrue: Bool) {
        if confirmed {
            return (.confirmed, true)
        }
        if retryConfirmed {
            return (.confirmedOnRetry, true)
        }
        if pidFallbackSucceeded {
            return (.unverifiedFallback, true)
        }
        return (.clipboard, false)
    }

    /// Whether to restore the pre-insert pasteboard snapshot after lane attempts finish.
    static func resolveSavedPasteboardRestore(
        pasteSucceeded: Bool,
        unicodeSucceeded: Bool,
        allLanesFailed: Bool
    ) -> SavedPasteboardRestoreDecision {
        if pasteSucceeded || unicodeSucceeded {
            return .restoreSaved
        }
        if allLanesFailed {
            return .doNotRestoreLeaveTranscript
        }
        return .deferRestore
    }

    /// Splits `text` into UTF-16 chunks sized for `keyboardSetUnicodeString`.
    static func chunkUTF16Units(_ text: String, maxChunkSize: Int = unicodeChunkSize) -> [[UInt16]] {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return [] }
        var chunks: [[UInt16]] = []
        var index = 0
        while index < units.count {
            let end = min(index + maxChunkSize, units.count)
            chunks.append(Array(units[index..<end]))
            index = end
        }
        return chunks
    }

    /// Reads the current string on `pasteboard`, or nil when absent.
    static func savedPasteboardString(from pasteboard: NSPasteboard) -> String? {
        pasteboard.string(forType: .string)
    }

    /// Writes transcript + concealed marker for paste injection.
    static func preparePasteboardForPaste(_ text: String, on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: concealedPasteboardType)
    }

    /// True when `pasteboard` currently holds exactly `expected` as `.string`.
    /// Used to gate Cmd-V so Universal Clipboard / Continuity cannot slip stale
    /// iPhone copy under our write before the paste chord fires.
    static func pasteboardHoldsExpectedString(_ expected: String, on pasteboard: NSPasteboard) -> Bool {
        pasteboard.string(forType: .string) == expected
    }

    /// Prepares the pasteboard and re-checks until the transcript sticks, or
    /// gives up after `maxAttempts`. External Continuity writers can race a
    /// single `setString`; retrying beats pasting whatever they left behind.
    static func preparePasteboardForPasteStable(
        _ text: String,
        on pasteboard: NSPasteboard,
        maxAttempts: Int = 3,
        retryDelay: TimeInterval = 0.01
    ) -> Bool {
        for attempt in 1...max(1, maxAttempts) {
            preparePasteboardForPaste(text, on: pasteboard)
            if pasteboardHoldsExpectedString(text, on: pasteboard) {
                return true
            }
            if attempt < maxAttempts {
                Thread.sleep(forTimeInterval: retryDelay)
            }
        }
        return false
    }

    /// Restore the saved snapshot only while our injected text is still on the
    /// pasteboard. If Continuity replaced it after paste, leave that alone.
    static func shouldRestoreSavedPasteboard(
        injectedText: String,
        on pasteboard: NSPasteboard
    ) -> Bool {
        pasteboardHoldsExpectedString(injectedText, on: pasteboard)
    }

    /// Restores a prior snapshot: `setString` when there was content, else `clearContents`.
    static func restorePasteboardSnapshot(_ savedString: String?, on pasteboard: NSPasteboard) {
        if let savedString {
            pasteboard.clearContents()
            pasteboard.setString(savedString, forType: .string)
        } else {
            pasteboard.clearContents()
        }
    }

    /// Strips trailing whitespace/newlines only — preserves a deliberately-prepended leading space.
    private static func trimmingTrailingWhitespaceAndNewlines(_ text: String) -> String {
        var result = text
        while let last = result.unicodeScalars.last,
              CharacterSet.whitespacesAndNewlines.contains(last) {
            result.removeLast()
        }
        return result
    }

    @discardableResult
    func insert(_ text: String) -> Bool {
        let trimmed = Self.trimmingTrailingWhitespaceAndNewlines(text)
        guard !trimmed.isEmpty,
              trimmed.contains(where: { !$0.isWhitespace && !$0.isNewline }) else { return false }

        if IsSecureEventInputEnabled() {
            Self.log("blocked secure-input chars=\(trimmed.count)")
            return false
        }

        Self.dedupeLock.lock()
        defer { Self.dedupeLock.unlock() }

        let now = Date()
        if Self.shouldSuppressDuplicateInsert(
            candidate: trimmed,
            lastDeliveredText: Self.lastDeliveredText,
            lastDeliveredAt: Self.lastDeliveredAt,
            now: now,
            window: Self.dedupeWindow
        ) {
            Self.log("DEDUPED chars=\(trimmed.count)")
            return true
        }

        let success: Bool
        if let deliveryLane = Self.deliveryLaneForTesting {
            success = deliveryLane(trimmed)
        } else {
            success = performInsert(trimmed)
        }

        if success {
            Self.lastDeliveredText = trimmed
            Self.lastDeliveredAt = Date()
        }

        return success
    }

    @discardableResult
    private func performInsert(_ trimmed: String) -> Bool {
        let utf16Count = trimmed.utf16.count
        let savedPasteboardString = Self.savedPasteboardString(from: NSPasteboard.general)

        guard let observer = UnicodeDeliveryObserver.create() else {
            // Observer unavailable: paste-blind only. Do not claim success if the
            // chord never posted (e.g. pasteboard race aborted before Cmd-V).
            return insertViaPasteBlind(trimmed, savedPasteboardString: savedPasteboardString)
        }
        defer { observer.stop() }

        let pasteSucceeded = tryPasteLane(trimmed, observer: observer)
        if pasteSucceeded {
            Thread.sleep(forTimeInterval: Self.pasteConsumerDelay)
            if Self.shouldRestoreSavedPasteboard(injectedText: trimmed, on: NSPasteboard.general) {
                Self.restorePasteboardSnapshot(savedPasteboardString, on: NSPasteboard.general)
            } else {
                Self.log("skip pasteboard restore — external overwrite after paste")
            }
            Self.log("paste chord emitted with verified pasteboard chars=\(utf16Count)")
            return true
        }

        observer.resetObservedCount()
        var posted = insertViaUnicodeTyping(trimmed)
        var confirmed = false
        var retryConfirmed = false

        if posted > 0 {
            confirmed = waitForConfirmation(
                observer: observer,
                target: posted,
                counter: .utf16Units
            )
        }

        if !confirmed, posted > 0 {
            Self.log("delivery drop detected — retrying")
            observer.resetObservedCount()
            posted = insertViaUnicodeTyping(trimmed)
            if posted > 0 {
                retryConfirmed = waitForConfirmation(
                    observer: observer,
                    target: posted,
                    counter: .utf16Units
                )
            }
        }

        var pidFallbackSucceeded = false
        if !confirmed, !retryConfirmed {
            if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                pidFallbackSucceeded = insertViaPostToPid(trimmed, pid: pid)
                if pidFallbackSucceeded {
                    Self.log("unverified fallback pid=\(pid) chars=\(utf16Count)")
                }
            }
        }

        let outcome = Self.resolveOutcome(
            confirmed: confirmed,
            retryConfirmed: retryConfirmed,
            pidFallbackSucceeded: pidFallbackSucceeded
        )
        let unicodeSucceeded = outcome.shouldReturnTrue

        switch Self.resolveSavedPasteboardRestore(
            pasteSucceeded: false,
            unicodeSucceeded: unicodeSucceeded,
            allLanesFailed: !unicodeSucceeded
        ) {
        case .restoreSaved:
            Self.restorePasteboardSnapshot(savedPasteboardString, on: NSPasteboard.general)
        case .doNotRestoreLeaveTranscript:
            leaveOnClipboard(trimmed)
        case .deferRestore:
            break
        }

        switch outcome.path {
        case .confirmed, .confirmedOnRetry:
            Self.log("unicode typing confirmed chars=\(utf16Count)")
            return true
        case .unverifiedFallback:
            return true
        case .clipboard:
            return false
        }
    }

    // MARK: - Paste lane

    /// Paste without delivery confirmation. Returns `false` when the chord was
    /// not posted (unstable pasteboard or event creation failure).
    @discardableResult
    private func insertViaPasteBlind(_ text: String, savedPasteboardString: String?) -> Bool {
        guard Self.preparePasteboardForPasteStable(text, on: NSPasteboard.general) else {
            Self.log("paste blind aborted — pasteboard unstable chars=\(text.utf16.count)")
            Self.restorePasteboardSnapshot(savedPasteboardString, on: NSPasteboard.general)
            return false
        }
        guard Self.pasteboardHoldsExpectedString(text, on: NSPasteboard.general) else {
            Self.log("paste blind aborted — pasteboard mismatch before chord")
            Self.restorePasteboardSnapshot(savedPasteboardString, on: NSPasteboard.general)
            return false
        }
        guard postPasteChord() else {
            Self.log("paste blind aborted — chord post failed chars=\(text.utf16.count)")
            if Self.shouldRestoreSavedPasteboard(injectedText: text, on: NSPasteboard.general) {
                Self.restorePasteboardSnapshot(savedPasteboardString, on: NSPasteboard.general)
            }
            return false
        }
        Thread.sleep(forTimeInterval: Self.pasteConsumerDelay)
        if Self.shouldRestoreSavedPasteboard(injectedText: text, on: NSPasteboard.general) {
            Self.restorePasteboardSnapshot(savedPasteboardString, on: NSPasteboard.general)
        }
        Self.log("paste blind chars=\(text.utf16.count)")
        return true
    }

    /// Returns true when a Cmd-V chord is observed *and* the pasteboard still
    /// holds our transcript. Chord-only confirmation previously let Universal
    /// Clipboard win the race and paste stale iPhone copy.
    private func tryPasteLane(_ text: String, observer: UnicodeDeliveryObserver) -> Bool {
        guard Self.preparePasteboardForPasteStable(text, on: NSPasteboard.general) else {
            Self.log("paste lane aborted — could not stabilize pasteboard")
            return false
        }

        func attempt() -> Bool {
            if !Self.pasteboardHoldsExpectedString(text, on: NSPasteboard.general) {
                Self.log("pasteboard mismatch before chord — re-stabilizing")
                guard Self.preparePasteboardForPasteStable(text, on: NSPasteboard.general) else {
                    return false
                }
            }
            guard Self.pasteboardHoldsExpectedString(text, on: NSPasteboard.general) else {
                return false
            }

            observer.resetObservedCount()
            guard postPasteChord() else { return false }
            let chordObserved = waitForConfirmation(
                observer: observer,
                target: Self.pasteChordTarget,
                counter: .pasteChord
            )
            // Chord observed proves WindowServer accepted our events; pasteboard
            // still holding the transcript proves Continuity did not overwrite
            // between prepare and paste. Neither checks target-app content.
            return chordObserved
                && Self.pasteboardHoldsExpectedString(text, on: NSPasteboard.general)
        }

        if attempt() {
            return true
        }

        Self.log("paste delivery drop detected — retrying")
        return attempt()
    }

    @discardableResult
    private func postPasteChord() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            Self.log("no CGEventSource")
            return false
        }
        source.localEventsSuppressionInterval = 0

        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: Self.virtualKeyV,
            keyDown: true
        ) else {
            Self.log("failed to create paste keyDown")
            return false
        }
        keyDown.flags = .maskCommand
        keyDown.post(tap: .cgSessionEventTap)

        guard let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: Self.virtualKeyV,
            keyDown: false
        ) else {
            Self.log("failed to create paste keyUp")
            return false
        }
        keyUp.flags = .maskCommand
        keyUp.post(tap: .cgSessionEventTap)
        return true
    }

    // MARK: - Unicode typing

    /// Posts unicode key events via the session tap. Returns UTF-16 units posted, or 0 on failure.
    private func insertViaUnicodeTyping(_ text: String) -> Int {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            Self.log("no CGEventSource")
            return 0
        }
        source.localEventsSuppressionInterval = 0

        let chunks = Self.chunkUTF16Units(text)
        guard !chunks.isEmpty else { return 0 }

        for chunk in chunks {
            var mutableChunk = chunk
            guard let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: true
            ) else {
                Self.log("failed to create keyDown")
                return 0
            }
            keyDown.keyboardSetUnicodeString(stringLength: mutableChunk.count, unicodeString: &mutableChunk)
            keyDown.post(tap: .cgSessionEventTap)

            if let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: false
            ) {
                keyUp.post(tap: .cgSessionEventTap)
            }
        }
        return chunks.reduce(0) { $0 + $1.count }
    }

    private func insertViaPostToPid(_ text: String, pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            Self.log("no CGEventSource")
            return false
        }
        source.localEventsSuppressionInterval = 0

        let chunks = Self.chunkUTF16Units(text)
        guard !chunks.isEmpty else { return false }

        for chunk in chunks {
            var mutableChunk = chunk
            guard let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: true
            ) else {
                Self.log("failed to create keyDown for postToPid")
                return false
            }
            keyDown.keyboardSetUnicodeString(stringLength: mutableChunk.count, unicodeString: &mutableChunk)
            keyDown.postToPid(pid)

            if let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: false
            ) {
                keyUp.postToPid(pid)
            }
        }
        return true
    }

    private enum ConfirmationCounter {
        case utf16Units
        case pasteChord
    }

    private func waitForConfirmation(
        observer: UnicodeDeliveryObserver,
        target: Int,
        counter: ConfirmationCounter,
        timeout: TimeInterval = TextInjector.confirmationTimeout
    ) -> Bool {
        let observedCount: () -> Int = {
            switch counter {
            case .utf16Units:
                return observer.observedUTF16Units
            case .pasteChord:
                return observer.observedPasteChordCount
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        var confirmed = false
        DispatchQueue(label: "com.matt.voice-dictation.unicode-delivery-wait").async {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if observedCount() >= target {
                    confirmed = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
            if !confirmed {
                confirmed = observedCount() >= target
            }
            semaphore.signal()
        }
        semaphore.wait()
        return confirmed
    }

    private func leaveOnClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Self.log("left on clipboard for manual paste")
    }

    // MARK: - Debug log

    private static func log(_ message: String) {
        vlog("inject: \(message)")
    }
}

// MARK: - Unicode delivery observer

private final class UnicodeDeliveryObserver {
    private let lock = NSLock()
    private var observedUTF16UnitsStorage = 0
    private var observedPasteChordCountStorage = 0
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var workerRunLoop: CFRunLoop?
    private var thread: Thread?
    private let readySemaphore = DispatchSemaphore(value: 0)
    private let finishedSemaphore = DispatchSemaphore(value: 0)
    private(set) var isReady = false
    private let processID = Int64(getpid())
    private static let pasteVirtualKey = Int64(9) // kVK_ANSI_V

    var observedUTF16Units: Int {
        lock.lock()
        defer { lock.unlock() }
        return observedUTF16UnitsStorage
    }

    var observedPasteChordCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return observedPasteChordCountStorage
    }

    func resetObservedCount() {
        lock.lock()
        observedUTF16UnitsStorage = 0
        observedPasteChordCountStorage = 0
        lock.unlock()
    }

    static func create() -> UnicodeDeliveryObserver? {
        let observer = UnicodeDeliveryObserver()
        return observer.isReady ? observer : nil
    }

    private init() {
        thread = Thread { [self] in
            self.runTapThread()
        }
        thread?.name = "UnicodeDeliveryObserver"
        thread?.start()
        readySemaphore.wait()
    }

    func stop() {
        guard isReady, let workerRunLoop else { return }
        CFRunLoopPerformBlock(workerRunLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            if let tap = self.tap {
                CGEvent.tapEnable(tap: tap, enable: false)
            }
            if let src = self.runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
            }
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(workerRunLoop)
        finishedSemaphore.wait()
    }

    private func runTapThread() {
        workerRunLoop = CFRunLoopGetCurrent()

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let retained = Unmanaged.passRetained(self)
        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.tapCallback,
            userInfo: retained.toOpaque()
        ) else {
            retained.release()
            readySemaphore.signal()
            finishedSemaphore.signal()
            return
        }

        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isReady = true
        readySemaphore.signal()

        CFRunLoopRun()

        retained.release()
        finishedSemaphore.signal()
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else {
            return Unmanaged.passUnretained(event)
        }
        let observer = Unmanaged<UnicodeDeliveryObserver>.fromOpaque(refcon).takeUnretainedValue()
        if type == .keyDown {
            observer.recordOwnKeyDown(event)
        }
        return Unmanaged.passUnretained(event)
    }

    private func recordOwnKeyDown(_ event: CGEvent) {
        guard event.getIntegerValueField(.eventSourceUnixProcessID) == processID else { return }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        if keycode == Self.pasteVirtualKey, event.flags.contains(.maskCommand) {
            lock.lock()
            observedPasteChordCountStorage += 1
            lock.unlock()
            return
        }

        // Query with a real buffer: the nil-buffer/zero-length form of
        // keyboardGetUnicodeString is not reliable across macOS versions, and a
        // stuck-at-zero length here would make every insert look undelivered.
        var actualLength = 0
        var buffer = [UniChar](repeating: 0, count: 32)
        event.keyboardGetUnicodeString(
            maxStringLength: buffer.count,
            actualStringLength: &actualLength,
            unicodeString: &buffer
        )
        guard actualLength > 0 else { return }

        lock.lock()
        observedUTF16UnitsStorage += actualLength
        lock.unlock()
    }
}
