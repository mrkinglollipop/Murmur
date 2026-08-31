import SwiftUI

struct WhatsNewReleaseView: View {
    let release: WhatsNewRelease
    var showsBuildSubtitle: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(release.title)
                    .font(Theme.serifTitle(20, weight: .medium))
                    .foregroundColor(Theme.textPrimary)

                if showsBuildSubtitle {
                    Text("Version \(release.version) (\(release.build))")
                        .font(Theme.body(11))
                        .foregroundColor(Theme.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(release.items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(Theme.body(12, weight: .semibold))
                            .foregroundColor(Theme.primary)
                        Text(item)
                            .font(Theme.body(12))
                            .foregroundColor(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WhatsNewListView: View {
    let releases: [WhatsNewRelease]
    var showsBuildSubtitle: Bool = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(releases) { release in
                    WhatsNewReleaseView(release: release, showsBuildSubtitle: showsBuildSubtitle)
                    if release.id != releases.last?.id {
                        Divider().overlay(Theme.hairline)
                    }
                }
            }
            .padding(20)
        }
    }
}

struct WhatsNewSettingsSectionView: View {
    private let releases = WhatsNewCatalog.load()
    @State private var showEarlierReleases = false

    var body: some View {
        if releases.isEmpty {
            Text("Release notes are not available in this build.")
                .font(Theme.body(12))
                .foregroundColor(Theme.textSecondary)
        } else if let latest = releases.first {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(latest.title)
                        .font(Theme.body(12, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(latest.version)
                        .font(Theme.body(10, weight: .semibold))
                        .foregroundColor(Theme.lavenderText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .murmurGlassCapsule(tint: Theme.selectionTint)
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(latest.items, id: \.self) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                                .font(Theme.body(11, weight: .semibold))
                                .foregroundColor(Theme.primary)
                            Text(item)
                                .font(Theme.body(11))
                                .foregroundColor(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if releases.count > 1 {
                    Button {
                        showEarlierReleases = true
                    } label: {
                        Text("Earlier releases (\(releases.count - 1))")
                            .font(Theme.body(11, weight: .medium))
                            .foregroundColor(Theme.lavenderText)
                    }
                    .buttonStyle(.plain)
                    .sheet(isPresented: $showEarlierReleases) {
                        WhatsNewEarlierReleasesSheet(
                            releases: Array(releases.dropFirst()),
                            onDismiss: { showEarlierReleases = false }
                        )
                    }
                }
            }
        }
    }
}

private struct WhatsNewEarlierReleasesSheet: View {
    let releases: [WhatsNewRelease]
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Earlier releases")
                    .font(Theme.serifTitle(22, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button("Done", action: onDismiss)
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            WhatsNewListView(releases: releases, showsBuildSubtitle: true)
        }
        .frame(minWidth: 420, minHeight: 480)
        .background(Theme.bg)
    }
}
