import SwiftUI

/// Flat snippet list — mirrors `DictionaryView`'s structure/style. Full CRUD
/// via a simple add form (trigger + expansion) and per-row edit/delete.
struct SnippetsView: View {
    @ObservedObject var store: SnippetsStore

    @State private var newTrigger: String = ""
    @State private var newExpansion: String = ""
    @State private var searchText: String = ""
    @State private var editingID: UUID?
    @State private var editTrigger: String = ""
    @State private var editExpansion: String = ""
    @State private var pendingDeleteSnippet: Snippet?
    @State private var showDeleteConfirmation = false

    @FocusState private var isSearchFocused: Bool
    @FocusState private var focusedEditID: UUID?

    private var filteredSnippets: [Snippet] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return store.snippets
        }
        let needle = searchText.lowercased()
        return store.snippets.filter {
            $0.trigger.lowercased().contains(needle) ||
            $0.expansion.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            composer
            Divider().overlay(Theme.hairline)
            searchBar

            if store.snippets.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .confirmDelete(
            isPresented: $showDeleteConfirmation,
            title: "Delete snippet?",
            onConfirm: {
                if let snippet = pendingDeleteSnippet {
                    withAnimation(Theme.easeOutOrNil()) {
                        store.delete(snippet)
                    }
                }
                pendingDeleteSnippet = nil
            }
        )
        .onChange(of: editingID) { _, newValue in
            focusedEditID = newValue
        }
    }

    // MARK: - Composer (add new snippet)

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Trigger phrase — e.g. my email address", text: $newTrigger)
                .textFieldStyle(.plain)
                .font(Theme.body(13))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .murmurGlassCard()

            HStack(spacing: 8) {
                TextField("Expands to…", text: $newExpansion)
                    .textFieldStyle(.plain)
                    .font(Theme.body(13))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .murmurGlassCard()
                    .onSubmit(addSnippet)

                Button("Add snippet", action: addSnippet)
                    .buttonStyle(.glassProminent)
                    .tint(Theme.lavender)
                    .font(.system(size: 13, weight: .semibold))
                    .disabled(
                        newTrigger.trimmingCharacters(in: .whitespaces).isEmpty ||
                        newExpansion.trimmingCharacters(in: .whitespaces).isEmpty
                    )
            }
        }
        .padding(14)
    }

    private func addSnippet() {
        let trigger = newTrigger.trimmingCharacters(in: .whitespaces)
        let expansion = newExpansion.trimmingCharacters(in: .whitespaces)
        guard !trigger.isEmpty, !expansion.isEmpty else { return }
        store.add(trigger: trigger, expansion: expansion)
        newTrigger = ""
        newExpansion = ""
    }

    // MARK: - Search

    private var searchBar: some View {
        SearchBar(
            text: $searchText,
            placeholder: "Search snippets",
            resultCount: searchText.isEmpty ? nil : filteredSnippets.count,
            isFocused: $isSearchFocused
        )
        .padding(12)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredSnippets) { snippet in
                    Group {
                        if editingID == snippet.id {
                            editRow(for: snippet)
                        } else {
                            row(for: snippet)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    Divider().overlay(Theme.hairline)
                }
            }
        }
    }

    private func row(for snippet: Snippet) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snippet.trigger)
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text(snippet.expansion)
                    .font(Theme.body(12))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                beginEdit(snippet)
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Edit")
            .accessibilityLabel("Edit")

            Button {
                pendingDeleteSnippet = snippet
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
        .contextMenu {
            Button("Edit") { beginEdit(snippet) }
            Button("Delete", role: .destructive) {
                pendingDeleteSnippet = snippet
                showDeleteConfirmation = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func editRow(for snippet: Snippet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Trigger", text: $editTrigger)
                .textFieldStyle(.plain)
                .font(Theme.body(13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .murmurGlassCard(cornerRadius: Theme.cornerRadiusCompact)
                .focused($focusedEditID, equals: snippet.id)
                .onSubmit { saveEdit(for: snippet) }

            TextField("Expansion", text: $editExpansion)
                .textFieldStyle(.plain)
                .font(Theme.body(13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .murmurGlassCard(cornerRadius: Theme.cornerRadiusCompact)
                .onSubmit { saveEdit(for: snippet) }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { cancelEdit() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .keyboardShortcut(.escape, modifiers: [])

                Button("Save") { saveEdit(for: snippet) }
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
            Spacer()
            Image(systemName: "scissors")
                .font(.system(size: 28))
                .foregroundColor(Theme.textSecondary)
            Text("No snippets yet")
                .font(Theme.body(13))
                .foregroundColor(Theme.textSecondary)
            Text("Say a trigger phrase to expand it automatically")
                .font(Theme.body(12))
                .foregroundColor(Theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func beginEdit(_ snippet: Snippet) {
        editingID = snippet.id
        editTrigger = snippet.trigger
        editExpansion = snippet.expansion
        focusedEditID = snippet.id
    }

    private func cancelEdit() {
        editingID = nil
        focusedEditID = nil
    }

    private func saveEdit(for snippet: Snippet) {
        var updated = snippet
        updated.trigger = editTrigger.trimmingCharacters(in: .whitespaces)
        updated.expansion = editExpansion.trimmingCharacters(in: .whitespaces)
        store.update(updated)
        editingID = nil
        focusedEditID = nil
    }
}
