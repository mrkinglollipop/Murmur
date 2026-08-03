import SwiftUI

/// Left sidebar navigation — wordmark + nav rows (Recent activity,
/// Dictionary) with Settings pinned at the bottom. Replaces the old
/// top-right segmented `navToggle` (see RootView).
struct SidebarNav: View {
    @Binding var selectedTab: RootTab

    private let width: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            wordmark
                .padding(.top, 30)
                .padding(.horizontal, 16)
                .padding(.bottom, 20)

            // GlassEffectContainer so the selected row's glass pill samples a
            // shared backdrop and blends with adjacent glass. The pill
            // cross-fades between rows on selection; a true traveling-glass
            // morph would need a shared .glassEffectID across the rows.
            GlassEffectContainer(spacing: 2) {
                VStack(spacing: 2) {
                    row(for: .history)
                    row(for: .insights)
                    row(for: .dictionary)
                    row(for: .snippets)
                    row(for: .style)
                    row(for: .transforms)
                    row(for: .scratchpad)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            row(for: .settings)
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
        }
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity)
        .background(Theme.bg)
    }

    private var wordmark: some View {
        HStack(spacing: 7) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.primary)
            Text("Murmur")
                .font(Theme.serifTitle(20, weight: .medium))
                .foregroundColor(Theme.textPrimary)
        }
    }

    private func row(for tab: RootTab) -> some View {
        NavRow(tab: tab, isSelected: selectedTab == tab) {
            withAnimation(Theme.easeOutOrNil()) {
                selectedTab = tab
            }
        }
        .keyboardShortcut(tabKeyboardShortcut(for: tab), modifiers: .command)
    }

    private func tabKeyboardShortcut(for tab: RootTab) -> KeyEquivalent {
        switch tab {
        case .history: return "1"
        case .insights: return "2"
        case .dictionary: return "3"
        case .snippets: return "4"
        case .style: return "5"
        case .transforms: return "6"
        case .scratchpad: return "7"
        case .settings: return "8"
        }
    }
}

/// One sidebar nav row: icon + label; coral-tinted Liquid Glass pill when
/// selected, subtle surface tint on hover when not.
private struct NavRow: View {
    let tab: RootTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var label: some View {
        let base = HStack(spacing: 9) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 16)
            Text(tab.title)
                .font(Theme.body(14))
            Spacer(minLength: 0)
        }
        .foregroundColor(isSelected ? Theme.lavenderText : Theme.textSecondary)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)

        if isSelected {
            base.murmurGlassCard(cornerRadius: Theme.cornerRadiusCompact, tint: Theme.selectionTint)
        } else if isHovering {
            base
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusCompact))
        } else {
            base
        }
    }
}
