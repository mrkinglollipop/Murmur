import SwiftUI

/// Read-only stats dashboard over retained dictation and dictionary entries.
struct InsightsView: View {
    @ObservedObject var historyStore: HistoryStore
    @ObservedObject var dictionaryStore: DictionaryStore
    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        if historyStore.entries.isEmpty {
            emptyState
        } else {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let dailyWords = wordsByDay
            let totalWords = dailyWords.values.reduce(0, +)
            let cutoff = calendar.date(byAdding: .day, value: -7, to: today) ?? today
            let wordsThisWeek = dailyWords.filter { $0.key >= cutoff }.values.reduce(0, +)
            let streak = Self.dayStreak(activeDays: Set(dailyWords.keys), today: today, calendar: calendar)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        MetricCard(label: "Words dictated", value: Self.groupedInteger(totalWords))
                        MetricCard(label: "Words this week", value: Self.groupedInteger(wordsThisWeek))
                        MetricCard(label: "Day streak", value: Self.groupedInteger(streak))
                        MetricCard(label: "Dictations", value: Self.groupedInteger(historyStore.entries.count))
                        MetricCard(
                            label: "Dictionary fixes",
                            value: Self.groupedInteger(dictionaryStore.entries.reduce(0) { $0 + $1.fixCount })
                        )
                    }
                    streakGrid(wordsByDay: dailyWords, calendar: calendar, today: today)
                }
                .padding(16)
            }
        }
    }

    static func metricsWordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).filter { !$0.isEmpty }.count
    }

    static func groupedInteger(_ value: Int, locale: Locale = .current) -> String {
        value.formatted(.number.locale(locale).grouping(.automatic))
    }

    /// A streak is live only when the newest active day is today or yesterday.
    static func dayStreak(activeDays: Set<Date>, today: Date, calendar: Calendar = .current) -> Int {
        guard let newest = activeDays.max() else { return 0 }
        let age = calendar.dateComponents([.day], from: newest, to: today).day ?? 2
        guard (0...1).contains(age) else { return 0 }
        var result = 0
        var cursor = newest
        while activeDays.contains(cursor) {
            result += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return result
    }

    /// Zero is empty; positive days use four quantile buckets.
    static func heatmapIntensity(for words: Int, positiveWordCounts: [Int]) -> Int {
        guard words > 0 else { return 0 }
        let sorted = positiveWordCounts.filter { $0 > 0 }.sorted()
        guard let index = sorted.firstIndex(of: words), !sorted.isEmpty else { return 1 }
        return min(4, max(1, Int(ceil(Double(index + 1) * 4 / Double(sorted.count)))))
    }

    private var wordsByDay: [Date: Int] {
        let calendar = Calendar.current
        return historyStore.entries.reduce(into: [:]) { result, entry in
            result[calendar.startOfDay(for: entry.date), default: 0] += Self.metricsWordCount(entry.text)
        }
    }

    private func streakGrid(wordsByDay: [Date: Int], calendar: Calendar, today: Date) -> some View {
        let weekday = calendar.component(.weekday, from: today)
        let daysSinceMonday = (weekday + 5) % 7
        let currentWeekStart = calendar.date(byAdding: .day, value: -daysSinceMonday, to: today) ?? today
        let firstDay = calendar.date(byAdding: .day, value: -(7 * 7), to: currentWeekStart) ?? currentWeekStart
        let days: [Date] = (0..<(8 * 7)).compactMap { calendar.date(byAdding: .day, value: $0, to: firstDay) }
        let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        let positives = days.compactMap { wordsByDay[$0] }.filter { $0 > 0 }
        let total = days.reduce(0) { $0 + (wordsByDay[$1] ?? 0) }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Last 8 weeks")
                .font(Theme.body(12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Mon").frame(height: 10)
                    Spacer().frame(height: 18)
                    Text("Wed").frame(height: 10)
                    Spacer().frame(height: 18)
                    Text("Fri").frame(height: 10)
                }
                .font(Theme.body(10))
                .foregroundColor(Theme.textSecondary)
                HStack(alignment: .top, spacing: 4) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: 4) {
                            ForEach(week, id: \.self) { day in
                                let intensity = Self.heatmapIntensity(for: wordsByDay[day] ?? 0, positiveWordCounts: positives)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(heatmapColor(intensity: intensity))
                                    .frame(width: 10, height: 10)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Words per day for the last eight weeks. \(Self.groupedInteger(total)) total words.")
            HStack(spacing: 5) {
                Text("Fewer")
                ForEach(0...4, id: \.self) { intensity in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(heatmapColor(intensity: intensity))
                        .frame(width: 14, height: 14)
                }
                Text("More words")
            }
            .font(Theme.body(11))
            .foregroundColor(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityHidden(true)
        }
        .padding(14)
        .murmurGlassCard()
    }

    private func heatmapColor(intensity: Int) -> Color {
        switch intensity {
        case 1: return Theme.primary.opacity(0.30)
        case 2: return Theme.primary.opacity(0.48)
        case 3: return Theme.primary.opacity(0.70)
        case 4: return Theme.primary
        default: return Theme.hairline
        }
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

private struct MetricCard: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading) {
            Text(label)
                .font(Theme.body(13))
                .foregroundColor(Theme.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(Theme.serifTitle(24, weight: .medium))
                .foregroundColor(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(14)
        .murmurGlassCard()
    }
}
