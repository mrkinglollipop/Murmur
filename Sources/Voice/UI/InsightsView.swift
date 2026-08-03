import SwiftUI

/// Read-only stats dashboard over `HistoryStore` + `DictionaryStore` — no new
/// store needed, this view only aggregates what those two already persist.
///
/// WPM is intentionally NOT shown: `HistoryEntry` has no duration field, so a
/// words-per-minute figure would have to be fabricated. Omit rather than fake
/// it — see `HistoryStore.swift`.
struct InsightsView: View {
    @ObservedObject var historyStore: HistoryStore
    @ObservedObject var dictionaryStore: DictionaryStore

    private var totalWords: Int {
        historyStore.entries.reduce(0) { $0 + wordCount($1.text) }
    }

    private var wordsThisWeek: Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return historyStore.entries
            .filter { $0.date >= cutoff }
            .reduce(0) { $0 + wordCount($1.text) }
    }

    /// Consecutive calendar days (ending at the most recent entry's day, which
    /// is "today" for an active streak) with at least one entry. Walks
    /// backward one day at a time until a gap is found.
    private var dayStreak: Int {
        guard !historyStore.entries.isEmpty else { return 0 }
        let calendar = Calendar.current
        let activeDays = Set(historyStore.entries.map { calendar.startOfDay(for: $0.date) })
        guard let mostRecent = activeDays.max() else { return 0 }

        var streak = 0
        var cursor = mostRecent
        while activeDays.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    private var transcriptionCount: Int {
        historyStore.entries.count
    }

    private var dictionaryFixCount: Int {
        dictionaryStore.entries.reduce(0) { $0 + $1.fixCount }
    }

    private func wordCount(_ text: String) -> Int {
        Self.metricsWordCount(text)
    }

    /// Shared word-count for metrics tiles and tests.
    static func metricsWordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).filter { !$0.isEmpty }.count
    }

    private var wordsByDay: [Date: Int] {
        let calendar = Calendar.current
        return historyStore.entries.reduce(into: [:]) { result, entry in
            let day = calendar.startOfDay(for: entry.date)
            result[day, default: 0] += wordCount(entry.text)
        }
    }

    private static let heatmapDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        if historyStore.entries.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        MetricCard(label: "Total words (last 1,000)", value: "\(totalWords)")
                        MetricCard(label: "Words this week (retained)", value: "\(wordsThisWeek)")
                        MetricCard(label: "Day streak (retained)", value: "\(dayStreak)")
                        MetricCard(label: "Dictations (last 1,000)", value: "\(transcriptionCount)")
                        MetricCard(label: "Dictionary fixes", value: "\(dictionaryFixCount)")
                    }

                    streakGrid
                }
                .padding(16)
            }
        }
    }

    // MARK: - Streak grid (last 8 weeks)

    /// Small filled/unfilled squares, one per day over the last 8 weeks,
    /// filled when that calendar day has at least one entry. Computed
    /// directly from entry dates — no new persistence.
    private var streakGrid: some View {
        let calendar = Calendar.current
        let activeDays = Set(historyStore.entries.map { calendar.startOfDay(for: $0.date) })
        let today = calendar.startOfDay(for: Date())
        let dayCount = 8 * 7
        let days: [Date] = (0..<dayCount).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
        let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }

        return VStack(alignment: .leading, spacing: 8) {
            Text("Last 8 weeks")
                .font(Theme.body(12, weight: .medium))
                .foregroundColor(Theme.textSecondary)

            HStack(alignment: .top, spacing: 4) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: 4) {
                        ForEach(week, id: \.self) { day in
                            let words = wordsByDay[day] ?? 0
                            RoundedRectangle(cornerRadius: 2)
                                .fill(activeDays.contains(day) ? Theme.primary : Theme.hairline)
                                .frame(width: 10, height: 10)
                                .help(heatmapCellHelp(day: day, wordCount: words))
                        }
                    }
                }
            }
        }
        .padding(14)
        .murmurGlassCard()
    }

    private func heatmapCellHelp(day: Date, wordCount: Int) -> String {
        let dateLabel = Self.heatmapDayFormatter.string(from: day)
        if wordCount == 0 {
            return "\(dateLabel) — no words"
        }
        return "\(dateLabel) — \(wordCount) word\(wordCount == 1 ? "" : "s")"
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "chart.bar")
                .font(.system(size: 28))
                .foregroundColor(Theme.textSecondary)
            Text("No dictations yet")
                .font(Theme.body(13))
                .foregroundColor(Theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One stat card: muted label + large serif number, matching the mockup's
/// Wispr-style metric tiles.
private struct MetricCard: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(Theme.body(13))
                .foregroundColor(Theme.textSecondary)
            Text(value)
                .font(Theme.serifTitle(24, weight: .medium))
                .foregroundColor(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .murmurGlassCard()
    }
}
