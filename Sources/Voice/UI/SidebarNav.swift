import SwiftUI

/// Left sidebar navigation — wordmark + nav rows (Recent activity,
/// Dictionary) with Settings pinned at the bottom. Replaces the old
/// top-right segmented `navToggle` (see RootView).
struct SidebarNav: View {
    @Binding var selectedTab: RootTab
    var isPro: Bool
    /// PRO ONLY — drives the account row (sign-in / account sheet).
    @ObservedObject var authFlow: AuthFlowController

    @State private var showAccountSheet = false
    @State private var isHoveringAccount = false

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
                    ForEach(RootTab.mainTabs) { tab in
                        row(for: tab)
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            accountRow
                .padding(.horizontal, 10)
                .padding(.bottom, 2)

            row(for: .settings)
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
        }
        .sheet(isPresented: $showAccountSheet) {
            if case .signedIn(let session) = authFlow.state {
                AccountSheetView(
                    authFlow: authFlow,
                    email: session.email,
                    isPro: isPro,
                    onDismiss: { showAccountSheet = false }
                )
            } else {
                SignInSheetView(authFlow: authFlow, onDismiss: { showAccountSheet = false })
            }
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
            // PRO ONLY — this branch's builds are visibly distinct from the
            // free app, so a Pro build is never mistaken for a stock one.
            // Must not merge to `main`.
            Text("Pro")
                .font(Theme.body(10, weight: .semibold))
                .foregroundColor(Theme.lavenderText)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Theme.lavender)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Murmur Pro")
    }

    @ViewBuilder
    private func row(for tab: RootTab) -> some View {
        let navRow = NavRow(tab: tab, isSelected: selectedTab == tab, isLocked: tab.isProFeature && !isPro) {
            withAnimation(Theme.easeOutOrNil()) {
                selectedTab = tab
            }
        }
        if let key = tabKeyboardShortcut(for: tab) {
            navRow.keyboardShortcut(key, modifiers: .command)
        } else {
            navRow
        }
    }

    /// `nil` means the tab is click-only.
    ///
    /// Clipboard deliberately has no shortcut: ⌘8 already belongs to Settings,
    /// and the Pro plan reassigns ⌘8 to Transcripts with Settings moving to
    /// ⌘9 — so both numbers are spoken for and neither may be taken here.
    private func tabKeyboardShortcut(for tab: RootTab) -> KeyEquivalent? {
        switch tab {
        case .history: return "1"
        case .insights: return "2"
        case .dictionary: return "3"
        case .snippets: return "4"
        case .style: return "5"
        case .transforms: return "6"
        case .scratchpad: return "7"
        case .clipboard: return nil
        case .settings: return "8"
        }
    }

    /// Account entry on the main screen — signed-out shows a sign-in prompt,
    /// signed-in shows the account email. Settings-only access was the
    /// minimum door for the first live test, not the design.
    private var accountRow: some View {
        Button {
            showAccountSheet = true
        } label: {
            HStack(spacing: 9) {
                Image(systemName: accountIcon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 16)
                Text(accountLabel)
                    .font(Theme.body(13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if isPro { ProChip() }
            }
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Same hover treatment as NavRow — without it this is the one
            // dead-feeling row in the sidebar.
            .background(isHoveringAccount ? Theme.surface : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusCompact))
        }
        .buttonStyle(.plain)
        .onHover { isHoveringAccount = $0 }
        .accessibilityLabel(accountLabel)
    }

    private var accountIcon: String {
        if case .signedIn = authFlow.state { return "person.crop.circle.fill" }
        return "person.crop.circle"
    }

    private var accountLabel: String {
        if case .signedIn(let session) = authFlow.state {
            return session.email ?? "Account"
        }
        return "Sign in"
    }
}

/// Small coral "Pro" marker used beside Pro-only rows and features.
struct ProChip: View {
    var body: some View {
        Text("Pro")
            .font(Theme.body(9, weight: .semibold))
            .foregroundColor(Theme.lavenderText)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(Theme.lavender)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .accessibilityLabel("Pro feature")
    }
}

/// One sidebar nav row: icon + label; coral-tinted Liquid Glass pill when
/// selected, subtle surface tint on hover when not.
private struct NavRow: View {
    let tab: RootTab
    let isSelected: Bool
    let isLocked: Bool
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
            if tab.isProFeature {
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.textSecondary)
                }
                ProChip()
            }
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
