import SwiftUI
import AppKit

/// Style profile picker — 3 selectable cards (Formal / Casual / Very casual),
/// mirroring Wispr's Style screen. Selecting a card sets the global cleanup
/// formality instruction (see `StyleStore`); has no visible effect on the
/// transcript unless Cleanup is enabled, so we surface that as a muted hint
/// rather than hiding the picker.
struct StyleView: View {
    @ObservedObject var store: StyleStore
    @ObservedObject var settingsStore: SettingsStore

    @State private var pendingRemoveBundleID: String?
    @State private var showRemoveConfirmation = false

    private var frontmostBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private var frontmostAppName: String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown app"
    }

    private var sortedAssignmentBundleIDs: [String] {
        store.appProfileMap.keys.sorted {
            store.appDisplayName(for: $0).localizedCaseInsensitiveCompare(store.appDisplayName(for: $1)) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !settingsStore.cleanupEnabled {
                cleanupOffHint
            }

            perAppSection

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(StyleProfile.allCases) { profile in
                        card(for: profile)
                    }
                }
                .padding(16)
            }
        }
        .confirmDelete(
            isPresented: $showRemoveConfirmation,
            title: "Remove per-app style?",
            message: "This app will use your global style profile again.",
            onConfirm: {
                if let bundleID = pendingRemoveBundleID {
                    store.removeAssignment(forBundleID: bundleID)
                }
                pendingRemoveBundleID = nil
            }
        )
    }

    private var perAppSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Per-app style")
                .font(Theme.body(12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
                .textCase(.uppercase)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(frontmostAppName)
                        .font(Theme.body(13, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .help(frontmostBundleID ?? "")
                }
                Spacer()
                Button("Assign \(store.selected.displayName)") {
                    guard let bundleID = frontmostBundleID else { return }
                    store.assignProfile(store.selected, toBundleID: bundleID)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.lavender)
                .font(Theme.body(11, weight: .semibold))
                .disabled(frontmostBundleID == nil)
            }

            if !store.appProfileMap.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(sortedAssignmentBundleIDs, id: \.self) { bundleID in
                        if let profile = store.appProfileMap[bundleID] {
                            HStack {
                                Text(store.appDisplayName(for: bundleID))
                                    .font(Theme.body(12))
                                    .foregroundColor(Theme.textPrimary)
                                    .help(bundleID)
                                Spacer()
                                Text(profile.displayName)
                                    .font(Theme.body(11))
                                    .foregroundColor(Theme.textSecondary)
                                Button {
                                    pendingRemoveBundleID = bundleID
                                    showRemoveConfirmation = true
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(Theme.textSecondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .murmurGlassPanel()
        .overlay(Rectangle().frame(height: 1).foregroundColor(Theme.hairline), alignment: .bottom)
    }

    private var cleanupOffHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
            Text("Style applies during cleanup — turn on Cleanup in Settings to use it.")
                .font(Theme.body(12))
        }
        .foregroundColor(Theme.textSecondary)
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private func card(for profile: StyleProfile) -> some View {
        let isSelected = store.selected == profile

        return Button {
            store.selected = profile
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(profile.displayName)
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Theme.primary)
                    }
                }

                Text(profile.subtitle)
                    .font(Theme.body(12))
                    .foregroundColor(Theme.textSecondary)

                Text("\u{201C}\(profile.example)\u{201D}")
                    .font(Theme.body(13))
                    .foregroundColor(Theme.textPrimary)
                    .italic()
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .murmurGlassCard()
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadiusCard)
                    .stroke(isSelected ? Theme.lavender : Theme.hairline, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}
