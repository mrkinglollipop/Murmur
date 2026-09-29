import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

// MARK: - TextInjector

/// Inserts recognised text at the current cursor position in the focused app.
///
/// Default primary lane: CGEvent unicode typing with transport observation, one retry,
/// and an F20 canary probe when the observation channel's own testimony is
/// unprovable — **does not touch** `NSPasteboard.general` on any of those
/// paths, so the user's prior copy survives a normal dictate. `postToPid` was
/// removed (2026-08-31): it posted a second, unverifiable copy of the
/// transcript with no way to confirm delivery, compounding the exact
/// duplication bug this file exists to prevent. Fallback: clipboard + single
/// Cmd-V chord (Wispr-style) when unicode cannot confirm; that path snapshots
/// + restores the prior pasteboard after `pasteboardRestoreDelay` so slow
/// Electron/Cursor consumers still read the transcript before restore. Safari
/// receives multi-chunk text through one paste transaction: its web editor can
/// accept separately-posted unicode chunks out of order even when the event tap
/// observes every chunk in order.
final class TextInjector {

    private static let dedupeLock = NSLock()
    private static let dedupeWindow: TimeInterval = 1.0
    private static var lastDeliveredText: String?
    private static var lastDeliveredAt: Date?

    enum InsertResult: Equatable {
        /// Delivery confirmed (paste chord or unicode observer).
        case inserted(deliveredText: String)
        /// Suppressed within the dedupe window — no field mutation.
        case deduped
        /// Failed, or delivery unconfirmed (paste-blind / unverified pid fallback).
        case failed

        /// True only for confirmed field delivery. Dedupe is not a fresh paste.
        var wasInjectedForHistory: Bool {
            switch self {
            case .inserted: return true
            case .deduped, .failed: return false
            }
        }
    }

    /// Leaves transcript on the general pasteboard for manual paste (PID-mismatch
    /// / failed inject). Package-visible for `TranscriptionPipeline`.
    static func leaveTranscriptOnClipboard(_ text: String) {
        clearPendingRestoreBaseline()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        log("left on clipboard for manual paste")
    }

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
    private static let safariBundleIdentifier = "com.apple.Safari"

    enum InjectionLane: Equatable {
        case unicodeWithEvidence
        case pasteOnce
    }

    /// Safari web editors can reorder separate multi-character unicode events.
    /// A single paste is atomic from the editor's perspective. Keep the
    /// pasteboard-free unicode lane everywhere else, and for one-chunk Safari
    /// inserts where reordering is impossible.
    static func injectionLanes(bundleIdentifier: String?, chunkCount: Int) -> [InjectionLane] {
        if bundleIdentifier == safariBundleIdentifier, chunkCount > 1 {
            return [.pasteOnce]
        }
        return [.unicodeWithEvidence, .pasteOnce]
    }

    // Confirmation wait is progress-aware, not a flat timeout: a WindowServer
    // stall DELAYS CGEvent delivery to the observer tap, it does not DROP it.
    // A flat 0.4s window mistook "still arriving" for "never arrived", retried
    // by re-typing the whole transcript, and both copies landed once the
    // stall cleared — doubled text with History recording only one delivery
    // (2026-08-31 double-injection incident). The wait now starts at
    // `confirmationBaseWindow` and extends by `confirmationProgressExtension`
    // every time the observed count moves forward, capped at
    // `confirmationMaxWait` total — so a genuinely stuck send (observed stays
    // at 0, or stalls partway with no further progress) still times out
    // promptly, while a delayed-but-arriving send gets the room it needs.
    private static let confirmationBaseWindow: TimeInterval = 0.4
    private static let confirmationProgressExtension: TimeInterval = 0.4
    private static let confirmationMaxWait: TimeInterval = 2.5
    /// Chord observation is binary (target 1, no partial-progress signal), so
    /// it cannot use the progress-extension mechanics above — it gets a flat,
    /// longer window instead. See `tryPasteLane` for the incident this guards.
    private static let pasteChordConfirmationWindow: TimeInterval = 1.5
    /// Brief yield after the paste chord so typical AppKit consumers read first.
    /// Not a restore gate — see `pasteboardRestoreDelay`.
    private static let pasteConsumerDelay: TimeInterval = 0.25
    /// How long after a confirmed paste chord we wait before restoring the
    /// user's prior pasteboard. Must outlast slow Electron/Cursor paste
    /// handlers; sync restore after `pasteConsumerDelay` alone raced them.
    static let pasteboardRestoreDelay: TimeInterval = 2.0
    private static let pasteChordTarget = 1
    private static let virtualKeyV: CGKeyCode = 9 // kVK_ANSI_V
    /// F20 — a no-op key in effectively every app — used as a canary to prove
    /// the post→WindowServer→tap pipe is live without mutating the document.
    private static let virtualKeyF20: CGKeyCode = 90 // kVK_F20
    /// Canary observation is binary (target 1), like the paste chord, so it
    /// gets a flat window rather than the progress-extension mechanics.
    private static let canaryConfirmationWindow: TimeInterval = 0.6

