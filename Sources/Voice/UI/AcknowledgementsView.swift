import SwiftUI

struct AcknowledgementsSectionView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Acknowledgements.all) { item in
                DisclosureGroup {
                    ScrollView {
                        Text(Acknowledgements.licenseText(for: item))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                } label: {
                    HStack(spacing: 8) {
                        Text(item.name)
                            .font(Theme.body(12, weight: .medium))
                            .foregroundColor(Theme.textPrimary)

                        Text(item.licenseType)
                            .font(Theme.body(10, weight: .semibold))
                            .foregroundColor(Theme.lavenderText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .murmurGlassCapsule(tint: Theme.selectionTint)

                        Spacer()

                        Link("GitHub", destination: item.url)
                            .font(Theme.body(11))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
        }
    }
}
