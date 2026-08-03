import SwiftUI

/// Transient card shown after `DictionaryStore.learn(from:to:)` records one or
/// more corrections from a History edit — tells the user what was learned
/// and gives them an immediate way to undo it (the safety net for anything
/// that slips past the similarity gate in `DictionaryStore.learn`).
struct LearnedPill: View {
    let batch: LearnBatch
    let onUndo: () -> Void
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
                Button(action: onUndo) {
                    Text("Undo")
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