    /// Bumped whenever a new deferred restore is scheduled so an older
    /// callback cannot clobber a newer dictation's pasteboard state.
    private static let restoreGenerationLock = NSLock()
    private static var restoreGeneration: UInt64 = 0
    /// The user's pre-dictation clipboard while a deferred restore is pending.
    /// Guarded by `restoreGenerationLock`. A paste-lane insert inside the
    /// restore window would otherwise snapshot the pasteboard while it holds
    /// the previous transcript, then supersede the pending restore — losing
    /// the user's original clipboard for good.
    private static var pendingRestoreBaseline: PasteboardSnapshot?

    static let concealedPasteboardType = NSPasteboard.PasteboardType(
        rawValue: "org.nspasteboard.ConcealedType"
    )

    enum InsertDeliveryPath: String, Equatable {
        case confirmed
        case confirmedOnRetry
        case clipboard

        /// Whether delivery into the focused field was actually *observed*
        /// (directly, by keycode evidence, or accepted unverified only after
        /// the F20 canary proved the observation channel itself was blind —
        /// see `canaryVerdict`). `.clipboard` means neither attempt landed
        /// and the paste lane must run.
        var isConfirmedDelivery: Bool {
            switch self {
            case .confirmed, .confirmedOnRetry: return true
            case .clipboard: return false
            }
        }
    }

    enum SavedPasteboardRestoreDecision: Equatable {
        /// Immediate restore — safe when the pasteboard was not the delivery
        /// channel (unicode transport observed).
        case restoreSaved
        /// Restore later so a slow Cmd-V consumer (Electron/Cursor) cannot
        /// read the pre-insert snapshot we just put back. Paste-lane only.
        case restoreSavedDeferred
        case deferRestore
        case doNotRestoreLeaveTranscript
    }

    /// What to do after a confirmation wait ends, given what the observer
    /// actually saw. `acceptPartial` is the anti-double case: some but not all
    /// of the posted text arrived, so the rest is presumed still in flight —
    /// re-typing here would duplicate the part that already landed.
    enum DeliveryFollowUp: Equatable {
        case confirmed
        case retryEligible
        case acceptPartial
    }

    /// Pure post-wait decision — no CGEvents, so directly unit-testable.
    static func deliveryFollowUp(observed: Int, target: Int) -> DeliveryFollowUp {
        if observed >= target {
            return .confirmed
        }
        if observed == 0 {
            return .retryEligible
        }
        return .acceptPartial
    }

    /// Pure deadline arithmetic for the progress-aware confirmation wait.
    /// Extends `currentDeadline` by `progressExtension` on forward progress,
    /// never past `startedAt + maxWait`.
    static func nextConfirmationDeadline(
        startedAt: Date,
        currentDeadline: Date,
        progressExtension: TimeInterval,
        maxWait: TimeInterval
    ) -> Date {
        min(currentDeadline.addingTimeInterval(progressExtension), startedAt.addingTimeInterval(maxWait))
    }

    /// Pure fallback ordering for verified unicode insert attempts. No pid
    /// fallback tier anymore (removed 2026-08-31 — see class doc) so this
    /// only ever lands on the first attempt, the retype, or the paste lane.
    static func resolveOutcome(
        confirmed: Bool,
        retryConfirmed: Bool
    ) -> (path: InsertDeliveryPath, shouldReturnTrue: Bool) {
        if confirmed {
            return (.confirmed, true)
        }
        if retryConfirmed {
            return (.confirmedOnRetry, true)
        }
        return (.clipboard, false)
    }

    /// Terminal decision for a single unicode-typing attempt, given what the
    /// observer actually saw.
    ///
    /// `keycodeZeroObserved` exists because of the 2026-08-31 evidence: during
    /// a system stutter, `keyboardGetUnicodeString` payload readback returned
    /// 0 for our own synthetic events while a keycode-matched Cmd-V chord
    /// posted moments later WAS observed. Payload readback and keycode
    /// matching are two independent witnesses to the same CGEvent stream —
    /// when the first goes blind, the second (virtualKey 0, what our unicode
    /// chunks use) can still prove the chunks flowed. `wentBlind` marks that
    /// the tap itself reported disabled during this window (see
    /// `UnicodeDeliveryObserver`): a witness that admits it blacked out
    /// cannot be trusted for a partial/keycode-only read, only for a count
    /// already at or past target — anything short of that defers to the
    /// canary probe instead of being accepted at face value.
    static func unicodeLaneVerdict(
        utf16Observed: Int,
        utf16Target: Int,
        keycodeZeroObserved: Int,
        chunkTarget: Int,
        wentBlind: Bool
    ) -> UnicodeLaneVerdict {
        guard utf16Target > 0 else { return .confirmed }
        if utf16Observed >= utf16Target {
            return .confirmed
        }
        if !wentBlind {
            if utf16Observed == 0, chunkTarget > 0, keycodeZeroObserved >= chunkTarget {
                return .confirmedByKeycode
            }
            if utf16Observed > 0 || keycodeZeroObserved > 0 {
                return .acceptPartial
            }
        }
        return .needsCanaryProbe
    }

