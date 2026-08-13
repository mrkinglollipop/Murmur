import SwiftUI
import UIKit

struct DictionaryScreen: View {
    @ObservedObject private var store = MurmurStores.dictionary
    @State private var showIntro = !AppGroupStore.introDismissed(AppGroupStore.dictionaryIntroKey)
    @State private var editor: DictionaryEditorState?
    @State private var pendingDelete: DictionaryEntry?

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
            DictionaryEditorSheet(state: state) { term, variants in
                save(state: state, term: term, variants: variants)
            }
        }
        .confirmationDialog("Delete dictionary term?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let entry = pendingDelete {
                    forgetKeyboardWord(entry.term)
                    store.delete(entry)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text("Murmur speaks the way you speak")
                    .font(AppTheme.serif(26))
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Button {
                    AppGroupStore.dismissIntro(AppGroupStore.dictionaryIntroKey)
                    showIntro = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.muted)
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Dismiss")
            }
            Text("Corrections for personal terms, company jargon, industry lingo. Same dictionary as Mac Murmur. On the keyboard: type a new word, then tap the quoted spelling in the suggestion bar — Apple’s learn gesture.")
                .font(AppTheme.sans(15))
                .foregroundStyle(AppTheme.muted)
            Button("Add new word") {
                editor = DictionaryEditorState()
            }
            .buttonStyle(CoralWideButtonStyle())
        }
        .padding(20)
        .background(AppTheme.hero, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
    }

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your words (\(store.entries.count))")
                .font(AppTheme.sans(13, weight: .medium))
                .foregroundStyle(AppTheme.muted)

            if store.entries.isEmpty {
                Text("No words yet. Add a term and the misheard variants Murmur should fix.")
                    .font(AppTheme.sans(15))
                    .foregroundStyle(AppTheme.muted)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.card, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
                        Button {
                            editor = DictionaryEditorState(entry: entry)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.term)
                                        .font(AppTheme.sans(16, weight: .medium))
                                        .foregroundStyle(AppTheme.ink)
                                    if !entry.variants.isEmpty {
                                        Text(entry.variants.joined(separator: ", "))
                                            .font(AppTheme.sans(13))
                                            .foregroundStyle(AppTheme.muted)
                                            .lineLimit(1)
                                    } else if entry.isAutoLearned {
                                        Text("From the keyboard")
                                            .font(AppTheme.sans(13))
                                            .foregroundStyle(AppTheme.muted)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                pendingDelete = entry
                            }
                        }
                        if index < store.entries.count - 1 {
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
            editor = DictionaryEditorState()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(AppTheme.coral))
                .shadow(color: AppTheme.coral.opacity(0.35), radius: 8, y: 3)
        }
        .accessibilityLabel("Add new word")
    }

    private func save(state: DictionaryEditorState, term: String, variants: [String]) {
        if let entry = state.entry {
            if entry.term.lowercased() != term.lowercased() {
                forgetKeyboardWord(entry.term)
            }
            var updated = entry
            updated.term = term
            updated.variants = variants
            store.update(updated)
        } else {
            store.add(term: term, variants: variants)
        }
    }

    private func forgetKeyboardWord(_ term: String) {
        LearnedWordStore.unlearn(term)
        UITextChecker.unlearnWord(term)
    }
}

struct DictionaryEditorState: Identifiable {
    let id = UUID()
    var entry: DictionaryEntry?

    init(entry: DictionaryEntry? = nil) {
        self.entry = entry
    }
}

private struct DictionaryEditorSheet: View {
    let state: DictionaryEditorState
    var onSave: (String, [String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var term: String
    @State private var variantsText: String

    init(state: DictionaryEditorState, onSave: @escaping (String, [String]) -> Void) {
        self.state = state
        self.onSave = onSave
        _term = State(initialValue: state.entry?.term ?? "")
        _variantsText = State(initialValue: state.entry?.variants.joined(separator: ", ") ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Correct spelling — e.g. Kubernetes", text: $term)
                    TextField("Misheard variants, comma-separated", text: $variantsText, axis: .vertical)
                        .lineLimit(2...4)
                } footer: {
                    Text("When you say a variant, Murmur inserts the correct spelling.")
                }
            }
            .navigationTitle(state.entry == nil ? "Add word" : "Edit word")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let variants = variantsText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        onSave(term, variants)
                        dismiss()
                    }
                    .disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct CoralWideButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTheme.sans(16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.coral.opacity(configuration.isPressed ? 0.85 : 1))
            )
    }
}
