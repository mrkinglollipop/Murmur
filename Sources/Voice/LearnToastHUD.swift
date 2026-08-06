import AppKit
import SwiftUI

/// System-wide floating toast after a successful announced `learn()`.
/// Opt-out: Reject undoes; dismiss/timeout keeps the learn.
/// Concurrent announced learns enqueue (FIFO, cap ``LearnToastPendingQueue.maxPending``);
/// when full, the newest announce is skipped (oldest queued keep Reject).
final class LearnToastHUD {

    private let panel: NSPanel
    private let hosting: NSHostingView<LearnToastContent>
    private var dismissWorkItem: DispatchWorkItem?
    /// Batch shown (or still rejectable during dismiss fade).
    private var rejectableBatch: LearnBatch?
    private var pendingBatches: [LearnBatch] = []
    private var isShowing = false
    private var hideInProgress = false
    private var hideGeneration = 0

    private let toastWidth: CGFloat = 360
    private let estimatedHeight: CGFloat = 72

    /// Recording HUD used for collision layout.
    weak var recordingHUD: RecordingHUD?

    var onReject: ((LearnBatch) -> Void)?
    var onDismiss: (() -> Void)?

    init() {
        let root = LearnToastContent(
            batch: LearnBatch(corrections: []),
            onReject: {},
            onDismiss: {}
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
        // Already presenting or mid fade-out → queue (FIFO; drop newest if full).
        if isShowing || rejectableBatch != nil || hideInProgress {
            _ = LearnToastPendingQueue.enqueue(batch, into: &pendingBatches)
            return
        }
        present(batch)
    }

    /// Dictionary Revert/unlearn: strip matching corrections from the visible
    /// or pending toast batches. Dismisses only when a batch's remainder is
    /// empty. Silent (no Reject / no `onDismiss`). Idempotent if the batch
    /// was already rejected or cleared.
    func dismissBatchesContaining(identities: Set<UnlearnedCorrectionIdentity>) {
        let plan = LearnToastUnlearnDismissal.plan(
            identities: identities,
            rejectable: rejectableBatch,
            pending: pendingBatches
        )
        pendingBatches = plan.pending

        if plan.dismissCurrent {
            dismissWorkItem?.cancel()
            dismissWorkItem = nil
            rejectableBatch = nil
            let generation = beginHide()
            isShowing = false
            hidePanel(generation: generation) { [weak self] in
                self?.presentNextPending()
            }
            return
        }

        guard let updated = plan.rejectable else {
            rejectableBatch = nil
            return
        }
        let priorKeys = rejectableBatch?.corrections.map(UnlearnedCorrectionIdentity.init) ?? []
        let nextKeys = updated.corrections.map(UnlearnedCorrectionIdentity.init)
        rejectableBatch = updated
        guard priorKeys != nextKeys else { return }
        refreshPresentedContent(updated)
    }

    /// Rebuild toast body after a partial unlearn without resetting the
    /// auto-dismiss timer or fade state.
    private func refreshPresentedContent(_ batch: LearnBatch) {
        hosting.rootView = LearnToastContent(
            batch: batch,
            onReject: { [weak self] in self?.reject() },
            onDismiss: { [weak self] in self?.dismiss(userInitiated: true) }
        )
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let width = max(toastWidth, min(size.width, 420))
        let height = max(estimatedHeight, size.height)
        panel.setContentSize(NSSize(width: width, height: height))
        reposition()
    }

    /// Repositions relative to RecordingHUD. Safe when toast is not showing.
    func reposition() {
        guard isShowing || panel.alphaValue > 0.01 || rejectableBatch != nil else { return }
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

    private func present(_ batch: LearnBatch) {
        rejectableBatch = batch
        dismissWorkItem?.cancel()

        hosting.rootView = LearnToastContent(
            batch: batch,
            onReject: { [weak self] in self?.reject() },
            onDismiss: { [weak self] in self?.dismiss(userInitiated: true) }
        )
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let width = max(toastWidth, min(size.width, 420))
        let height = max(estimatedHeight, size.height)
        panel.setContentSize(NSSize(width: width, height: height))

        isShowing = true
        reposition()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in
            self?.dismiss(userInitiated: false)
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: work)
    }

    private func reject() {
        guard let batch = LearnToastRejectSession.takeRejectable(&rejectableBatch) else {
            return
        }
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        onReject?(batch)
        let generation = beginHide()
        isShowing = false
        hidePanel(generation: generation) { [weak self] in
            self?.presentNextPending()
        }
    }

    private func dismiss(userInitiated: Bool) {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        guard rejectableBatch != nil || isShowing else { return }
        let generation = beginHide()
        isShowing = false
        // Keep rejectableBatch until fade ends so Reject during fade still works.
        hidePanel(generation: generation) { [weak self] in
            guard let self, self.hideGeneration == generation else { return }
            if LearnToastRejectSession.clearIfStillPresent(&self.rejectableBatch) {
                self.onDismiss?()
            }
            self.presentNextPending()
        }
        _ = userInitiated
    }

    private func presentNextPending() {
        guard rejectableBatch == nil, !isShowing else { return }
        guard let next = LearnToastPendingQueue.dequeue(from: &pendingBatches) else { return }
        present(next)
    }

    private func beginHide() -> Int {
        hideInProgress = true
        hideGeneration += 1
        return hideGeneration
    }

    private func hidePanel(generation: Int, completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.hideGeneration == generation else { return }
            self.panel.orderOut(nil)
            self.hideInProgress = false
            completion()
        })
    }
}

// MARK: - SwiftUI content

private struct LearnToastContent: View {
    let batch: LearnBatch
    let onReject: () -> Void
    let onDismiss: () -> Void

    private let maxShown = 3

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.lavenderText)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text("Learned")
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)

                correctionsList
            }

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                Button(action: onReject) {
                    Text("Reject")
                        .font(Theme.body(12, weight: .medium))
                        .foregroundColor(Theme.primary)
                }
                .buttonStyle(.plain)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .murmurGlassCard()
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
    }
}