    enum UnicodeLaneVerdict: Equatable {
        /// Payload readback reached target — direct confirmation.
        case confirmed
        /// Payload readback stayed at 0 but keycode-zero evidence reached the
        /// chunk target — delivered, readback itself was blind.
        case confirmedByKeycode
        /// Nonzero-but-short on either counter — some of the posted text
        /// already landed; re-typing would duplicate it. Accept, no escalation.
        case acceptPartial
        /// Both counters at 0 (or a mid-window blind-out with no full count
        /// yet) — cannot tell "not delivered" from "delivered but
        /// unobservable" without more evidence. Post the F20 canary next.
        case needsCanaryProbe
    }

    /// Post-canary decision. The canary (F20 keyDown+keyUp — a no-op key in
    /// effectively every app) proves the post→WindowServer→tap pipe is live
    /// *without mutating the document*, distinguishing "observer blind" from
    /// "text genuinely did not arrive". `wentBlind` is sticky on the observer
    /// once set (its credibility is shot for this insert), so it forces the
    /// anti-double-safe outcome even if this particular canary check reports
    /// observed==true.
    ///
    /// `lateChunksObserved` covers the delayed-not-dropped case: the WindowServer
    /// stall that made the unicode wait read 0 can release our chunks while the
    /// canary wait runs. Text that arrived late must never be re-typed.
    static func canaryVerdict(
        canaryObserved: Bool,
        wentBlind: Bool,
        isSecondAttempt: Bool,
        lateChunksObserved: Bool = false
    ) -> CanaryVerdict {
        guard canaryObserved, !wentBlind, !lateChunksObserved else {
            return .acceptUnverified
        }
        return isSecondAttempt ? .escalateToPaste : .retypeOnce
    }

    enum CanaryVerdict: Equatable {
        /// Pipe unprovable (canary unobserved, or the tap admitted going
        /// blind) — a silently-lost dictation beats duplicated text. Accept
        /// once, log, stop. No re-type, no paste.
        case acceptUnverified
        /// Pipe proven live and our text genuinely did not arrive — one
        /// re-type, then re-run the same evidence ladder on it.
        case retypeOnce
        /// Pipe proven live on the *second* check (post-retype) and text
        /// still didn't land — fall to the paste lane, whose chord
        /// confirmation is keycode-based and proven to work.
        case escalateToPaste
    }

    /// Whether to restore the pre-insert pasteboard snapshot after lane attempts finish.
    ///
    /// Paste success must not restore synchronously: confirmation only proves the
    /// Cmd-V chord fired and the transcript was still on the pasteboard — not that
    /// the target app already consumed it. Restoring after `pasteConsumerDelay`
    /// (0.25s) let Cursor paste the prior clipboard while History recorded the
    /// correct transcript as injected (2026-08-31).
    static func resolveSavedPasteboardRestore(
        pasteSucceeded: Bool,
        unicodeSucceeded: Bool,
        allLanesFailed: Bool
    ) -> SavedPasteboardRestoreDecision {
        if pasteSucceeded {
            return .restoreSavedDeferred
        }
        if unicodeSucceeded {
            return .restoreSaved
        }
        if allLanesFailed {
            return .doNotRestoreLeaveTranscript
        }
        return .deferRestore
    }

