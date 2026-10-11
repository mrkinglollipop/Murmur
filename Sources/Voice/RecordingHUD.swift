import AppKit
import QuartzCore
import SwiftUI

// MARK: - RecordingHUD

/// A small, subtle floating pill shown while push-to-talk recording is
/// active — a borderless, non-activating panel with an audio-reactive
/// waveform, so the user has visual confirmation the mic is live without
/// stealing focus from whatever app they're dictating into.
///
/// States:
///   .listening  — audio-reactive bars driven by mic level (pushLevel(_:))
///   .processing — transcription running; bars collapse into a gentle
///                 indeterminate pulse until hide() is called
///   .success    — brief checkmark flash before hide
///   .clipboardFlash — brief clipboard icon when text landed on clipboard
///   .microphoneNoAudio — nonblocking in-hold hint; recording continues
///   .error      — red-tinted pill with a short failure message; auto-hides
///                 after 3s (see `showError(_:)`)

struct HUDTransitionToken: Equatable {
    private(set) var generation: Int = 0

    mutating func advance() -> Int {
        generation += 1
        return generation
    }

    func isCurrent(_ capturedGeneration: Int) -> Bool {
        capturedGeneration == generation
    }
}

final class RecordingHUD {

    private(set) var holdToken: UInt64?

    /// Ownership changes invalidate flash timers and fade completions from
    /// the preceding hold before presenting the new hold's state.
    func claimHold(_ token: UInt64?) {
        holdToken = token
        _ = beginTransition()
    }

    func ownsHold(_ token: UInt64?) -> Bool {
        Self.holdOwnsPresentation(token: token, owner: holdToken)
    }

    static func holdOwnsPresentation(token: UInt64?, owner: UInt64?) -> Bool {
        token == owner
    }

    enum PipelineCompletionAction { case success, hide, none }

    static func pipelineCompletionAction(
        result: TranscriptionPipeline.InjectPipelineResult,
        token: UInt64?, owner: UInt64?, isProcessing: Bool
    ) -> PipelineCompletionAction {
        guard holdOwnsPresentation(token: token, owner: owner) else { return .none }
        switch result {
        case .inserted: return .success
        case .savedToHistory, .deduped, .failed: return isProcessing ? .hide : .none
        }
    }

    enum State: Equatable {
        case listening
        case editingSelection
        case processing
        case success
        case clipboardFlash
        case microphoneNoAudio(String)
        case error(String)

        var accessibilityAnnouncement: String {
            switch self {
            case .listening: return "Listening"
            case .editingSelection: return "Editing selection"
            case .processing: return "Transcribing"
            case .success: return "Dictation complete"
            case .clipboardFlash: return "Text copied to clipboard"
            case .microphoneNoAudio(let device): return "No microphone audio from \(device)"
            case .error(let message): return "Dictation failed. \(message)"
            }
        }

        var visibleLabel: String? {
            if case .editingSelection = self { return "Editing selection" }
            return nil
        }
    }

    /// Invoked on every state transition — wired by AppDelegate for menu-bar icon sync.
    var onStateChange: ((State) -> Void)?

    /// Invoked when the HUD fully hides — the only reliable "back to idle"
    /// signal, since `hide()` is reachable from every terminal path (silence,
    /// early failures, and after a `.success`/`.clipboardFlash`/`.error`
    /// flash) without necessarily passing through `applyState`.
    var onHide: (() -> Void)?

    /// Fires on show / resize / hide **after** `isVisible` reflects the new
    /// state. AppDelegate uses this to re-stack LearnToastHUD. Chain with
    /// `onHide` by calling this before `onHide` on hide (see `hide()`).
    var onLayoutChange: (() -> Void)?

    private(set) var currentState: State = .listening

    /// Whether the HUD is in the post-release transcription phase.
    var isProcessing: Bool {
        if case .processing = currentState { return true }
        return false
    }

    private let panel: NSPanel
    private let waveformView: WaveformView

    private let pillWidth: CGFloat = 260
    private let pillListeningHeight: CGFloat = 40
    private let pillInterimExtraHeight: CGFloat = 50

    /// Whether the recording HUD panel is currently shown.
    private(set) var isVisible = false

