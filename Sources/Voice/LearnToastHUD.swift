import AppKit
import SwiftUI

/// System-wide floating pop-up asking whether to add learned dictionary
/// suggestions. A suggestion does nothing until the user taps **Add**;
/// **Never** rejects and blocklists it; ✕ decides later (it stays pending,
/// still inert, and is listed on the Dictionary screen). No auto-dismiss.
/// Hidden while a dictation records or processes, then shown again.
/// See ``LearnToastState`` for queueing and merge rules.
final class LearnToastHUD {

    private let panel: NSPanel
    private let hosting: NSHostingView<LearnToastContent>
    private(set) var state = LearnToastState()
    /// Batch currently rendered into `hosting` (nil when nothing rendered).
    private var renderedBatch: LearnBatch?
    private var panelShown = false
    private var fadeGeneration = 0

    private let toastWidth: CGFloat = 360
    private let estimatedHeight: CGFloat = 72

    /// Recording HUD used for collision layout.
    weak var recordingHUD: RecordingHUD?

    /// Add: approve every suggestion in the batch.
    var onApprove: ((LearnBatch) -> Void)?
    /// Never: reject + blocklist every suggestion in the batch.
    var onReject: ((LearnBatch) -> Void)?

    init() {
        let root = LearnToastContent(
            batch: LearnBatch(corrections: []),
            onAdd: {},
            onNever: {},
            onDecideLater: {}
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: toastWidth, height: estimatedHeight))
        self.hosting = hosting

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.alphaValue = 0
        panel.contentView = hosting
        self.panel = panel
    }

    func show(batch: LearnBatch) {
        guard !batch.corrections.isEmpty else { return }
        state.receive(batch)
        render()
    }

    /// Dictionary Add / Never / Revert: strip matching corrections from the
    /// visible or queued pop-up batches. Silent (no `onApprove`/`onReject`).
    func dismissBatchesContaining(identities: Set<UnlearnedCorrectionIdentity>) {
        state.strip(identities)
        render()
    }

    /// Recording HUD shown/hidden: hide the pop-up while a dictation records
    /// or processes, and bring it back afterwards.
    func setDictationActive(_ active: Bool) {
        guard state.dictationActive != active else {
            reposition()
            return
        }
        state.dictationActive = active
        render()
    }

    /// Re-syncs with the recording HUD (wired to its layout callback).
    func recordingLayoutChanged() {
        setDictationActive(recordingHUD?.isVisible ?? false)
    }

    // MARK: Actions (internal for tests)

    func performAdd() {
        guard let batch = state.takeCurrent() else { return }
        onApprove?(batch)
        AccessibilityAnnouncement.post(Self.addedAnnouncement(count: batch.corrections.count), element: panel)
        render()
    }

    func performNever() {
        guard let batch = state.takeCurrent() else { return }
        onReject?(batch)
        AccessibilityAnnouncement.post("Won't suggest again", element: panel)
        render()
    }

    /// ✕: the suggestion stays pending (inert) and listed in Dictionary.
    func performDecideLater() {
        guard state.takeCurrent() != nil else { return }
        AccessibilityAnnouncement.post("Saved for later in Dictionary", element: panel)
        render()
    }

    static func suggestionAnnouncement(count: Int) -> String {
        count == 1
            ? "Dictionary suggestion. Add it?"
            : "\(count) dictionary suggestions. Add them?"
    }

    static func addedAnnouncement(count: Int) -> String {
        count == 1 ? "Added to dictionary" : "Added \(count) to dictionary"
    }

    // MARK: Rendering

    private func render() {
        guard state.isOnScreen, let batch = state.current else {
            renderedBatch = nil
            if panelShown { fadeOut() }
            return
        }
        let wasShown = panelShown
        if renderedBatch != batch {
            let isNewBatch = renderedBatch?.id != batch.id
            setContent(batch)
            if wasShown && isNewBatch {
                AccessibilityAnnouncement.post(Self.suggestionAnnouncement(count: batch.corrections.count), element: panel)
            }
        }
        if !wasShown {
            fadeIn()
            AccessibilityAnnouncement.post(Self.suggestionAnnouncement(count: batch.corrections.count), element: panel)
        } else {
            reposition()
        }
    }

    private func setContent(_ batch: LearnBatch) {
        renderedBatch = batch
        hosting.rootView = LearnToastContent(
            batch: batch,
            onAdd: { [weak self] in self?.performAdd() },
            onNever: { [weak self] in self?.performNever() },
            onDecideLater: { [weak self] in self?.performDecideLater() }
        )
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let width = max(toastWidth, min(size.width, 420))
        let height = max(estimatedHeight, size.height)
        panel.setContentSize(NSSize(width: width, height: height))
    }

    private func fadeIn() {
        panelShown = true
        fadeGeneration += 1
        reposition()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOut() {
        panelShown = false
        fadeGeneration += 1
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.fadeGeneration == generation, !self.panelShown else { return }
            self.panel.orderOut(nil)
        })
    }

    /// Repositions relative to RecordingHUD. Safe when the pop-up is hidden.
    func reposition() {
        guard panelShown else { return }
        let hud = recordingHUD
        let visible = hud?.isVisible ?? false
        let frame = hud?.frameForStacking ?? .zero
        let restingY = hud?.restingOriginY ?? restingFallbackY()
        let y = LearnToastLayout.toastOriginY(
            recordingVisible: visible,
            recordingFrame: frame,
            restingOriginY: restingY
        )
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let x = visibleFrame.midX - panel.frame.width / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func restingFallbackY() -> CGFloat {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return 30 }
        return screen.visibleFrame.minY + 30
    }
}

