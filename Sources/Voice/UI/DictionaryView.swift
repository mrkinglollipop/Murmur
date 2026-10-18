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

    var body: some View {
        let filteredEntries = DictionarySearch.sortedEntries(
            DictionarySearch.entries(store.entries, query: searchText)
        )
        // Pending suggestions are inert, so they are not "your words".
        let activeEntries = filteredEntries.filter { !$0.isPendingApproval }
        VStack(spacing: 0) {
            composer
            Divider().overlay(Theme.hairline)
            searchBar(entries: filteredEntries)

            // One outer scroll: entries (or compact empty) + pending review +
            // corrections. Composer/search stay pinned above.
            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.activeEntries.isEmpty {
                        emptyState
                    } else {
                        termsSectionHeader(count: activeEntries.count)
                        entryRows(entries: activeEntries)
                    }
                    pendingSuggestionsSection(entries: filteredEntries)
                    recentCorrectionsSection
                }
            }
        }
        .saveFailureBanner(store.saveFailure, onDismiss: store.dismissSaveFailure)
        .saveFailureBanner(correctionsLog.saveFailure, onDismiss: correctionsLog.dismissSaveFailure)
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

    private var visibleCorrectionGroups: [CorrectionGroup] {
        DictionarySearch.corrections(correctionsLog.groupedRecent(days: 7), query: searchText)
    }

    @ViewBuilder
    private var recentCorrectionsSection: some View {
        let groups = visibleCorrectionGroups
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Recent corrections")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 8)

                ForEach(groups) { group in
                    groupedCorrectionBlock(group)
                    Divider().overlay(Theme.hairline)
                }
            }
        }
    }

    private func groupedCorrectionBlock(_ group: CorrectionGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(group.replaced)
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)

                Spacer()

                Text(dictionaryRelativeDateFormatter.localizedString(for: group.latestDate, relativeTo: Date()))
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textSecondary)

                Button("Hide") {
                    correctionsLog.remove(ids: group.recordIDs)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .help("Hide from Recent without changing the dictionary")
                .accessibilityLabel("Hide recent corrections for \(group.replaced)")
            }

            ForEach(group.rows) { record in
                recentCorrectionRow(record)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func recentCorrectionRow(_ record: CorrectionRecord) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                recentCorrectionSummary(record)
                Spacer(minLength: 0)
                recentCorrectionActions(record)
            }
            VStack(alignment: .leading, spacing: 6) {
                recentCorrectionSummary(record)
                HStack {
                    Spacer(minLength: 0)
                    recentCorrectionActions(record)
                }
            }
        }
    }

    private func recentCorrectionSummary(_ record: CorrectionRecord) -> some View {
        HStack(spacing: 8) {
            HeardChip(variant: record.heard)

            Text("→")
                .font(Theme.body(13, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .fixedSize()

            Text(record.replaced)
                .font(Theme.body(13, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(correctionSourceLabel(record.source))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .murmurGlassCapsule()
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heard \(record.heard), replaced with \(record.replaced), \(correctionSourceLabel(record.source))")
    }

    private func recentCorrectionActions(_ record: CorrectionRecord) -> some View {
        HStack(spacing: 8) {
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
                    removeLogPair(record)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
            }
        }
        .fixedSize()
        .layoutPriority(1)
    }

    private func removeLogPair(_ record: CorrectionRecord) {
        let ids = correctionsLog.records.filter {
            $0.heard.caseInsensitiveCompare(record.heard) == .orderedSame
                && $0.replaced.caseInsensitiveCompare(record.replaced) == .orderedSame
        }.map(\.id)
        correctionsLog.remove(ids: ids)
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
        // announce: false — no pop-up; the pair returns as a pending suggestion
        // under "Waiting for your OK" (inert until Add). Coordinator appends
        // learnAccepted via onLearnBatch when non-empty.
        _ = store.learn(
            from: record.heard,
            to: record.replaced,
            userInitiated: true,
            announce: false
        )
        // Always dismiss the rejected row, even when learn is a no-op.
        removeLogPair(record)
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
            let soleLearnedVariant = store.entries.first(where: { $0.id == entryID }).map {
                dictionaryEntryHasOnlyHeard($0, heard: record.heard)
            } ?? false
            if createdNew && soleLearnedVariant {
                pendingRevertRecord = record
                showRevertDeleteConfirmation = true
            } else if store.unlearn(correction) {
                removeLogPair(record)
            }
            return
        }
        // Old records without entryID: blocklist + best-effort variant removal.
        if degradeRevertLearnAccepted(record) {
            removeLogPair(record)
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
        removeLogPair(record)
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
           }),
           dictionaryEntryHasOnlyHeard(entry, heard: record.heard) {
            pendingRevertRecord = record
            showRevertDeleteConfirmation = true
        } else {
            revertCorrection(record, deleteEntry: record.source == .autoLearned)
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
                removeLogPair(record)
            }
            return
        }
        if deleteEntry,
           let entry = store.entries.first(where: {
               $0.term.caseInsensitiveCompare(record.replaced) == .orderedSame
           }) {
            var updated = entry
            updated.variants.removeAll {
                $0.caseInsensitiveCompare(record.heard) == .orderedSame
            }
            if updated.variants.isEmpty {
                store.delete(entry)
            } else if updated.variants.count != entry.variants.count {
                store.update(updated)
            }
        }
        store.blocklistPair(heard: record.heard, replaced: record.replaced)
        removeLogPair(record)
    }

    private func dictionaryEntryHasOnlyHeard(_ entry: DictionaryEntry, heard: String) -> Bool {
        !entry.variants.isEmpty && entry.variants.allSatisfy {
            $0.caseInsensitiveCompare(heard) == .orderedSame
        }
    }

    // MARK: - Pending suggestions

    /// Learned suggestions awaiting the user's OK. They change nothing until
    /// added: no rewrite, no phonetic match, no engine vocabulary.
    @ViewBuilder
    private func pendingSuggestionsSection(entries: [DictionaryEntry]) -> some View {
        let pending = entries.filter(\.hasPendingSuggestion)
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Waiting for your OK (\(pending.count))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .accessibilityAddTraits(.isHeader)
                    Text("Not used in dictation until you add them.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

                ForEach(pending) { entry in
                    pendingSuggestionRow(for: entry)
                    Divider().overlay(Theme.hairline)
                }
            }
        }
    }

    private func pendingSuggestionRow(for entry: DictionaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.lavenderText)
                    .help("Suggested from your corrections")
                    .accessibilityLabel("Suggested")

                Text(entry.term)
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)

                Spacer()

                Button("Never") {
                    withAnimation(Theme.easeOutOrNil()) {
                        store.rejectPending(entry)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .help("Don't suggest this again")
                .accessibilityLabel("Never suggest \(entry.term)")

                Button("Add") {
                    withAnimation(Theme.easeOutOrNil()) {
                        store.approvePending(entry)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.primary)
                .help("Add to your dictionary")
                .accessibilityLabel("Add \(entry.term) to dictionary")
            }

            if !entry.unapprovedVariants.isEmpty {
                HeardVariants(variants: entry.unapprovedVariants)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Composer (add new term)

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            DictionaryTextField(
                title: "Correct spelling",
                placeholder: "e.g. Kubernetes",
                text: $newTerm,
                emphasizesText: true
            )

            HStack(alignment: .bottom, spacing: 8) {
                DictionaryTextField(
                    title: "Heard as",
                    hint: "separate with commas",
                    placeholder: "e.g. cube net ease, cooper netties",
                    text: $newVariants
                )
                .onSubmit(addTerm)

                Button("Add word", action: addTerm)
                    .buttonStyle(.glassProminent)
                    .foregroundColor(Theme.ctaText)
                    .tint(Theme.lavender)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize()
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
    }

    private func addTerm() {
        let variants = DictionaryEntryInput.variants(from: newVariants)
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        store.add(term: term, variants: variants)
        newTerm = ""
        newVariants = ""
    }

    // MARK: - Search

    private func searchBar(entries: [DictionaryEntry]) -> some View {
        SearchBar(
            text: $searchText,
            placeholder: "Search terms",
            resultCount: DictionarySearch.needle(searchText).isEmpty ? nil
                : DictionarySearch.resultCount(entries: entries, groups: visibleCorrectionGroups),
            isFocused: $isSearchFocused
        )
        .padding(12)
    }

    // MARK: - List

    private func termsSectionHeader(count: Int) -> some View {
        Text("Your words (\(count))")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func entryRows(entries: [DictionaryEntry]) -> some View {
        ForEach(entries) { entry in
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
                Text(entry.term)
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)

                Spacer()

                if entry.fixCount > 0 {
                    Text("\(entry.fixCount) \(entry.fixCount == 1 ? "fix" : "fixes")")
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
                HeardVariants(variants: entry.variants)
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
            VStack(alignment: .leading, spacing: 4) {
                DictionaryFieldLabel(title: "Correct spelling")
                TextField("e.g. Kubernetes", text: $editTerm)
                    .accessibilityLabel("Correct spelling")
                    .textFieldStyle(.plain)
                    .font(Theme.body(13, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .murmurGlassCard(cornerRadius: Theme.cornerRadiusCompact)
                    .focused($focusedEditID, equals: entry.id)
                    .onSubmit { saveEdit(for: entry) }
            }

            VStack(alignment: .leading, spacing: 4) {
                DictionaryFieldLabel(title: "Heard as", hint: "separate with commas")
                TextField("e.g. cube net ease, cooper netties", text: $editVariants)
                    .accessibilityLabel("Heard as, separate with commas")
                    .textFieldStyle(.plain)
                    .font(Theme.body(13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .murmurGlassCard(cornerRadius: Theme.cornerRadiusCompact)
                    .onSubmit { saveEdit(for: entry) }
            }

            DictionaryPreview(
                variants: DictionaryEntryInput.variants(from: editVariants),
                term: editTerm.trimmingCharacters(in: .whitespaces)
            )

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { cancelEdit() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .keyboardShortcut(.escape, modifiers: [])

                Button("Save") { saveEdit(for: entry) }
                    .buttonStyle(.glassProminent)
                    .foregroundColor(Theme.ctaText)
                    .tint(Theme.lavender)
                    .font(.system(size: 12, weight: .semibold))
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(editTerm.trimmingCharacters(in: .whitespaces).isEmpty)
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
        // A blank term would make correct() replace this entry's variants
        // with empty string — silently deleting words from dictations.
        let term = editTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        var updated = entry
        updated.term = term
        updated.variants = DictionaryEntryInput.variants(from: editVariants)
        store.update(updated)
        editingID = nil
        focusedEditID = nil
    }
}

private struct DictionaryFieldLabel: View {
    let title: String
    var hint: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            if let hint {
                Text("· \(hint)")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct DictionaryTextField: View {
    let title: String
    var hint: String? = nil
    let placeholder: String
    @Binding var text: String
    var emphasizesText = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DictionaryFieldLabel(title: title, hint: hint)
            TextField(placeholder, text: $text)
                .accessibilityLabel(hint.map { "\(title), \($0)" } ?? title)
                .textFieldStyle(.plain)
                .font(Theme.body(13, weight: emphasizesText ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .murmurGlassCard(cornerRadius: Theme.cornerRadiusCompact)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DictionaryPreview: View {
    let variants: [String]
    let term: String

    var body: some View {
        let trimmedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        if DictionaryEntryInput.showsPreview(term: trimmedTerm, variants: variants) {
            ChipFlowLayout(spacing: 5) {
                Text("Will fix")
                    .foregroundColor(Theme.textSecondary)
                ForEach(Array(variants.enumerated()), id: \.offset) { _, variant in
                    HeardChip(variant: variant)
                }
                (Text("→ ").foregroundColor(Theme.textSecondary)
                    + Text(trimmedTerm)
                        .font(Theme.body(12, weight: .semibold))
                        .foregroundColor(Theme.textPrimary))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(Theme.body(12))
        }
    }
}

private struct HeardVariants: View {
    let variants: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Text("Heard as")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .fixedSize()
                .padding(.top, 3)
            FlowChips(variants: variants)
        }
    }
}

private struct HeardChip: View {
    let variant: String

    var body: some View {
        Text(variant)
            .lineLimit(1)
            .truncationMode(.middle)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Theme.textSecondary)
            .strikethrough(true, color: Theme.textSecondary.opacity(0.55))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .murmurGlassCapsule()
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
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
                HeardChip(variant: variant)
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
            let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth.isFinite ? maxWidth : nil, height: nil))
            let gap = rowWidth > 0 ? spacing : 0
            if rowWidth + gap + size.width > maxWidth, rowWidth > 0 {
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
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
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

enum DictionarySearch {
    static func needle(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func entries(_ entries: [DictionaryEntry], query: String) -> [DictionaryEntry] {
        let needle = needle(query)
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.term.lowercased().contains(needle)
                || ($0.variants + $0.pendingVariants).contains { $0.lowercased().contains(needle) }
        }
    }

    /// Presentation-only A–Z order. Store order remains untouched so merely
    /// opening or searching the Dictionary never rewrites persisted entries.
    static func sortedEntries(_ entries: [DictionaryEntry]) -> [DictionaryEntry] {
        entries.sorted { lhs, rhs in
            let lhsKey = lhs.term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let rhsKey = rhs.term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let comparison = lhsKey.compare(rhsKey, options: [.numeric], range: nil, locale: .current)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    static func corrections(_ groups: [CorrectionGroup], query: String) -> [CorrectionGroup] {
        let needle = needle(query)
        guard !needle.isEmpty else { return groups }
        return groups.compactMap { group in
            if group.replaced.lowercased().contains(needle) { return group }
            let rows = group.rows.filter { $0.heard.lowercased().contains(needle) }
            guard !rows.isEmpty else { return nil }
            return CorrectionGroup(replaced: group.replaced, rows: rows, recordIDs: rows.map(\.id))
        }
    }

    static func resultCount(entries: [DictionaryEntry], groups: [CorrectionGroup]) -> Int {
        // Pending entries list only under "Waiting for your OK"; an approved
        // entry with pending heard-forms lists in both sections.
        entries.filter { !$0.isPendingApproval }.count
            + entries.filter(\.hasPendingSuggestion).count
            + groups.reduce(0) { $0 + $1.rows.count }
    }
}

enum DictionaryEntryInput {
    static func showsPreview(term: String, variants: [String]) -> Bool {
        !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !variants.isEmpty
    }

    static func variants(from value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