    /// Panel frame for stacking LearnToastHUD above the waveform.
    /// When visible, uses the resting origin (not a mid-entrance offset) so
    /// toasts sit at the final pill position for the whole recording.
    var frameForStacking: NSRect {
        guard isVisible else { return panel.frame }
        return NSRect(origin: mainScreenOrigin(), size: currentPillSize)
    }

    /// Y of the resting / `mainScreenOrigin` position (not the in-animation
    /// offset used during entrance).
    var restingOriginY: CGFloat { mainScreenOrigin().y }

    private var pendingHideTimer: Timer?
    private var transitionToken = HUDTransitionToken()
    private var pendingCorrectionCount: Int = 0
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var accessibilityObserver: NSObjectProtocol?
    private var isHiding = false
    private var shouldShowEditingSelection = false
    private var recordingIsVoiceEdit = false

    /// Short label for the push-to-talk key chip (e.g. "fn", "⌥").
    private(set) var activationKeyLabel: String = "fn"

    init() {
        let content = WaveformView(frame: NSRect(origin: .zero, size: NSSize(width: pillWidth, height: pillListeningHeight)))
        self.waveformView = content

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: pillWidth, height: pillListeningHeight)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        panel.contentView = content

        self.panel = panel

        waveformView.onErrorDismiss = { [weak self] in
            self?.hide()
        }
        waveformView.setReduceMotion(reduceMotion)
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshMotionPreference()
        }
    }

    deinit {
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
        pendingHideTimer?.invalidate()
    }

    private func refreshMotionPreference() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        waveformView.setReduceMotion(reduceMotion)
        if reduceMotion, isHiding {
            finishHide(generation: transitionToken.generation)
        } else if isVisible {
            if reduceMotion {
                panel.setFrameOrigin(mainScreenOrigin())
                panel.alphaValue = 1
            }
            waveformView.startAnimating()
            notifyLayoutChange()
        }
    }

    /// Updates the key-chip label to match the configured activation key.
    func setActivationKeyLabel(_ label: String) {
        activationKeyLabel = label
        waveformView.setActivationKeyLabel(label)
    }

    /// Shows the HUD in `.listening` state, centered horizontally, ~30pt
    /// above the main screen's visible-frame bottom. Fades + slides in.
    /// Safe to call repeatedly (e.g. re-show for a new recording).
    func show() {
        _ = beginTransition()
        clearInterimText()
        let initialState: State = shouldShowEditingSelection ? .editingSelection : .listening
        shouldShowEditingSelection = false
        applyState(initialState)
        resizePanel(forInterim: false)
        positionOnMainScreen(offsetBelowFinal: 8)
        panel.orderFrontRegardless()
        isVisible = true
        notifyLayoutChange()
        waveformView.startAnimating()

        let finalOrigin = mainScreenOrigin()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0 : 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(finalOrigin)
        }, completionHandler: { [weak self] in
            guard let self, self.isVisible else { return }
            self.notifyLayoutChange()
        })
    }

    /// Sets the next recording HUD appearance from the captured hold intent.
    /// Every hold calls this so a failed preflight cannot label the next normal
    /// recording as an edit.
    func prepareForRecording(editingSelection: Bool) {
        shouldShowEditingSelection = editingSelection
        recordingIsVoiceEdit = editingSelection
    }

    /// Switches to `.processing` state (indeterminate pulse) without
    /// hiding the pill — used while transcription is in flight.
    func setProcessing() {
        guard isVisible else { return }
        _ = beginTransition()
        clearInterimText()
        applyState(.processing)
        waveformView.setProcessingLabel(true)
        resizePanel(forInterim: true)
        positionOnMainScreen(offsetBelowFinal: 8)
        notifyLayoutChange()
    }

    /// Shows the last 1–2 lines of live transcript preview below the waveform
    /// bars while in `.listening` state. Safe to call from background threads.
    func showInterimText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, self.currentState == .listening else { return }
            let hasInterim = !trimmed.isEmpty
            self.waveformView.setInterimText(hasInterim ? trimmed : nil)
            self.resizePanel(forInterim: hasInterim)
            self.positionOnMainScreen(offsetBelowFinal: 8)
            self.notifyLayoutChange()
        }
    }

    /// Clears any live transcript preview beneath the waveform bars.
    func clearInterimText() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.waveformView.setInterimText(nil)
            if self.currentState != .processing {
                self.resizePanel(forInterim: false)
            }
        }
    }

    /// Feeds a fresh mic amplitude sample (0...1) into the waveform while
    /// in `.listening` state. Safe to call at high frequency from the
    /// audio tap's thread-safe accessor — hop to main is handled internally
    /// by the waveform's own display timer, so this just records the value.
    func pushLevel(_ level: Float) {
        waveformView.pushLevel(level)
    }

    /// Contextual warning for a live hold. This deliberately does not use the
    /// terminal error pill: the user may simply be pausing before speaking.
    func showMicrophoneNoAudio(_ deviceName: String) {
        guard isVisible, !isProcessing else { return }
        if case .microphoneNoAudio(let currentDeviceName) = currentState,
           currentDeviceName == deviceName {
            return
        }
        applyState(.microphoneNoAudio(deviceName))
        resizePanel(forInterim: true)
        positionOnMainScreen(offsetBelowFinal: 8)
        notifyLayoutChange()
    }

    /// The first real RMS sample clears the in-hold hint without interrupting
    /// the waveform or changing focus.
    func clearMicrophoneNoAudio() {
        guard case .microphoneNoAudio = currentState else { return }
        applyState(recordingIsVoiceEdit ? .editingSelection : .listening)
        resizePanel(forInterim: false)
        positionOnMainScreen(offsetBelowFinal: 8)
        notifyLayoutChange()
    }

    /// Shows a red-tinted error pill with `message`, then auto-hides after 3s.
    func showError(_ message: String) {
        let generation = beginTransition()

        applyState(.error(message))
        panel.ignoresMouseEvents = false
        positionOnMainScreen(offsetBelowFinal: 8)
        panel.orderFrontRegardless()
        isVisible = true
        notifyLayoutChange()
        waveformView.startAnimating()

        let finalOrigin = mainScreenOrigin()
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0 : 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(finalOrigin)
        }, completionHandler: { [weak self] in
            guard let self, self.isVisible, self.transitionToken.isCurrent(generation) else { return }
            self.notifyLayoutChange()
        })

        scheduleAutoHide(after: 3.0, generation: generation)
    }

    /// Flashes a success checkmark briefly, then runs the normal hide animation.
    func setPendingCorrectionCount(_ count: Int) {
        pendingCorrectionCount = count
    }

    func showSuccessThenHide(correctionCount: Int = 0) {
        let generation = beginTransition()
        let count = correctionCount > 0 ? correctionCount : pendingCorrectionCount
        pendingCorrectionCount = 0
        guard isVisible else {
            hide()
            return
        }
        waveformView.setCorrectionCount(count)
        applyState(.success)
        collapseToCompactPill()
        waveformView.startAnimating()
        // Plain success is a quick flash; a fix count is information the
        // user should actually get to read before the pill fades.
        scheduleAutoHide(after: count > 0 ? 2.0 : 0.6, generation: generation)
    }

    /// Flashes a clipboard icon briefly, then runs the normal hide animation.
    func showClipboardFlashThenHide() {
        let generation = beginTransition()
        guard isVisible else {
            hide()
            return
        }
        applyState(.clipboardFlash)
        collapseToCompactPill()
        waveformView.startAnimating()
        // "Left on clipboard" means the text did NOT inject — give the cue
        // enough screen time to register before fading.
        scheduleAutoHide(after: 1.5, generation: generation)
    }

    /// Animates the expanded (interim/processing) pill down to the compact
    /// flash pill so terminal states contract deliberately instead of
    /// snapping during the fade-out.
    private func collapseToCompactPill() {
        waveformView.setInterimText(nil)
        waveformView.setProcessingLabel(false)
        resizePanel(forInterim: false, animatedShrink: true)
    }

    /// Fades out and hides the HUD, stopping all animation. Mirrors the
    /// entrance: fade plus a small downward slide; content cleanup happens
    /// after the panel is offscreen so nothing visibly snaps mid-fade.
    func hide() {
        let generation = beginTransition()
        panel.ignoresMouseEvents = true
        guard isVisible else {
            waveformView.setInterimText(nil)
            waveformView.setProcessingLabel(false)
            // Still notify layout so stacked toasts can drop to resting Y.
            notifyLayoutChange()
            onHide?()
            return
        }
        AccessibilityAnnouncement.post("Dictation stopped", element: panel)
        // Menu-bar idle immediately. Keep `isVisible` true through the fade so
        // LearnToastHUD does not snap to resting Y while the pill is still on
        // screen; clear visibility + re-stack after the animation completes.
        onHide?()
        var slidDown = panel.frame.origin
        isHiding = true
        slidDown.y -= reduceMotion ? 0 : 8
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0 : 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrameOrigin(slidDown)
        }, completionHandler: { [weak self] in
            self?.finishHide(generation: generation)
        })
    }

    private func finishHide(generation: Int) {
        guard transitionToken.isCurrent(generation), isVisible else { return }
        isVisible = false
        isHiding = false
        waveformView.stopAnimating()
        panel.orderOut(nil)
        waveformView.setInterimText(nil)
        waveformView.setProcessingLabel(false)
        resizePanel(forInterim: false)
        notifyLayoutChange()
    }

    @discardableResult
    private func beginTransition() -> Int {
        isHiding = false
        pendingHideTimer?.invalidate()
        pendingHideTimer = nil
        return transitionToken.advance()
    }

    private func scheduleAutoHide(after interval: TimeInterval, generation: Int) {
        pendingHideTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self, self.transitionToken.isCurrent(generation) else { return }
            self.hide()
        }
    }

    private func applyState(_ newState: State) {
        if currentState != newState || !isVisible {
            AccessibilityAnnouncement.post(newState.accessibilityAnnouncement, element: panel)
        }
        currentState = newState
        waveformView.setState(newState)
        // Click-through everywhere except .error (see showError/H7) — reset
        // here too, not just in hide(), so a new recording starting while an
        // old error pill is still up (state jumps straight to .listening
        // without an intervening hide()) doesn't leave the panel eating clicks.
        if case .error = newState {} else {
            panel.ignoresMouseEvents = true
        }
        onStateChange?(newState)
    }

    private var currentPillSize: NSSize {
        NSSize(width: pillWidth, height: waveformView.hasInterimText || waveformView.hasProcessingLabel || waveformView.hasEditingSelectionLabel || waveformView.hasMicrophoneWarning ? pillListeningHeight + pillInterimExtraHeight : pillListeningHeight)
    }

    private func resizePanel(forInterim: Bool, animatedShrink: Bool = false) {
        let expanded = forInterim || waveformView.hasProcessingLabel || waveformView.hasEditingSelectionLabel || waveformView.hasMicrophoneWarning
        let targetHeight = expanded ? pillListeningHeight + pillInterimExtraHeight : pillListeningHeight
        if panel.frame.height == targetHeight { return }
        var frame = panel.frame
        // Keep origin.y fixed: AppKit origin is bottom-left, so a constant
        // origin pins the pill's bottom edge above the Dock and grows the
        // pill upward. Shifting origin by the delta pushed it into the Dock.
        frame.size.height = targetHeight
        // Growth always animates. Shrink snaps during interim churn (overlapping
        // shrink animations stack up) but animates for terminal flash states.
        if !reduceMotion && (targetHeight > panel.frame.height || animatedShrink) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = reduceMotion ? 0 : 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        waveformView.frame = NSRect(origin: .zero, size: NSSize(width: pillWidth, height: targetHeight))
        if isVisible {
            notifyLayoutChange()
        }
    }

    private func notifyLayoutChange() {
        onLayoutChange?()
    }

    private func mainScreenOrigin() -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return .zero }
        let visible = screen.visibleFrame
        let size = currentPillSize
        let x = visible.midX - size.width / 2
        let y = visible.minY + 30
        return NSPoint(x: x, y: y)
    }

    private func positionOnMainScreen(offsetBelowFinal: CGFloat) {
        let final = mainScreenOrigin()
        panel.setFrameOrigin(NSPoint(x: final.x, y: final.y - (reduceMotion ? 0 : offsetBelowFinal)))
    }
}