    /// Splits `text` into UTF-16 chunks sized for `keyboardSetUnicodeString`,
    /// never inside a grapheme cluster.
    static func chunkUTF16Units(_ text: String, maxChunkSize: Int = unicodeChunkSize) -> [[UInt16]] {
        var chunks: [[UInt16]] = []
        var current: [UInt16] = []
        // Grapheme boundaries only: a surrogate pair (emoji, ZWJ sequence)
        // split across two events posts two lone surrogates. A single
        // grapheme wider than the cap goes alone rather than being cut.
        for character in text {
            let units = Array(String(character).utf16)
            if !current.isEmpty, current.count + units.count > maxChunkSize {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// One captured pasteboard item: every representation type it carried,
    /// with its bytes. A whole pasteboard is an ordered list of these.
    typealias PasteboardSnapshot = [[NSPasteboard.PasteboardType: Data]]

    /// Baseline for an insert about to run: the original clipboard captured by a
    /// still-pending deferred restore, else the live pasteboard.
    static func pasteboardBaselineSnapshot(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        restoreGenerationLock.lock()
        let pending = pendingRestoreBaseline
        restoreGenerationLock.unlock()
        return pending ?? pasteboardSnapshot(from: pasteboard)
    }

    private static func clearPendingRestoreBaseline() {
        restoreGenerationLock.lock()
        pendingRestoreBaseline = nil
        restoreGenerationLock.unlock()
    }

    /// Captures every item and every representation currently on `pasteboard`.
    ///
    /// Reading only `.string` (as this used to) meant an ordinary dictation
    /// destroyed any image, file URL, RTF, or multi-flavor payload the user had
    /// copied: restore clears the pasteboard, and a plain-text-only snapshot has
    /// nothing to put back. The paste lane is the primary injection lane, so
    /// that ran on essentially every dictation.
    ///
    /// Lazily-promised data (file promises) cannot be captured this way —
    /// `data(forType:)` returns nil for an unresolved promise, so those types
    /// are dropped. Still strictly narrower than the previous behavior, which
    /// dropped everything except plain text.
    static func pasteboardSnapshot(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    representations[type] = data
                }
            }
            return representations.isEmpty ? nil : representations
        }
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

    /// Schedules a pasteboard restore after `delay`, re-checking that our
    /// transcript is still present (Continuity / user copy → skip). Newer
    /// schedules cancel older ones via `restoreGeneration`.
    ///
    /// `asyncAfter` is injectable for tests; production uses main-queue
    /// `asyncAfter`.
    static func scheduleDeferredPasteboardRestore(
        injectedText: String,
        savedPasteboard: PasteboardSnapshot,
        on pasteboard: NSPasteboard = .general,
        delay: TimeInterval = pasteboardRestoreDelay,
        asyncAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        restoreGenerationLock.lock()
        restoreGeneration &+= 1
        let generation = restoreGeneration
        pendingRestoreBaseline = savedPasteboard
        restoreGenerationLock.unlock()

        asyncAfter(delay) {
            restoreGenerationLock.lock()
            let current = restoreGeneration
            if generation == current {
                pendingRestoreBaseline = nil
            }
            restoreGenerationLock.unlock()
            guard generation == current else {
                log("skip deferred pasteboard restore — superseded")
                return
            }
            guard shouldRestoreSavedPasteboard(injectedText: injectedText, on: pasteboard) else {
                log("skip deferred pasteboard restore — external overwrite after paste")
                return
            }
            restorePasteboardSnapshot(savedPasteboard, on: pasteboard)
            log("deferred pasteboard restore chars=\(injectedText.utf16.count)")
        }
    }

    /// Test seam: reset generation so deferred-restore tests stay isolated.
    static func resetDeferredRestoreGenerationForTesting() {
        restoreGenerationLock.lock()
        restoreGeneration = 0
        pendingRestoreBaseline = nil
        restoreGenerationLock.unlock()
    }

    /// Restores a captured snapshot, rebuilding every item with all of its
    /// representations. An empty snapshot means the pasteboard was empty before
    /// we touched it, so it is left cleared.
    static func restorePasteboardSnapshot(_ snapshot: PasteboardSnapshot, on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let items: [NSPasteboardItem] = snapshot.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
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

    /// `insert` normally runs off-main. AppKit's frontmost-application state is
    /// sampled on main at the actual insertion boundary, after pipeline work.
    private static func frontmostBundleIdentifierAtInsert() -> String? {
        let sample = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        return Thread.isMainThread ? sample() : DispatchQueue.main.sync(execute: sample)
    }

    @discardableResult
    func insert(_ text: String) -> InsertResult {
        let trimmed = Self.trimmingTrailingWhitespaceAndNewlines(text)
        guard !trimmed.isEmpty,
              trimmed.contains(where: { !$0.isWhitespace && !$0.isNewline }) else { return .failed }

        if IsSecureEventInputEnabled() {
            Self.log("blocked secure-input chars=\(trimmed.count)")
            return .failed
        }

        // Never synchronously hop to main while holding the dedupe lock: a
        // main-thread insertion may already be waiting for that same lock.
        let bundleIdentifier = Self.deliveryLaneForTesting == nil
            ? Self.frontmostBundleIdentifierAtInsert() : nil
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
            return .deduped
        }

        let result: InsertResult
        if let deliveryLane = Self.deliveryLaneForTesting {
            result = deliveryLane(trimmed) ? .inserted(deliveredText: trimmed) : .failed
        } else {
            result = performInsert(
                trimmed,
                bundleIdentifier: bundleIdentifier
            )
        }

        if case .inserted = result {
            Self.lastDeliveredText = trimmed
            Self.lastDeliveredAt = Date()
        }

        return result
    }

    /// Terminal state of one `insertViaUnicodeTyping` attempt, folded down to
    /// what `performInsert` needs to branch on. `.confirmed` covers all three
    /// accept sub-verdicts of `unicodeLaneVerdict` (direct, keycode-evidence,
    /// partial) — each logs its own evidence, but all three stop the chain
    /// the same way.
    private enum UnicodeAttemptResult {
        case confirmed
        case needsCanaryProbe
        case postFailed
    }

    private func attemptUnicodeTyping(
        _ trimmed: String,
        observer: UnicodeDeliveryObserver,
        chunkTarget: Int,
        attemptLabel: String
    ) -> UnicodeAttemptResult {
        observer.resetObservedCount()
        let posted = insertViaUnicodeTyping(trimmed)
        guard posted > 0 else { return .postFailed }

        let observed = waitForConfirmation(observer: observer, target: posted, counter: .utf16Units)
        let keycodeZeroObserved = observer.keycodeZeroKeyDownCount
        switch Self.unicodeLaneVerdict(
            utf16Observed: observed,
            utf16Target: posted,
            keycodeZeroObserved: keycodeZeroObserved,
            chunkTarget: chunkTarget,
            wentBlind: observer.wentBlind
        ) {
        case .confirmed:
            Self.log("unicode transport observed\(attemptLabel) chars=\(trimmed.utf16.count) — target acceptance unverified, pasteboard untouched")
            return .confirmed
        case .confirmedByKeycode:
            Self.log("unicode transport observed by keycode (readback blind)\(attemptLabel) chunks=\(chunkTarget) — target acceptance unverified")
            return .confirmed
        case .acceptPartial:
            Self.log("partial unicode transport observed=\(observed)/\(posted)\(attemptLabel) — accepting without retry (anti-double)")
            return .confirmed
        case .needsCanaryProbe:
            return .needsCanaryProbe
        }
    }

    /// Posts the F20 canary, waits a flat window, and folds the result
    /// through `canaryVerdict`.
    ///
    /// Only the canary counter is cleared: the unicode counters must survive
    /// the wait so chunks delivered late (delayed, not dropped) are noticed.
    private func probeCanary(observer: UnicodeDeliveryObserver, isSecondAttempt: Bool) -> CanaryVerdict {
        observer.resetCanaryCount()
        _ = postCanary()
        let observedCanary = waitForConfirmation(
            observer: observer,
            target: 1,
            counter: .canary,
            baseWindow: Self.canaryConfirmationWindow,
            progressExtension: 0,
            maxWait: Self.canaryConfirmationWindow
        )
        let lateChunksObserved = observer.observedUTF16Units > 0
            || observer.keycodeZeroKeyDownCount > 0
        if lateChunksObserved {
            Self.log("unicode chunks arrived during canary wait — accepting unverified (anti-double)")
        }
        return Self.canaryVerdict(
            canaryObserved: observedCanary >= 1,
            wentBlind: observer.wentBlind,
            isSecondAttempt: isSecondAttempt,
            lateChunksObserved: lateChunksObserved
        )
    }

    private func performInsert(_ trimmed: String, bundleIdentifier: String?) -> InsertResult {
        let utf16Count = trimmed.utf16.count
        // Snapshot before any lane that may write the pasteboard. Unicode-first
        // never writes on success; paste fallback needs this to put the user's
        // prior copy back after Cmd-V.
        // While a prior deferred restore is pending the live pasteboard holds
        // that transcript, so the baseline is the original the restore owns.
        let savedPasteboard = Self.pasteboardBaselineSnapshot(from: NSPasteboard.general)

        guard let observer = UnicodeDeliveryObserver.create() else {
            // Paste-blind is unconfirmed — fail closed for watch / InsertResult.
            // Do not restore the pre-insert pasteboard: the pipeline maps this
            // to `.failed` and the HUD tells the user the transcript is on
            // the clipboard. A deferred restore would clobber that promise.
            _ = insertViaPasteBlind(trimmed)
            return .failed
        }
        defer { observer.stop() }

        let chunkTarget = Self.chunkUTF16Units(trimmed).count
        let lanes = Self.injectionLanes(
            bundleIdentifier: bundleIdentifier,
            chunkCount: chunkTarget
        )

        if lanes == [.pasteOnce] {
            let pasteSucceeded = tryPasteLane(trimmed, observer: observer, retryOnAmbiguous: false)
            if pasteSucceeded {
                Thread.sleep(forTimeInterval: Self.pasteConsumerDelay)
                Self.scheduleDeferredPasteboardRestore(
                    injectedText: trimmed,
                    savedPasteboard: savedPasteboard
                )
                Self.log("Safari atomic paste transport observed chars=\(utf16Count) — target acceptance unverified")
                return .inserted(deliveredText: trimmed)
            }

            // A missing observer count cannot distinguish a dropped chord from
            // a paste Safari already accepted. Never follow it with unicode or
            // another Cmd-V: either could duplicate or corrupt the field.
            leaveOnClipboard(trimmed)
            Self.log("Safari atomic paste ambiguous — no retry; transcript left on clipboard chars=\(utf16Count)")
            return .failed
        }

        var confirmed = false
        var retryConfirmed = false

        // Evidence ladder (2026-08-31): never escalate to a second delivery
        // attempt unless the observation channel is PROVEN live at that
        // moment AND it proves our text did not arrive. Anything unprovable
        // is accepted once and logged — a silently-lost dictation beats
        // duplicated text.
        switch attemptUnicodeTyping(trimmed, observer: observer, chunkTarget: chunkTarget, attemptLabel: "") {
        case .confirmed:
            confirmed = true
        case .postFailed:
            break // No CGEventSource — skip straight to the paste lane below.
        case .needsCanaryProbe:
            switch probeCanary(observer: observer, isSecondAttempt: false) {
            case .acceptUnverified:
                Self.log("observer blind — accepting unverified (anti-double)")
                confirmed = true
            case .retypeOnce:
                Self.log("delivery drop detected — retrying")
                switch attemptUnicodeTyping(trimmed, observer: observer, chunkTarget: chunkTarget, attemptLabel: " on retry") {
                case .confirmed:
                    retryConfirmed = true
                case .postFailed:
                    break
                case .needsCanaryProbe:
                    switch probeCanary(observer: observer, isSecondAttempt: true) {
                    case .acceptUnverified:
                        Self.log("observer blind — accepting unverified (anti-double)")
                        retryConfirmed = true
                    case .escalateToPaste, .retypeOnce:
                        break // Pipe proven live, text still missing — paste lane.
                    }
                }
            case .escalateToPaste:
                break // Defensive: canaryVerdict never returns this on a first check.
            }
        }

        let outcome = Self.resolveOutcome(confirmed: confirmed, retryConfirmed: retryConfirmed)
        if outcome.path.isConfirmedDelivery {
            return .inserted(deliveredText: trimmed)
        }

        // Paste fallback (Wispr-style). Touches the pasteboard; restore prior
        // after pasteboardRestoreDelay so Electron/Cursor can still consume.
        let pasteSucceeded = tryPasteLane(trimmed, observer: observer, retryOnAmbiguous: true)
        if pasteSucceeded {
            Thread.sleep(forTimeInterval: Self.pasteConsumerDelay)
            switch Self.resolveSavedPasteboardRestore(
                pasteSucceeded: true,
                unicodeSucceeded: false,
                allLanesFailed: false
            ) {
            case .restoreSavedDeferred:
                Self.scheduleDeferredPasteboardRestore(
                    injectedText: trimmed,
                    savedPasteboard: savedPasteboard
                )
            case .restoreSaved:
                if Self.shouldRestoreSavedPasteboard(injectedText: trimmed, on: NSPasteboard.general) {
                    Self.restorePasteboardSnapshot(savedPasteboard, on: NSPasteboard.general)
                } else {
                    Self.log("skip pasteboard restore — external overwrite after paste")
                }
            case .doNotRestoreLeaveTranscript:
                leaveOnClipboard(trimmed)
            case .deferRestore:
                break
            }
            Self.log("paste chord fallback chars=\(utf16Count)")
            return .inserted(deliveredText: trimmed)
        }

        // All lanes failed. Leave transcript for the HUD "paste it yourself"
        // flash — prior clipboard is sacrificed only here.
        leaveOnClipboard(trimmed)
        Self.log("inject failed — transcript left on clipboard chars=\(utf16Count)")
        return .failed
    }

    // MARK: - Paste lane

    /// Paste without delivery confirmation. Returns `false` when the chord was
    /// not posted (unstable pasteboard or event creation failure).
    ///
    /// Every path leaves the transcript on the clipboard rather than restoring
    /// the prior contents. `performInsert` maps this lane to `.failed`, which
    /// the pipeline surfaces as `.injectionFailed` → the HUD's clipboard flash
    /// ("your text is on the clipboard, paste it yourself"). Restoring — even
    /// after `pasteboardRestoreDelay` — made that promise false.
    @discardableResult
    private func insertViaPasteBlind(_ text: String) -> Bool {
        guard Self.preparePasteboardForPasteStable(text, on: NSPasteboard.general) else {
            Self.log("paste blind aborted — pasteboard unstable chars=\(text.utf16.count)")
            leaveOnClipboard(text)
            return false
        }
        guard Self.pasteboardHoldsExpectedString(text, on: NSPasteboard.general) else {
            Self.log("paste blind aborted — pasteboard mismatch before chord")
            leaveOnClipboard(text)
            return false
        }
        guard postPasteChord() else {
            Self.log("paste blind aborted — chord post failed chars=\(text.utf16.count)")
            leaveOnClipboard(text)
            return false
        }
        Thread.sleep(forTimeInterval: Self.pasteConsumerDelay)
        Self.log("paste blind chars=\(text.utf16.count) — transcript left on clipboard")
        return true
    }

    /// Returns true when a Cmd-V chord is observed *and* the pasteboard still
    /// holds our transcript. Chord-only confirmation previously let Universal
    /// Clipboard win the race and paste stale iPhone copy.
    private func tryPasteLane(
        _ text: String,
        observer: UnicodeDeliveryObserver,
        retryOnAmbiguous: Bool
    ) -> Bool {
        guard Self.preparePasteboardForPasteStable(text, on: NSPasteboard.general) else {
            Self.log("paste lane aborted — could not stabilize pasteboard")
            return false
        }

        func attempt() -> (landed: Bool, chordObserved: Bool) {
            if !Self.pasteboardHoldsExpectedString(text, on: NSPasteboard.general) {
                Self.log("pasteboard mismatch before chord — re-stabilizing")
                guard Self.preparePasteboardForPasteStable(text, on: NSPasteboard.general) else {
                    return (false, false)
                }
            }
            guard Self.pasteboardHoldsExpectedString(text, on: NSPasteboard.general) else {
                return (false, false)
            }

            observer.resetObservedCount()
            guard postPasteChord() else { return (false, false) }
            // Chord observation is binary (target 1) — a WindowServer stall
            // DELAYS the CGEvent reaching the observer tap, it does not drop
            // it. The original 0.4s window mistook "still in flight" for
            // "dropped", fired a second Cmd-V, and once the stall cleared both
            // chords landed — pasting the transcript twice while History
            // recorded one delivery (2026-08-31 double-paste incident). 1.5s
            // gives a stalled WindowServer room to deliver before we escalate
            // to the single retry below.
            let observedChordCount = waitForConfirmation(
                observer: observer,
                target: Self.pasteChordTarget,
                counter: .pasteChord,
                baseWindow: Self.pasteChordConfirmationWindow,
                progressExtension: 0,
                maxWait: Self.pasteChordConfirmationWindow
            )
            let chordObserved = observedChordCount >= Self.pasteChordTarget
            // Chord observed proves WindowServer accepted our events; pasteboard
            // still holding the transcript proves Continuity did not overwrite
            // between prepare and paste. Neither checks target-app content.
            let landed = chordObserved
                && Self.pasteboardHoldsExpectedString(text, on: NSPasteboard.general)
            return (landed, chordObserved)
        }

        let first = attempt()
        if first.landed {
            return true
        }

        guard Self.shouldRetryPaste(
            chordObserved: first.chordObserved,
            retryOnAmbiguous: retryOnAmbiguous
        ) else { return false }
        Self.log("paste delivery drop detected — retrying")
        return attempt().landed
    }

    /// A second Cmd-V is only safe when the first chord was never observed
    /// (dropped). An observed chord with the pasteboard overwritten afterwards
    /// means the target already pasted — retrying would paste twice.
    static func shouldRetryPaste(chordObserved: Bool, retryOnAmbiguous: Bool) -> Bool {
        retryOnAmbiguous && !chordObserved
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

    /// Posts an F20 keyDown+keyUp with no flags — a no-op in effectively
    /// every app. Proves the post→WindowServer→tap pipe is live without
    /// mutating the document, so a blind unicode observer can be
    /// distinguished from a genuinely dropped delivery (see `canaryVerdict`).
    @discardableResult
    private func postCanary() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            Self.log("no CGEventSource")
            return false
        }
        source.localEventsSuppressionInterval = 0

        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: Self.virtualKeyF20,
            keyDown: true
        ) else {
            Self.log("failed to create canary keyDown")
            return false
        }
        keyDown.post(tap: .cgSessionEventTap)

