import SwiftUI

struct WhatsNewSheetView: View {
    let releases: [WhatsNewRelease]
    var onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                Text("What's New")
                    .font(Theme.serifTitle(22, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                WhatsNewListView(releases: releases, showsBuildSubtitle: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                GlassEffectContainer(spacing: 10) {
                    Button("Got it") {
                        onDismiss()
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.lavender)
                    .font(Theme.body(12, weight: .medium))
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .padding(8)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .frame(width: 480, height: 420)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }
}
