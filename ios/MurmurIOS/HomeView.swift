import AVFoundation
import SwiftUI

struct HomeView: View {
    var onOpenSettings: () -> Void
    var settingsOpen: Bool

    @ObservedObject private var session = DictationController.shared
    @ObservedObject private var history = MurmurStores.history
    @State private var micGranted = false

    private var setupIncomplete: Bool {
        AppGroupStore.selectedEngineAPIKey.isEmpty || !micGranted
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                if setupIncomplete {
                    setupCard
                }
                today
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .onAppear { refreshMic() }
        .onChange(of: settingsOpen) { _, open in
            if !open { refreshMic() }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            if history.wordCount == 0 {
                // "on" = set up and ready (key + mic). `session.isArmed` is a
                // transient take-in-flight flag — it read "off" whenever the
                // app was opened between takes, while the keyboard worked fine.
                (
                    Text("Murmur is ")
                        + Text(setupIncomplete ? "off" : "on")
                        .foregroundColor(AppTheme.coral)
                )
                .font(AppTheme.serif(36))
                .foregroundStyle(AppTheme.ink)
                Text("Dictate from the Murmur keyboard. This phone keeps a local count — no fake book stats.")
                    .font(AppTheme.sans(15))
                    .foregroundStyle(AppTheme.muted)
            } else {
                Text(wordCountLabel)
                    .font(AppTheme.serif(40))
                    .foregroundStyle(AppTheme.ink)
                Text("you've dictated on this iPhone")
                    .font(AppTheme.sans(15))
                    .foregroundStyle(AppTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(AppTheme.hero, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
    }

    private var wordCountLabel: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let value = formatter.string(from: NSNumber(value: history.wordCount)) ?? "\(history.wordCount)"
        return "\(value) words"
    }

    private var setupCard: some View {
        Button(action: onOpenSettings) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Finish setup")
                    .font(AppTheme.sans(17, weight: .semibold))
                    .foregroundStyle(AppTheme.ink)
                Text("Keyboard, Full Access, microphone, and API keys live in Settings.")
                    .font(AppTheme.sans(14))
                    .foregroundStyle(AppTheme.muted)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Settings")
    }

    private var today: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Today")
                .font(AppTheme.sans(13, weight: .medium))
                .foregroundStyle(AppTheme.muted)

            let todays = todayEntries
            if todays.isEmpty {
                Text("Dictations show up here.")
                    .font(AppTheme.sans(15))
                    .foregroundStyle(AppTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(AppTheme.card, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(todays.enumerated()), id: \.element.id) { index, entry in
                        historyRow(entry)
                        if index < todays.count - 1 {
                            Divider().overlay(AppTheme.hairline)
                        }
                    }
                }
                .background(AppTheme.card, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
            }
        }
    }

    private var todayEntries: [HistoryEntry] {
        history.entries.filter { Calendar.current.isDateInToday($0.date) }
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.text)
                .font(AppTheme.sans(16, weight: .medium))
                .foregroundStyle(entry.failed ? AppTheme.failed : AppTheme.ink)
                .lineLimit(3)
            Text(entry.date, format: .dateTime.hour().minute())
                .font(AppTheme.sans(13))
                .foregroundStyle(AppTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func refreshMic() {
        micGranted = AVAudioApplication.shared.recordPermission == .granted
    }
}
