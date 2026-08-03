import SwiftUI

private let scratchpadRelativeDateFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
}()

/// Notes list + detail editor split. Unlike Dictionary/Snippets (flat
/// list-only), Scratchpad needs a persistent editor pane since notes are
/// free-form dictation targets, not short structured rows.
///
/// The detail editor's `TextEditor` is a normal focused text view, so
/// dictation injects into it via the existing text-injection path when
/// focused — no special mode needed here.
struct ScratchpadView: View {
    @ObservedObject var store: ScratchpadStore

    @State private var selectedID: UUID?
    @State private var editingTitle: String = ""
    @State private var editingBody: String = ""
    @State private var showDeleteConfirmation = false

    private var selectedNote: ScratchpadNote? {
        guard let id = selectedID else { return nil }
        return store.notes.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 220)
            Divider().overlay(Theme.hairline)

            if selectedNote != nil {
                editor
            } else {
                emptyDetail
            }
        }
        .confirmDelete(
            isPresented: $showDeleteConfirmation,
            title: "Delete note?",
            onConfirm: {
                if let id = selectedID {
                    withAnimation(Theme.easeOutOrNil()) {
                        store.delete(id: id)
                    }
                    selectedID = nil
                }
            }
        )
        .onChange(of: selectedID) { _, newValue in
            guard let note = store.notes.first(where: { $0.id == newValue }) else { return }
            editingTitle = note.title
            editingBody = note.body
        }
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            newNoteButton
            Divider().overlay(Theme.hairline)

            if store.notes.isEmpty {
                emptyList
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.notes) { note in
                            row(for: note)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            Divider().overlay(Theme.hairline)
                        }
                    }
                }
            }
        }
    }

    private var newNoteButton: some View {
        Button {
            let note = store.newNote()
            selectedID = note.id
            editingTitle = note.title
            editingBody = note.body
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("New note")
                    .font(Theme.body(13, weight: .semibold))
            }
            .foregroundColor(Theme.lavenderText)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.lavender)
        .padding(14)
    }

    private func row(for note: ScratchpadNote) -> some View {
        let isSelected = note.id == selectedID
        let displayTitle = note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled note"
            : note.title
        let preview = note.body
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""

        let label = VStack(alignment: .leading, spacing: 4) {
            Text(displayTitle)
                .font(Theme.body(13, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
            if !preview.isEmpty {
                Text(preview)
                    .font(Theme.body(11))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            Text(relativeDate(note.updatedAt))
                .font(.system(size: 10))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        return Button {
            selectedID = note.id
        } label: {
            if isSelected {
                label.murmurGlassCard(cornerRadius: 0, tint: Theme.selectionTint)
            } else {
                label
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete", role: .destructive) {
                selectedID = note.id
                showDeleteConfirmation = true
            }
        }
    }

    private func relativeDate(_ date: Date) -> String {
        scratchpadRelativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    private var emptyList: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "note.text")
                .font(.system(size: 28))
                .foregroundColor(Theme.textSecondary)
            Text("No notes yet")
                .font(Theme.body(12))
                .foregroundColor(Theme.textSecondary)
            Text("Tap new note to start dictating here")
                .font(Theme.body(11))
                .foregroundColor(Theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Detail editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Untitled note", text: $editingTitle)
                    .textFieldStyle(.plain)
                    .font(Theme.serifTitle(18, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .onChange(of: editingTitle) { _, newValue in
                        persist(title: newValue, body: editingBody)
                    }

                Spacer()

                Button {
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
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider().overlay(Theme.hairline)

            TextEditor(text: $editingBody)
                .font(Theme.body(14))
                .foregroundColor(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .onChange(of: editingBody) { _, newValue in
                    persist(title: editingTitle, body: newValue)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .murmurGlassPanel()
    }

    private func persist(title: String, body: String) {
        guard let id = selectedID else { return }
        store.update(id: id, title: title, body: body)
    }

    private var emptyDetail: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "note.text")
                .font(.system(size: 28))
                .foregroundColor(Theme.textSecondary)
            Text("Select a note, or start a new one")
                .font(Theme.body(13))
                .foregroundColor(Theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .murmurGlassPanel()
    }
}