// MARK: - SwiftUI content

/// Pop-up body. Internal so tests can render it to a PNG.
struct LearnToastContent: View {
    let batch: LearnBatch
    let onAdd: () -> Void
    let onNever: () -> Void
    let onDecideLater: () -> Void

    private let maxShown = 3

    private var count: Int { batch.corrections.count }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.lavenderText)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Add to dictionary?")
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                correctionsList
            }

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                Button(action: onNever) {
                    Text("Never")
                        .font(Theme.body(12, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(count == 1 ? "Don't suggest this again" : "Don't suggest these again")
                .accessibilityLabel(count == 1 ? "Never suggest this" : "Never suggest these \(count)")

                Button(action: onAdd) {
                    Text("Add")
                        .font(Theme.body(12, weight: .semibold))
                        .foregroundColor(Theme.primary)
                }
                .buttonStyle(.plain)
                .help(count == 1 ? "Add to your dictionary" : "Add all \(count) to your dictionary")
                .accessibilityLabel(count == 1 ? "Add to dictionary" : "Add all \(count) to dictionary")

                Button(action: onDecideLater) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Decide later in Dictionary")
                .accessibilityLabel("Decide later")
            }
        }
        .modifier(MurmurToastSurface())
        .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
        .frame(maxWidth: 360)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var correctionsList: some View {
        if batch.corrections.count == 1, let only = batch.corrections.first {
            correctionLine(only)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(batch.corrections.prefix(maxShown)) { correction in
                    correctionLine(correction)
                }
                if batch.corrections.count > maxShown {
                    Text("+\(batch.corrections.count - maxShown) more")
                        .font(Theme.body(11))
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
    }

    private func correctionLine(_ correction: LearnedCorrection) -> some View {
        HStack(spacing: 4) {
            Text(correction.variant)
                .foregroundColor(Theme.textSecondary)
            Image(systemName: "arrow.right")
                .font(.system(size: 9))
                .foregroundColor(Theme.textSecondary)
            Text(correction.term)
                .foregroundColor(Theme.textPrimary)
        }
        .font(Theme.body(12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heard \(correction.variant), write \(correction.term)")
    }
}

struct MurmurToastSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .murmurGlassCard()
    }
}
