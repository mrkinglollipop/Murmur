import SwiftUI

private let dictionaryRelativeDateFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
}()

/// Flat (no categories) dictionary list — matches the mockup's chip-based
/// look. Full CRUD via a simple add form (term + comma-separated variants)
/// and per-row edit/delete.
struct DictionaryView: View {
    @ObservedObject var store: DictionaryStore
    @ObservedObject var correctionsLog: CorrectionsLog

    init(store: DictionaryStore, correctionsLog: CorrectionsLog? = nil) {
        self.store = store
        self._correctionsLog = ObservedObject(
            wrappedValue: correctionsLog ?? CorrectionsLog.liveInstance ?? CorrectionsLog()
        )
    }

    @State private var newTerm: String = ""
    @State private var newVariants: String = ""
    @State private var searchText: String = ""
    @State private var editingID: UUID?
    @State private var editTerm: String = ""
    @State private var editVariants: String = ""
    @State private var pendingDeleteEntry: DictionaryEntry?
    @State private var showDeleteConfirmation = false
    @State private var pendingRevertRecord: CorrectionRecord?
    @State private var showRevertDeleteConfirmation = false

    @FocusState private var isSearchFocused: Bool
    @FocusState private var focusedEditID: UUID?

    private var filteredEntries: [DictionaryEntry] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return store.entries
        }
        let needle = searchText.lowercased()
        return store.entries.filter {
            $0.term.lowercased().contains(needle) ||
            $0.variants.contains { $0.lowercased().contains(needle) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            composer
            Divider().overlay(Theme.hairline)
            searchBar

            // One outer scroll: entries (or compact empty) + corrections +
            // auto-learned. Composer/search stay pinned above.
            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.entries.isEmpty {
                        emptyState
                    } else {
                        entryRows
                    }
                    recentCorrectionsSection
                    autoLearnedSection
                }
            }
        }
        .confirmDelete(
            isPresented: $showDeleteConfirmation,
            title: "Delete dictionary term?",
            onConfirm: {
                if let entry = pendingDeleteEntry {
                    withAnimation(Theme.easeOutOrNil()) {
                        store.delete(entry)
                    }
                }
                pendingDeleteEntry = nil
            }
        )
        .confirmDelete(
            isPresented: $showRevertDeleteConfirmation,
            title: pendingRevertRecord?.source == .learnAccepted
                ? "Remove learned dictionary entry?"
                : "Revert auto-learned term?",
            onConfirm: {
                if let record = pendingRevertRecord {
                    revertCorrection(record, deleteEntry: true)
                }
                pendingRevertRecord = nil
            }
        )
        .onChange(of: editingID) { _, newValue in
            focusedEditID = newValue
        }
    }

    // MARK: - Recent corrections

    @ViewBuilder
    private var recentCorrectionsSection: some View {
        let recent = correctionsLog.recent(days: 7)
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Recent corrections")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 8)

                ForEach(recent) { record in
                    recentCorrectionRow(record)
                    Divider().overlay(Theme.hairline)
                }
            }
        }
    }

    private func recentCorrectionRow(_ record: CorrectionRecord) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(record.heard) → \(record.replaced)")
                    .font(Theme.body(13, weight: .medium))
                    .foregroundColor(Theme.textPrimary)

                HStack(spacing: 6) {
                    Text(correctionSourceLabel(record.source))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .murmurGlassCapsule()

                    Text(dictionaryRelativeDateFormatter.localizedString(for: record.date, relativeTo: Date()))
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textSecondary)
                }
            }

            Spacer()

            switch record.source {
            case .learnRejected:
                Button("Restore") {
                    handleRestore(record)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)

            case .learnAccepted:
                Button("Revert") {
                    handleLearnAcceptedRevert(record)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)

                Button("Never") {
                    handleLearnAcceptedNever(record)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)

            case .dictionary, .phonetic, .autoLearned:
                Button("Revert") {
                    handleRevert(record)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)

                Button("Never") {
                    store.blocklistPair(heard: record.heard, replaced: record.replaced)
                    correctionsLog.remove(id: record.id)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func correctionSourceLabel(_ source: CorrectionSource) -> String {
        switch source {
        case .dictionary: return "dictionary"
        case .phonetic: return "phonetic"
        case .autoLearned: return "auto-learned"
        case .learnAccepted: return "learned"
        case .learnRejected: return "rejected"
        }
    }

    private func handleRestore(_ record: CorrectionRecord) {
        store.unblockPair(heard: record.heard, replaced: record.replaced)
        // announce: false — no toast; coordinator appends learnAccepted via onLearnBatch when non-empty.
        _ = store.learn(
            from: record.heard,
            to: record.replaced,
            userInitiated: true,
            announce: false
        )
        // Always dismiss the rejected row, even when learn is a no-op.
        correctionsLog.remove(id: record.id)
    }

    private func handleLearnAcceptedRevert(_ record: CorrectionRecord) {
        if let entryID = record.entryID,
           let createdNew = record.createdNewEntry {
            let correction = LearnedCorrection(
                variant: record.heard,
                term: record.replaced,
                createdNewEntry: createdNew,
                entryID: entryID
            )
            if createdNew {
                pendingRevertRecord = record
                showRevertDeleteConfirmation = true
            } else if store.unlearn(correction) {
                correctionsLog.remove(id: record.id)
            }
            return
        }
        // Old records without entryID: blocklist + best-effort variant removal.
        if degradeRevertLearnAccepted(record) {
            correctionsLog.remove(id: record.id)
        }
    }

    private func handleLearnAcceptedNever(_ record: CorrectionRecord) {
        if let entryID = record.entryID,
           let createdNew = record.createdNewEntry {
            let correction = LearnedCorrection(
                variant: record.heard,
                term: record.replaced,
                createdNewEntry: createdNew,
                entryID: entryID
            )
            store.unlearn(correction)
        } else {
            _ = degradeRevertLearnAccepted(record)
        }
        store.blocklistPair(heard: record.heard, replaced: record.replaced)
        // User intent = stop this pair; dismiss even if unlearn was a quiet no-op.
        correctionsLog.remove(id: record.id)
    }

    /// Pre-migration learnAccepted rows: pure undo (remove matching variant by CI).
    /// Never must call `blocklistPair` separately — Revert must not blocklist.
    /// Tears down any active Learn toast for the undone variant only.
    /// - Returns: `true` when a store mutation was applied.
    @discardableResult
    private func degradeRevertLearnAccepted(_ record: CorrectionRecord) -> Bool {
        if let entry = store.entries.first(where: {
            $0.term.caseInsensitiveCompare(record.replaced) == .orderedSame
        }) {
            var updated = entry
            let before = updated.variants.count
            updated.variants.removeAll {
                $0.caseInsensitiveCompare(record.heard) == .orderedSame
            }
            // Mirror `applyUnlearn`: no-op when the variant was already gone.
            guard updated.variants.count != before else { return false }
            if updated.variants.isEmpty && entry.isAutoLearned {
                store.delete(entry)
            } else {
                store.update(updated)
            }
            store.notifyUnlearned([
                UnlearnedCorrectionIdentity(
                    entryID: entry.id,
                    variant: record.heard,
                    term: record.replaced
                )
            ])
            return true
        }
        return false
    }

    private func handleRevert(_ record: CorrectionRecord) {
        if record.source == .autoLearned,
           let entry = store.entries.first(where: {
               $0.term.caseInsensitiveCompare(record.replaced) == .orderedSame
           }) {
            pendingRevertRecord = record
            showRevertDeleteConfirmation = true
        } else {
            revertCorrection(record, deleteEntry: false)
        }
    }

    private func revertCorrection(_ record: CorrectionRecord, deleteEntry: Bool) {
        if record.source == .learnAccepted,
           let entryID = record.entryID,
           let createdNew = record.createdNewEntry {
            let correction = LearnedCorrection(
                variant: record.heard,
                term: record.replaced,
                createdNewEntry: createdNew,
                entryID: entryID
            )
            if store.unlearn(correction) {
                correctionsLog.remove(id: record.id)
            }
            return
        }
        if deleteEntry,
           let entry = store.entries.first(where: {
               $0.term.caseInsensitiveCompare(record.replaced) == .orderedSame
           }) {
            store.delete(entry)
        }
        store.blocklistPair(heard: record.heard, replaced: record.replaced)
        correctionsLog.remove(id: record.id)
    }

    // MARK: - Auto-learned entries

    @ViewBuilder
    private var autoLearnedSection: some View {
        let autoLearned = store.entries.filter { $0.isAutoLearned }
        if !autoLearned.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Auto-learned entries")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 8)

                ForEach(autoLearned) { entry in
                    autoLearnedRow(for: entry)
                    Divider().overlay(Theme.hairline)
                }
            }
        }
    }

    private func autoLearnedRow(for entry: DictionaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.term)
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)

                Spacer()

                Button("Approve") {
                    var updated = entry
                    updated.isAutoLearned = false
                    store.update(updated)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)

                Button("Delete") {
                    pendingDeleteEntry = entry
                    showDeleteConfirmation = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
            }

            if !entry.variants.isEmpty {
                FlowChips(variants: entry.variants)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Composer (add new term)

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Correct spelling — e.g. Kubernetes", text: $newTerm)
                .textFieldStyle(.plain)
                .font(Theme.body(13))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .murmurGlassCard()

            HStack(spacing: 8) {
                TextField("Misheard variants, comma-separated", text: $newVariants)
                    .textFieldStyle(.plain)
                    .font(Theme.body(13))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .murmurGlassCard()
                    .onSubmit(addTerm)

                Button("Add term", action: addTerm)
                    .buttonStyle(.glassProminent)
                    .tint(Theme.lavender)
                    .font(.system(size: 13, weight: .semibold))
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
    }

    private func addTerm() {
        let variants = newVariants
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        store.add(term: term, variants: variants)
        newTerm = ""
        newVariants = ""
    }

    // MARK: - Search

    private var searchBar: some View {
        SearchBar(
            text: $searchText,
            placeholder: "Search terms",
            resultCount: searchText.isEmpty ? nil : filteredEntries.count,
            isFocused: $isSearchFocused
        )
        .padding(12)
    }

    // MARK: - List

    @ViewBuilder
    private var entryRows: some View {
        ForEach(filteredEntries) { entry in
            Group {
                if editingID == entry.id {
                    editRow(for: entry)
                } else {
                    row(for: entry)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
            Divider().overlay(Theme.hairline)
        }
    }

    private func row(for entry: DictionaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if entry.isAutoLearned {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.lavenderText)
                        .help("Learned automatically from a History edit")
                        .accessibilityLabel("Learned automatically")
                }

                Text(entry.term)
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)

                Spacer()

                if entry.fixCount > 0 {
                    Text("\(entry.fixCount) fix\(entry.fixCount == 1 ? "" : "es")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .murmurGlassCapsule()
                }

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
                    pendingDeleteEntry = entry
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Delete")
                .accessibilityLabel("Delete")
            }

            if !entry.variants.isEmpty {
                FlowChips(variants: entry.variants)
            }
        }
        .contextMenu {
            Button("Edit") { beginEdit(entry) }
            Button("Delete", role: .destructive) {
                pendingDeleteEntry = entry
                showDeleteConfirmation = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func editRow(for entry: DictionaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Term", text: $editTerm)
                .textFieldStyle(.plain)
                .font(Theme.body(13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .murmurGlassCard(cornerRadius: Theme.cornerRadiusCompact)
                .focused($focusedEditID, equals: entry.id)
                .onSubmit { saveEdit(for: entry) }

            TextField("Variants, comma-separated", text: $editVariants)
                .textFieldStyle(.plain)
                .font(Theme.body(13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .murmurGlassCard(cornerRadius: Theme.cornerRadiusCompact)
                .onSubmit { saveEdit(for: entry) }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { cancelEdit() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .keyboardShortcut(.escape, modifiers: [])

                Button("Save") { saveEdit(for: entry) }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.lavender)
                    .font(.system(size: 12, weight: .semibold))
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onExitCommand { cancelEdit() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "book.closed")
                .font(.system(size: 28))
                .foregroundColor(Theme.textSecondary)
            Text("No dictionary terms yet")
                .font(Theme.body(13))
                .foregroundColor(Theme.textSecondary)
            Text("Terms you correct in History land here — or add one above")
                .font(Theme.body(12))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func beginEdit(_ entry: DictionaryEntry) {
        editingID = entry.id
        editTerm = entry.term
        editVariants = entry.variants.joined(separator: ", ")
        focusedEditID = entry.id
    }

    private func cancelEdit() {
        editingID = nil
        focusedEditID = nil
    }

    private func saveEdit(for entry: DictionaryEntry) {
        var updated = entry
        updated.term = editTerm.trimmingCharacters(in: .whitespaces)
        updated.variants = editVariants
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        store.update(updated)
        editingID = nil
        focusedEditID = nil
    }
}

/// A simple wrapping chip row for a dictionary entry's misheard variants.
private struct FlowChips: View {
    let variants: [String]

    var body: some View {
        // GlassEffectContainer so the closely-packed variant chips' glass
        // shapes sample and blend together rather than double-refracting.
        GlassEffectContainer(spacing: 5) {
            FlexibleView(data: variants) { variant in
                Text(variant)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .murmurGlassCapsule()
            }
        }
    }
}

/// Minimal flow/wrap layout for chip collections, using macOS 14's `Layout`
/// protocol. Dependency-free replacement for a third-party flow-layout lib.
private struct FlexibleView<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
    let data: Data
    let content: (Data.Element) -> Content

    var body: some View {
        ChipFlowLayout(spacing: 5) {
            ForEach(Array(data), id: \.self) { element in
                content(element)
            }
        }
    }
}

/// A basic left-to-right, top-to-bottom flow layout (macOS 14+ `Layout`
/// protocol), used for dictionary variant chips.
private struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + (rowWidth > 0 ? spacing : 0)
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
