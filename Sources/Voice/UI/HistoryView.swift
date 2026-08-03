import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let historyDayHeaderFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMMM d"
    return formatter
}()

private let historyTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
}()

/// "Never lose a transcription" — the cornerstone History view. Newest-first
/// list of every completed dictation, searchable, with a per-row Copy button
/// and a visual flag for entries that were left on the clipboard (injection
/// failed or was skipped) rather than injected directly.
struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var dictionaryStore: DictionaryStore
    var asrEngineSelector: () -> ASREngineSelector?

    @State private var searchText: String = ""
    @State private var copiedID: UUID?
    @State private var editingID: UUID?
    @State private var draftText: String = ""
    @State private var retryingID: UUID?
    @State private var pendingDeleteID: UUID?
    @State private var showDeleteConfirmation = false
    @State private var scrollNearTop = true

    @FocusState private var isSearchFocused: Bool
    @FocusState private var focusedEditID: UUID?

    private var filteredEntries: [HistoryEntry] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return store.entries
        }
        let needle = searchText.lowercased()
        return store.entries.filter { $0.text.lowercased().contains(needle) }
    }

    /// `filteredEntries` bucketed by calendar day, day order preserved
    /// (entries are already newest-first, so the first day encountered is the
    /// most recent). Each bucket keeps its entries' original newest-first
    /// order.
    private var groupedEntries: [(day: Date, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [HistoryEntry]] = [:]

        for entry in filteredEntries {
            let day = calendar.startOfDay(for: entry.date)
            if buckets[day] == nil {
                buckets[day] = []
                order.append(day)
            }
            buckets[day]?.append(entry)
        }

        return order.map { (day: $0, entries: buckets[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Container so the adjacent search-field and export-button glass
            // shapes blend instead of double-refracting at the seam.
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    searchBar
                    exportMenu
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if store.entries.isEmpty {
                emptyState
            } else if filteredEntries.isEmpty {
                noResultsState
            } else {
                list
            }
        }
        .confirmDelete(
            isPresented: $showDeleteConfirmation,
            title: "Delete transcription?",
            onConfirm: {
                if let id = pendingDeleteID {
                    withAnimation(Theme.easeOutOrNil()) {
                        store.delete(id: id)
                    }
                }
                pendingDeleteID = nil
            }
        )
        .onChange(of: editingID) { _, newValue in
            focusedEditID = newValue
        }
    }

    private var searchBar: some View {
        SearchBar(
            text: $searchText,
            placeholder: "Search transcriptions",
            resultCount: searchText.isEmpty ? nil : filteredEntries.count,
            isFocused: $isSearchFocused
        )
        .frame(maxWidth: .infinity)
    }

    private var exportMenu: some View {
        Menu {
            Button("Export as JSON…") { exportJSON() }
            Button("Export as Markdown…") { exportMarkdown() }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
                .padding(8)
                .murmurGlassCard()
        }
        .menuStyle(.borderlessButton)
        .disabled(store.entries.isEmpty)
        .help("Export history")
    }

    private func exportJSON() {
        guard let data = store.exportJSON() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "voice-history.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func exportMarkdown() {
        let markdown = store.exportMarkdown()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "voice-history.md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private var list: some View {
        ScrollView {
            ScrollViewReader { proxy in
                LazyVStack(spacing: 0) {
                    ForEach(groupedEntries, id: \.day) { group in
                        dayHeader(group.day)
                        ForEach(group.entries) { entry in
                            row(for: entry)
                                .id(entry.id)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            Divider().overlay(Theme.hairline)
                        }
                    }
                }
                .onChange(of: store.entries.first?.id) { _, newID in
                    guard let newID, scrollNearTop else { return }
                    withAnimation(Theme.easeOutOrNil()) {
                        proxy.scrollTo(newID, anchor: .top)
                    }
                }
            }
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            scrollNearTop = offset < 80
        }
    }

    private func dayHeader(_ day: Date) -> some View {
        Text(dayLabel(day))
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Theme.textSecondary)
            .textCase(.uppercase)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return historyDayHeaderFormatter.string(from: day)
    }

    private func row(for entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(absoluteTime(entry.date))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }

            if editingID == entry.id {
                TextEditor(text: $draftText)
                    .font(Theme.body(13))
                    .foregroundColor(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 60)
                    .padding(6)
                    .murmurGlassCard()
                    .focused($focusedEditID, equals: entry.id)
                    .onSubmit { saveEdit(for: entry) }
            } else {
                Text(entry.text)
                    .font(Theme.body(13))
                    .foregroundColor(Theme.textPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                // Chip cluster in a container so adjacent glass capsules
                // blend correctly.
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        engineChip(entry.engine)

                        if !entry.injected && !entry.failed {
                            clipboardChip
                        }

                        if entry.failed {
                            failedChip
                        }
                    }
                }

                Spacer()

                Group {
                    if entry.failed, entry.audioPath != nil, retryingID != entry.id {
                        Button {
                            retryEntry(entry)
                        } label: {
                            Text("Retry")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Theme.primary)
                        }
                        .buttonStyle(.plain)
                        .help("Retry transcription")
                    } else if retryingID == entry.id {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    }
                }
                .frame(width: 44, alignment: .trailing)

                if editingID == entry.id {
                    Button {
                        cancelEdit()
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])

                    Button {
                        saveEdit(for: entry)
                    } label: {
                        Text("Save")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.primary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        beginEdit(entry)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Edit")
                    .accessibilityLabel("Edit")

                    Button {
                        copyEntry(entry)
                    } label: {
                        Image(systemName: copiedID == entry.id ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundColor(copiedID == entry.id ? Theme.primary : Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                    .accessibilityLabel(copiedID == entry.id ? "Copied" : "Copy")

                    if !entry.failed {
                        Button {
                            let text = entry.text
                            DispatchQueue.global(qos: .utility).async {
                                _ = TextInjector().insert(text)
                            }
                        } label: {
                            Image(systemName: "arrow.turn.down.left")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Re-inject")
                        .accessibilityLabel("Re-inject")
                    }

                    Button {
                        pendingDeleteID = entry.id
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.recordRed)
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                    .accessibilityLabel("Delete")
                }
            }
        }
        .onExitCommand {
            if editingID != nil { cancelEdit() }
        }
        .contextMenu {
            if editingID != entry.id {
                Button("Edit") { beginEdit(entry) }
                Button("Copy") { copyEntry(entry) }
                if !entry.failed {
                    Button("Re-inject") {
                        let text = entry.text
                        DispatchQueue.global(qos: .utility).async {
                            _ = TextInjector().insert(text)
                        }
                    }
                }
                if entry.failed, entry.audioPath != nil {
                    Button("Retry") { retryEntry(entry) }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    pendingDeleteID = entry.id
                    showDeleteConfirmation = true
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(rowBackground(for: entry))
        .overlay(
            Rectangle()
                .fill(rowAccent(for: entry))
                .frame(width: 2),
            alignment: .leading
        )
    }

    private func rowBackground(for entry: HistoryEntry) -> Color {
        if entry.failed { return Theme.amberBgSubtle }
        return entry.injected ? Theme.bg : Theme.amberBg
    }

    private func rowAccent(for entry: HistoryEntry) -> Color {
        if entry.failed { return Theme.recordRed.opacity(0.55) }
        return entry.injected ? Color.clear : Theme.amberBorder
    }

    private func engineChip(_ engine: String) -> some View {
        Text(EngineDisplayName.displayName(for: engine))
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .murmurGlassCapsule()
    }

    private var failedChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
            Text("Transcription failed")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(Theme.recordRed.opacity(0.85))
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .overlay(
            Capsule().stroke(Theme.recordRed.opacity(0.35), lineWidth: 1)
        )
        .clipShape(Capsule())
    }

    private var clipboardChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "clipboard")
                .font(.system(size: 10))
            Text("Left on clipboard")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(Theme.amberText)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .overlay(
            Capsule().stroke(Theme.amberBorder, lineWidth: 1)
        )
        .clipShape(Capsule())
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 28))
                .foregroundColor(Theme.textSecondary)
            Text("Your dictations will appear here")
                .font(Theme.body(13))
                .foregroundColor(Theme.textSecondary)
            Text("Hold your push-to-talk key to dictate")
                .font(Theme.body(12))
                .foregroundColor(Theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No matching transcriptions")
                .font(Theme.body(13))
                .foregroundColor(Theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func absoluteTime(_ date: Date) -> String {
        historyTimeFormatter.string(from: date)
    }

    private func copyEntry(_ entry: HistoryEntry) {
        store.copyToPasteboard(entry)
        copiedID = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.copyConfirmSeconds) {
            if copiedID == entry.id { copiedID = nil }
        }
    }

    private func retryEntry(_ entry: HistoryEntry) {
        guard let selector = asrEngineSelector() else { return }
        retryingID = entry.id
        store.retryTranscription(id: entry.id, asrSelector: selector) {
            retryingID = nil
        }
    }

    private func beginEdit(_ entry: HistoryEntry) {
        editingID = entry.id
        draftText = entry.text
        focusedEditID = entry.id
    }

    private func cancelEdit() {
        editingID = nil
        focusedEditID = nil
    }

    private func saveEdit(for entry: HistoryEntry) {
        let originalText = entry.text
        dictionaryStore.learn(from: originalText, to: draftText, userInitiated: true)
        store.updateText(id: entry.id, newText: draftText)
        editingID = nil
        focusedEditID = nil
    }
}
