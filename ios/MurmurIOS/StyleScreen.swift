import SwiftUI

struct StyleScreen: View {
    @ObservedObject private var store = MurmurStores.style

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                (
                    Text("Your ")
                        .font(AppTheme.serif(34))
                        .foregroundColor(AppTheme.ink)
                    + Text("default sound")
                        .font(AppTheme.sans(28, weight: .regular))
                        .foregroundColor(AppTheme.coral)
                )

                Text("Caps, punctuation, and spacing only — same as Wispr Style. Murmur does not rewrite your words.")
                    .font(AppTheme.sans(15))
                    .foregroundStyle(AppTheme.muted)

                VStack(spacing: 12) {
                    ForEach(StyleProfile.allCases) { profile in
                        card(for: profile)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    private func card(for profile: StyleProfile) -> some View {
        let selected = store.selected == profile
        return Button {
            store.selected = profile
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(profile.displayName)
                        .font(AppTheme.sans(17, weight: .semibold))
                        .foregroundStyle(AppTheme.ink)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(AppTheme.coral)
                    }
                }
                Text(profile.subtitle)
                    .font(AppTheme.sans(14))
                    .foregroundStyle(AppTheme.muted)
                Text("“\(profile.example)”")
                    .font(AppTheme.sans(15))
                    .italic()
                    .foregroundStyle(AppTheme.ink)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(AppTheme.coral.opacity(0.10))
                    )
            }
            .padding(16)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                    .stroke(selected ? AppTheme.coral : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