        guard let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: Self.virtualKeyF20,
            keyDown: false
        ) else {
            Self.log("failed to create canary keyUp")
            return false
        }
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

    private enum ConfirmationCounter {
        case utf16Units
        case pasteChord
        case canary
    }

    /// Waits for `observedCount()` to reach `target`, extending the deadline on
    /// forward progress (delayed delivery) rather than timing out the instant a
    /// fixed window elapses (see `confirmationBaseWindow` doc comment). Returns
    /// the final observed count — callers decide confirmed / retry / partial via
    /// `unicodeLaneVerdict`, not a bare Bool, so a delayed-but-partial delivery is
    /// distinguishable from a genuine drop.
    private func waitForConfirmation(
        observer: UnicodeDeliveryObserver,
        target: Int,
        counter: ConfirmationCounter,
        baseWindow: TimeInterval = TextInjector.confirmationBaseWindow,
        progressExtension: TimeInterval = TextInjector.confirmationProgressExtension,
        maxWait: TimeInterval = TextInjector.confirmationMaxWait
    ) -> Int {
        let observedCount: () -> Int = {
            switch counter {
            case .utf16Units:
                return observer.observedUTF16Units
            case .pasteChord:
                return observer.observedPasteChordCount
            case .canary:
                return observer.canaryObservedCount
            }
        }
        // Keycode-zero counting (virtualKey 0, what our unicode chunks use)
        // keeps working even when payload readback goes blind (2026-08-31
        // evidence), so it counts as forward progress for the unicode-units
        // wait too — a stutter that stalls payload readback but not keycode
        // delivery still earns the wait more time instead of reading as a
        // drop the instant the base window elapses.
        let progressCount: () -> Int = {
            switch counter {
            case .utf16Units:
                return observer.observedUTF16Units + observer.keycodeZeroKeyDownCount
            case .pasteChord, .canary:
                return observedCount()
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        var finalObserved = 0
        DispatchQueue(label: "com.matt.voice-dictation.unicode-delivery-wait").async {
            let startedAt = Date()
            var deadline = startedAt.addingTimeInterval(baseWindow)
            var lastObserved = progressCount()
            while Date() < deadline {
                let current = progressCount()
                if current > lastObserved {
                    deadline = Self.nextConfirmationDeadline(
                        startedAt: startedAt,
                        currentDeadline: deadline,
                        progressExtension: progressExtension,
                        maxWait: maxWait
                    )
                    lastObserved = current
                }
                if observedCount() >= target {
                    break
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
            finalObserved = observedCount()
            semaphore.signal()
        }
        semaphore.wait()
        return finalObserved
    }

    private func leaveOnClipboard(_ text: String) {
        Self.leaveTranscriptOnClipboard(text)
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
    private var keycodeZeroKeyDownCountStorage = 0
    private var canaryObservedCountStorage = 0
    /// Sticky once set — never cleared by `resetObservedCount`. Once the tap
    /// has reported itself disabled during this insert, its testimony is no
    /// longer trustworthy for the remainder of that insert, even after it is
    /// re-enabled and starts reporting counts again.
    private var wentBlindStorage = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var workerRunLoop: CFRunLoop?
    private var thread: Thread?
    private let readySemaphore = DispatchSemaphore(value: 0)
    private let finishedSemaphore = DispatchSemaphore(value: 0)
    private(set) var isReady = false
    private let processID = Int64(getpid())
    private static let pasteVirtualKey = Int64(9) // kVK_ANSI_V
    private static let canaryVirtualKey = Int64(90) // kVK_F20

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

    /// Own-PID keyDowns with `keyboardEventKeycode == 0` — the virtualKey our
    /// unicode chunks post. This counts independently of the unicode payload
    /// readback (`keyboardGetUnicodeString`), so it keeps working when that
    /// readback goes blind — the 2026-08-31 evidence for this whole ladder.
    var keycodeZeroKeyDownCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return keycodeZeroKeyDownCountStorage
    }

    /// Own-PID keyDowns matching the F20 canary.
    var canaryObservedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return canaryObservedCountStorage
    }

    /// Whether the tap has ever reported `tapDisabledByTimeout` or
    /// `tapDisabledByUserInput` during this observer's lifetime. Sticky.
    var wentBlind: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wentBlindStorage
    }

    /// Clears the per-attempt counters so a fresh attempt starts from zero.
    /// `wentBlind` is intentionally excluded — see its doc comment.
    func resetObservedCount() {
        lock.lock()
        observedUTF16UnitsStorage = 0
        observedPasteChordCountStorage = 0
        keycodeZeroKeyDownCountStorage = 0
        canaryObservedCountStorage = 0
        lock.unlock()
    }

    func resetCanaryCount() {
        lock.lock()
        canaryObservedCountStorage = 0
        lock.unlock()
    }

    private func markWentBlind() {
        lock.lock()
        wentBlindStorage = true
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
        // Must come before the keyDown check: a stalled tap delivers this
        // event type instead of keyDowns, and every escalation lane below
        // trusts "observed==0" as "not delivered" unless it knows the
        // witness itself blacked out (2026-08-31 evidence).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            observer.markWentBlind()
            if let tap = observer.tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
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

        if keycode == Self.canaryVirtualKey {
            lock.lock()
            canaryObservedCountStorage += 1
            lock.unlock()
            return
        }

        // Our unicode chunks always post with virtualKey 0. Count this
        // regardless of whether the payload readback below succeeds — this
        // is the counter that keeps working when that readback goes blind.
        if keycode == 0 {
            lock.lock()
            keycodeZeroKeyDownCountStorage += 1
            lock.unlock()
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