// MARK: - WaveformView

/// Dark rounded-capsule content view: a row of thin audio-reactive white
/// bars plus a small activation-key chip, drawn manually (no gradients, minimal
/// aesthetic). Matches the approved Wispr-style pill mockup.
private final class WaveformView: NSView {

    private let barCount = 6
    private let barLayers: [CALayer]
    private let fnChipBackground: CALayer
    private let fnLabel: NSTextField
    private let errorLabel: NSTextField
    private let successIcon: NSImageView
    private let correctionLabel: NSTextField
    private let clipboardIcon: NSImageView
    private let interimLabel: NSTextField

    private(set) var hasInterimText = false
    private(set) var hasProcessingLabel = false
    private(set) var hasEditingSelectionLabel = false
    private(set) var hasMicrophoneWarning = false
    private(set) var correctionCount: Int = 0

    var onErrorDismiss: (() -> Void)?

    private var reduceMotion = false
    private var displayTimer: Timer?
    private var state: RecordingHUD.State = .listening

    // MARK: Level ring buffer (audio-reactive bars)

    /// Thread-safe published level, written from AudioRecorder's mic-tap
    /// thread via `pushLevel`, read from the main-thread display timer.
    private let levelLock = NSLock()
    private var latestLevel: Float = 0

    /// Rolling history of recent smoothed levels — newest at the end.
    /// Mapped onto the 6 bars each tick for a scrolling VU look.
    private var levelHistory: [CGFloat] = Array(repeating: 0, count: 6)

