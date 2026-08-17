import SwiftUI

struct SnippetsScreen: View {
    @ObservedObject private var store = MurmurStores.snippets
    @State private var showIntro = !AppGroupStore.introDismissed(AppGroupStore.snippetsIntroKey)
    @State private var editor: SnippetEditorState?
    @State private var pendingDelete: Snippet?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if showIntro {
                        introCard
                    }
                    listCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 88)
            }

            fab
                .padding(.trailing, 22)
                .padding(.bottom, 12)
        }
        .sheet(item: $editor) { state in
            SnippetEditorSheet(state: state) { trigger, expansion in
                save(state: state, trigger: trigger, expansion: expansion)
            }
        }
        .confirmationDialog("Delete snippet?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let snippet = pendingDelete {
                    store.delete(snippet)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text("The stuff you shouldn't have to re-type")
                    .font(AppTheme.serif(26))
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Button {
                    AppGroupStore.dismissIntro(AppGroupStore.snippetsIntroKey)
                    showIntro = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.muted)
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Dismiss")
            }
            Text("Speak the trigger, get the expansion — emails, links, addresses, bios.")
                .font(AppTheme.sans(15))
                .foregroundStyle(AppTheme.muted)
            Button("Add new snippet") {
                editor = SnippetEditorState()
            }
            .buttonStyle(CoralWideButtonStyle())
        }
        .padding(20)
        .background(AppTheme.hero, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
    }

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your snippets (\(store.snippets.count))")
                .font(AppTheme.sans(13, weight: .medium))
                .foregroundStyle(AppTheme.muted)

            if store.snippets.isEmpty {
                Text("No snippets yet.")
                    .font(AppTheme.sans(15))
                    .foregroundStyle(AppTheme.muted)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.card, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.snippets.enumerated()), id: \.element.id) { index, snippet in
                        Button {
                            editor = SnippetEditorState(snippet: snippet)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(snippet.trigger)
                                    .font(AppTheme.sans(16, weight: .medium))
                                    .foregroundStyle(AppTheme.ink)
                                Text(snippet.expansion)
                                    .font(AppTheme.sans(14))
                                    .foregroundStyle(AppTheme.muted)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                pendingDelete = snippet
                            }
                        }
                        if index < store.snippets.count - 1 {
                            Divider().overlay(AppTheme.hairline).padding(.leading, 16)
                        }
                    }
                }
                .background(AppTheme.card, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
            }
        }
    }

    private var fab: some View {
        Button {
            editor = SnippetEditorState()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(AppTheme.coral))
                .shadow(color: AppTheme.coral.opacity(0.35), radius: 8, y: 3)
        }
        .accessibilityLabel("Add new snippet")
    }

    private func save(state: SnippetEditorState, trigger: String, expansion: String) {
        if let snippet = state.snippet {
            var updated = snippet
            updated.trigger = trigger
            updated.expansion = expansion
            store.update(updated)
        } else {
            store.add(trigger: trigger, expansion: expansion)
        }
    }
}

struct SnippetEditorState: Identifiable {
    let id = UUID()
    var snippet: Snippet?

    init(snippet: Snippet? = nil) {
        self.snippet = snippet
    }
}

private struct SnippetEditorSheet: View {
    let state: SnippetEditorState
    var onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var trigger: String
    @State private var expansion: String

    init(state: SnippetEditorState, onSave: @escaping (String, String) -> Void) {
        self.state = state
        self.onSave = onSave
        _trigger = State(initialValue: state.snippet?.trigger ?? "")
        _expansion = State(initialValue: state.snippet?.expansion ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Trigger phrase — e.g. my email address", text: $trigger)
                    TextField("Expands to…", text: $expansion, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle(state.snippet == nil ? "Add snippet" : "Edit snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(trigger, expansion)
                        dismiss()
                    }
                    .disabled(
                        trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
    }
}
