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

    var body: some View {
        if releases.isEmpty {
            Text("Release notes are not available in this build.")
                .font(Theme.body(12))
                .foregroundColor(Theme.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(releases) { release in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(release.items, id: \.self) { item in
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
                        .padding(.top, 4)
                    } label: {
                        HStack(spacing: 8) {
                            Text(release.title)
                                .font(Theme.body(12, weight: .medium))
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            Text(release.version)
                                .font(Theme.body(10, weight: .semibold))
                                .foregroundColor(Theme.lavenderText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .murmurGlassCapsule(tint: Theme.selectionTint)
                        }
                    }
                }
            }
        }
    }
}