    /// Current displayed bar heights, eased toward target each tick for
    /// attack/decay smoothing (fast attack, slower decay).
    private var displayedHeights: [CGFloat]

    /// Fallback canned-pulse phase, used only if no real level has arrived
    /// recently — keeps the HUD from ever looking frozen.
    private var noLevelTicks = 0
    private var pulsePhase: CGFloat = 0

    private let restingHeight: CGFloat = 5
    private let maxHeight: CGFloat = 18

    override init(frame frameRect: NSRect) {
        var layers: [CALayer] = []
        for _ in 0 ..< 6 {
            let layer = CALayer()
            layer.backgroundColor = NSColor.white.cgColor
            layer.cornerRadius = 2.0
            layers.append(layer)
        }
        self.barLayers = layers
        self.displayedHeights = Array(repeating: 5, count: 6)

        let chipBg = CALayer()
        chipBg.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        chipBg.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        chipBg.borderWidth = 1
        chipBg.cornerRadius = 4
        self.fnChipBackground = chipBg

        let label = NSTextField(labelWithString: "fn")
        label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        label.textColor = NSColor(calibratedRed: 0.604, green: 0.639, blue: 0.698, alpha: 1.0) // #9aa3b2
        label.alignment = .center
        self.fnLabel = label

        let error = NSTextField(labelWithString: "")
        error.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        error.textColor = NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.72, alpha: 1.0)
        error.alignment = .center
        error.isHidden = true
        self.errorLabel = error

        let success = NSImageView()
        success.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Success")
        success.contentTintColor = NSColor(calibratedRed: 0.114, green: 0.620, blue: 0.459, alpha: 1.0)
        success.imageScaling = .scaleProportionallyUpOrDown
        success.isHidden = true
        success.wantsLayer = true
        self.successIcon = success

        let correction = NSTextField(labelWithString: "")
        correction.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        correction.textColor = NSColor(calibratedRed: 0.75, green: 0.78, blue: 0.84, alpha: 1.0)
        correction.alignment = .center
        correction.isHidden = true
        self.correctionLabel = correction

        let clipboard = NSImageView()
        clipboard.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Copied to clipboard")
        clipboard.contentTintColor = NSColor(calibratedRed: 0.949, green: 0.722, blue: 0.502, alpha: 1.0)
        clipboard.imageScaling = .scaleProportionallyUpOrDown
        clipboard.isHidden = true
        clipboard.wantsLayer = true
        self.clipboardIcon = clipboard

        let interim = NSTextField(labelWithString: "")
        interim.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        interim.textColor = NSColor(calibratedRed: 0.75, green: 0.78, blue: 0.84, alpha: 1.0)
        interim.alignment = .center
        interim.lineBreakMode = .byTruncatingTail
        interim.maximumNumberOfLines = 3
        interim.isHidden = true
        self.interimLabel = interim

        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.086, alpha: 0.98).cgColor // ~#161616 @ 0.98
        layer?.cornerRadius = frameRect.height / 2
        layer?.masksToBounds = false
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 1

        // Drop shadow — soft, y -2, blur ~16, black ~0.35.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        for barLayer in barLayers {
            layer?.addSublayer(barLayer)
        }
        layer?.addSublayer(chipBg)
        addSubview(fnLabel)
        addSubview(errorLabel)
        addSubview(successIcon)
        addSubview(correctionLabel)
        addSubview(clipboardIcon)
        addSubview(interimLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        if case .error = state {
            onErrorDismiss?()
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(reduceMotion)
        defer { CATransaction.commit() }

        let chipWidth: CGFloat = 26
        let chipHeight: CGFloat = 18
        let horizontalPadding: CGFloat = 18
        let gapBetweenBarsAndChip: CGFloat = 8
        let barWidth: CGFloat = 3
        let barGap: CGFloat = 3
        let barsContainerWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap

        let waveformBandHeight: CGFloat = 40
        let bandOriginY = bounds.height - waveformBandHeight
        let midY = bandOriginY + waveformBandHeight / 2
        let barsStartX = horizontalPadding

        for (index, barLayer) in barLayers.enumerated() {
            let x = barsStartX + CGFloat(index) * (barWidth + barGap)
            let height = displayedHeights[index]
            barLayer.frame = CGRect(x: x, y: midY - height / 2, width: barWidth, height: height)
        }

        let chipX = bounds.width - horizontalPadding - chipWidth
        fnChipBackground.frame = CGRect(x: chipX, y: midY - chipHeight / 2, width: chipWidth, height: chipHeight)
        fnLabel.frame = CGRect(x: chipX, y: midY - 7, width: chipWidth, height: 14)
        errorLabel.frame = bounds.insetBy(dx: 16, dy: 0)
        if correctionCount > 0 {
            let iconSize: CGFloat = 20
            let gap: CGFloat = 6
            let labelWidth: CGFloat = 90
            let groupWidth = iconSize + gap + labelWidth
            let groupX = bounds.midX - groupWidth / 2
            successIcon.frame = CGRect(x: groupX, y: midY - iconSize / 2, width: iconSize, height: iconSize)
            correctionLabel.frame = CGRect(x: groupX + iconSize + gap, y: midY - 8, width: labelWidth, height: 16)
        } else {
            successIcon.frame = CGRect(x: bounds.midX - 12, y: midY - 12, width: 24, height: 24)
            correctionLabel.isHidden = true
        }
        clipboardIcon.frame = CGRect(x: bounds.midX - 12, y: midY - 12, width: 24, height: 24)

        if hasInterimText || hasProcessingLabel || hasEditingSelectionLabel || hasMicrophoneWarning {
            interimLabel.isHidden = false
            interimLabel.frame = CGRect(x: 12, y: 4, width: bounds.width - 24, height: bounds.height - waveformBandHeight - 4)
        } else {
            interimLabel.isHidden = true
        }

        // Sanity: bars area should end before the chip, honoring the gap.
        _ = barsStartX + barsContainerWidth + gapBetweenBarsAndChip
    }

    // MARK: - State

    func setState(_ newState: RecordingHUD.State) {
        let previous = state
        state = newState

        if case .processing = previous, !isProcessingState(newState) {
            setProcessingLabel(false)
        }
        if case .editingSelection = previous, newState != .editingSelection {
            hasEditingSelectionLabel = false
        }

        switch newState {
        case .processing:
            hasMicrophoneWarning = false
            pulsePhase = 0
            errorLabel.isHidden = true
            successIcon.isHidden = true
            clipboardIcon.isHidden = true
            fnChipBackground.isHidden = true
            fnLabel.isHidden = true
            for barLayer in barLayers { barLayer.isHidden = false }
            layer?.backgroundColor = NSColor(calibratedWhite: 0.086, alpha: 0.98).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        case .success:
            hasMicrophoneWarning = false
            errorLabel.isHidden = true
            successIcon.isHidden = false
            clipboardIcon.isHidden = true
            fnChipBackground.isHidden = true
            fnLabel.isHidden = true
            for barLayer in barLayers { barLayer.isHidden = true }
            interimLabel.isHidden = true
            if correctionCount > 0 {
                correctionLabel.stringValue = "\(correctionCount) corrected"
                correctionLabel.isHidden = false
            } else {
                correctionLabel.isHidden = true
            }
            layer?.backgroundColor = NSColor(calibratedWhite: 0.086, alpha: 0.98).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
            animateFlashIcon(successIcon)
        case .clipboardFlash:
            hasMicrophoneWarning = false
            errorLabel.isHidden = true
            successIcon.isHidden = true
            clipboardIcon.isHidden = false
            fnChipBackground.isHidden = true
            fnLabel.isHidden = true
            for barLayer in barLayers { barLayer.isHidden = true }
            interimLabel.isHidden = true
            layer?.backgroundColor = NSColor(calibratedWhite: 0.086, alpha: 0.98).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
            animateFlashIcon(clipboardIcon)
        case .microphoneNoAudio(let deviceName):
            hasMicrophoneWarning = true
            errorLabel.isHidden = true
            successIcon.isHidden = true
            clipboardIcon.isHidden = true
            fnChipBackground.isHidden = false
            fnLabel.isHidden = false
            for barLayer in barLayers { barLayer.isHidden = false }
            interimLabel.stringValue = "No microphone audio · \(deviceName)"
            interimLabel.isHidden = false
            layer?.backgroundColor = NSColor(calibratedWhite: 0.086, alpha: 0.98).cgColor
            layer?.borderColor = NSColor(Theme.amberBorder).withAlphaComponent(0.65).cgColor
        case .error(let message):
            hasMicrophoneWarning = false
            errorLabel.stringValue = message
            errorLabel.isHidden = false
            successIcon.isHidden = true
            clipboardIcon.isHidden = true
            fnChipBackground.isHidden = true
            fnLabel.isHidden = true
            for barLayer in barLayers { barLayer.isHidden = true }
            interimLabel.isHidden = true
            layer?.backgroundColor = NSColor(calibratedRed: 0.22, green: 0.08, blue: 0.08, alpha: 0.98).cgColor
            layer?.borderColor = NSColor(calibratedRed: 0.85, green: 0.25, blue: 0.25, alpha: 0.55).cgColor
        case .editingSelection:
            hasMicrophoneWarning = false
            errorLabel.isHidden = true
            successIcon.isHidden = true
            clipboardIcon.isHidden = true
            fnChipBackground.isHidden = false
            fnLabel.isHidden = false
            for barLayer in barLayers { barLayer.isHidden = false }
            hasEditingSelectionLabel = true
            interimLabel.stringValue = newState.visibleLabel ?? ""
            interimLabel.isHidden = false
            layer?.backgroundColor = NSColor(calibratedWhite: 0.086, alpha: 0.98).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        case .listening:
            hasMicrophoneWarning = false
            errorLabel.isHidden = true
            successIcon.isHidden = true
            clipboardIcon.isHidden = true
            fnChipBackground.isHidden = false
            fnLabel.isHidden = false
            for barLayer in barLayers { barLayer.isHidden = false }
            hasEditingSelectionLabel = false
            interimLabel.isHidden = !hasInterimText && !hasProcessingLabel
            layer?.backgroundColor = NSColor(calibratedWhite: 0.086, alpha: 0.98).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        }
    }

    func setProcessingLabel(_ show: Bool) {
        hasProcessingLabel = show
        if show {
            interimLabel.stringValue = "Transcribing…"
            interimLabel.isHidden = false
        } else if !hasInterimText {
            interimLabel.stringValue = ""
            interimLabel.isHidden = true
        }
        needsLayout = true
    }

    func setInterimText(_ text: String?) {
        if let text, !text.isEmpty {
            hasInterimText = true
            interimLabel.stringValue = lastLines(of: text, maxLines: 2)
            interimLabel.isHidden = state != .listening
        } else {
            hasInterimText = false
            if hasEditingSelectionLabel {
                interimLabel.stringValue = RecordingHUD.State.editingSelection.visibleLabel ?? ""
                interimLabel.isHidden = false
            } else if !hasProcessingLabel {
                interimLabel.stringValue = ""
                interimLabel.isHidden = true
            }
        }
        needsLayout = true
    }

    /// Returns the last `maxLines` lines of `text` for the compact HUD preview.
    private func lastLines(of text: String, maxLines: Int) -> String {
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        if lines.count <= maxLines { return lines.joined(separator: "\n") }
        return "…\n" + lines.suffix(maxLines).joined(separator: "\n")
    }

    func setActivationKeyLabel(_ label: String) {
        fnLabel.stringValue = label
        needsLayout = true
    }

    func setCorrectionCount(_ count: Int) {
        correctionCount = count
        needsLayout = true
    }

    private func isProcessingState(_ state: RecordingHUD.State) -> Bool {
        if case .processing = state { return true }
        return false
    }

    private func animateFlashIcon(_ icon: NSImageView) {
        icon.layer?.removeAnimation(forKey: "flashScale")
        if reduceMotion {
            icon.layer?.setAffineTransform(.identity)
            return
        }
        icon.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.6, y: 0.6))
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.6
        spring.toValue = 1.0
        spring.stiffness = 380
        spring.damping = 24
        spring.mass = 1
        spring.duration = min(spring.settlingDuration, 0.18)
        spring.fillMode = .forwards
        spring.isRemovedOnCompletion = false
        icon.layer?.add(spring, forKey: "flashScale")
        icon.layer?.setAffineTransform(.identity)
    }

    // MARK: - Level input (thread-safe write from mic-tap thread)

    func pushLevel(_ level: Float) {
        levelLock.lock()
        latestLevel = max(0, min(1, level))
        levelLock.unlock()
    }

    private func consumeLatestLevel() -> Float? {
        levelLock.lock()
        defer { levelLock.unlock() }
        return latestLevel
    }

    // MARK: - Animation driver

    func setReduceMotion(_ enabled: Bool) {
        reduceMotion = enabled
        if enabled {
            stopAnimating()
            displayedHeights = Array(repeating: restingHeight, count: barCount)
            successIcon.layer?.setAffineTransform(.identity)
            clipboardIcon.layer?.setAffineTransform(.identity)
            needsLayout = true
        }
    }

    func startAnimating() {
        stopAnimating()
        noLevelTicks = 0
        levelHistory = Array(repeating: 0, count: barCount)
        displayedHeights = Array(repeating: restingHeight, count: barCount)
        guard !reduceMotion else {
            needsLayout = true
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    func stopAnimating() {
        displayTimer?.invalidate()
        displayTimer = nil
        for barLayer in barLayers {
            barLayer.removeAllAnimations()
        }
        successIcon.layer?.removeAnimation(forKey: "flashScale")
        clipboardIcon.layer?.removeAnimation(forKey: "flashScale")
    }

    private func tick() {
        switch state {
        case .listening, .editingSelection, .microphoneNoAudio:
            tickListening()
        case .processing:
            tickProcessing()
        case .success, .clipboardFlash, .error:
            break
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func tickListening() {
        if let level = consumeLatestLevel(), level > 0.0 {
            noLevelTicks = 0
            // Normalize: quiet keeps a small resting height, loud speech
            // fills toward maxHeight without clipping past it.
            let normalized = CGFloat(pow(Double(level), 0.6)) // perceptual curve
            let target = restingHeight + normalized * (maxHeight - restingHeight)
            levelHistory.removeFirst()
            levelHistory.append(min(maxHeight, target))
        } else {
            noLevelTicks += 1
            if noLevelTicks > 15 {
                // No level arriving for ~0.5s — fall back to a gentle canned
                // pulse so the HUD never looks frozen.
                pulsePhase += 0.12
                let pulse = restingHeight + (sin(pulsePhase) * 0.5 + 0.5) * 4
                levelHistory.removeFirst()
                levelHistory.append(pulse)
            }
        }

        // Attack/decay smoothing per bar: fast attack, slower decay, so
        // motion is fluid rather than jittery.
        for i in 0 ..< barCount {
            let target = levelHistory[i]
            let current = displayedHeights[i]
            let rate: CGFloat = target > current ? 0.55 : 0.2
            displayedHeights[i] = current + (target - current) * rate
        }
    }

    private func tickProcessing() {
        // Indeterminate shimmer: a soft traveling pulse across the bars,
        // all settled near a low resting height — subtle, Wispr-like.
        pulsePhase += 0.10
        for i in 0 ..< barCount {
            let wave = sin(pulsePhase - CGFloat(i) * 0.6)
            let target = restingHeight + (wave * 0.5 + 0.5) * 6
            displayedHeights[i] = displayedHeights[i] + (target - displayedHeights[i]) * 0.3
        }
    }
}

enum AccessibilityAnnouncement {
    static func post(_ message: String, element: Any) {
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }
}
