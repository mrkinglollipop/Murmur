import SwiftUI
import AppKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Transform cards — name + description + "Run on last dictation" button —
/// plus create/edit/delete, matching Snippets' card/list style. MVP scope:
/// running a transform takes the most recent History entry's text, rewrites
/// it via `TransformRunner`, and copies the result to the clipboard with a
/// transient inline confirmation. No global hotkey, no arbitrary
/// focused-app selection — that's a future stretch (see build report).
struct TransformsView: View {
    @ObservedObject var store: TransformsStore
    @ObservedObject var historyStore: HistoryStore

    /// Resolves the BYO cloud (OpenAI) key for the cloud fallback path in
    /// `TransformRunner.run` — wired by `AppDelegate` to the same Keychain
    /// account cleanup uses, since a Transform run reuses cleanup's backend
    /// selection.
    var openAIKeyProvider: () -> String?

    @State private var searchText: String = ""
    @State private var isCreating = false
    @State private var newName: String = ""
    @State private var newPrompt: String = ""
    @State private var editingID: UUID?
    @State private var editName: String = ""
    @State private var editPrompt: String = ""
    @State private var pendingDeleteTransform: Transform?
    @State private var showDeleteConfirmation = false

    @FocusState private var focusedEditID: UUID?
    @FocusState private var isCreateNameFocused: Bool
    @FocusState private var isSearchFocused: Bool

    /// Transform id -> "running" / "copied" transient state, so each card's
    /// button can show its own feedback independent of the others.
    @State private var runState: [UUID: RunState] = [:]

    private enum RunState {
        case running
        case copied
        case failed(String)
    }

    private var lastDictationText: String? {
        historyStore.entries.first?.text
    }

    private var filteredTransforms: [Transform] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return store.transforms
        }
        let needle = searchText.lowercased()
        return store.transforms.filter { $0.name.lowercased().contains(needle) }
    }

    /// Whether a Transform can actually run right now — on-device model
    /// available, or a cloud key configured. Mirrors `TransformRunner`'s
    /// backend selection so the Run button is disabled up front rather than
    /// spinning and then failing with `.noBackendAvailable`.
    private var backendAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            return true
        }
        #endif
        if let key = openAIKeyProvider(), !key.isEmpty { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                autoRunSection

                if !store.transforms.isEmpty {
                    SearchBar(
                        text: $searchText,
                        placeholder: "Search transforms",
                        resultCount: searchText.isEmpty ? nil : filteredTransforms.count,
                        isFocused: $isSearchFocused
                    )
                }

                if isCreating {
                    creationForm
                } else {
                    newTransformButton
                }

                ForEach(filteredTransforms) { transform in
                    Group {
                        if editingID == transform.id {
                            editForm(for: transform)
                        } else {
                            card(for: transform)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if store.transforms.isEmpty && !isCreating {
                    emptyState
                }
            }
            .padding(16)
        }
        .confirmDelete(
            isPresented: $showDeleteConfirmation,
            title: "Delete transform?",
            onConfirm: {
                if let transform = pendingDeleteTransform {
                    withAnimation(Theme.easeOutOrNil()) {
                        store.delete(transform)
                    }
                }
                pendingDeleteTransform = nil
            }
        )
        .onChange(of: editingID) { _, newValue in
            focusedEditID = newValue
        }
    }

    // MARK: - Auto-run + hotkey

    private var autoRunSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Auto-run after dictation")
                .font(Theme.body(12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
                .textCase(.uppercase)

            Picker("Transform", selection: Binding(
                get: { store.autoRunTransformID },
                set: { store.autoRunTransformID = $0 }
            )) {
                Text("None").tag(Optional<UUID>.none)
                ForEach(store.transforms) { transform in
                    Text(transform.name).tag(Optional(transform.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            Text("Global hotkey: ⌃⌥⌘T runs the first transform on your last dictation and copies the result.")
                .font(Theme.body(10))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(14)
        .murmurGlassCard()
    }

    // MARK: - New transform

    private var newTransformButton: some View {
        Button {
            isCreating = true
            newName = ""
            newPrompt = ""
            isCreateNameFocused = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("Create new transform")
                    .font(Theme.body(13, weight: .semibold))
            }
            .foregroundColor(Theme.lavenderText)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.lavender)
    }

    private var creationForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name — e.g. Polish", text: $newName)
                .textFieldStyle(.plain)
                .font(Theme.body(13))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .murmurGlassCard()
                .focused($isCreateNameFocused)

            TextEditor(text: $newPrompt)
                .font(Theme.body(13))
                .frame(height: 70)
                .scrollContentBackground(.hidden)
                .padding(8)
                .murmurGlassCard()
                .overlay(alignment: .topLeading) {
                    if newPrompt.isEmpty {
                        Text("Instruction — e.g. Rewrite as a clear, well-structured LLM prompt")
                            .font(Theme.body(13))
                            .foregroundColor(Theme.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { isCreating = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)

                Button("Save") {
                    store.add(name: newName, prompt: newPrompt)
                    isCreating = false
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.lavender)
                .font(.system(size: 12, weight: .semibold))
                .disabled(
                    newName.trimmingCharacters(in: .whitespaces).isEmpty ||
                    newPrompt.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
        }
        .padding(14)
        .murmurGlassCard()
    }

    // MARK: - Card

    private func card(for transform: Transform) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(transform.name)
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    if let description = transform.description, !description.isEmpty {
                        Text(description)
                            .font(Theme.body(12))
                            .foregroundColor(Theme.textSecondary)
                    }
                }

                Spacer()

                Button {
                    beginEdit(transform)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Edit")
                .accessibilityLabel("Edit")

                Button {
                    pendingDeleteTransform = transform
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

            runButton(for: transform)
        }
        .contextMenu {
            Button("Run on last dictation") { run(transform) }
                .disabled(lastDictationText == nil || !backendAvailable || isRunning(transform))
            Button("Edit") { beginEdit(transform) }
            Button("Delete", role: .destructive) {
                pendingDeleteTransform = transform
                showDeleteConfirmation = true
            }
        }
        .padding(14)
        .murmurGlassCard()
    }

    private func runButton(for transform: Transform) -> some View {
        let disabledReason: String? = {
            if lastDictationText == nil { return "No dictation yet" }
            if !backendAvailable { return "No backend available" }
            return nil
        }()

        return HStack(spacing: 8) {
            Button {
                run(transform)
            } label: {
                HStack(spacing: 6) {
                    if case .running = runState[transform.id] {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                    }
                    Text(buttonLabel(for: transform))
                        .font(Theme.body(12, weight: .semibold))
                }
                .foregroundColor(Theme.lavenderText)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.lavender)
            .disabled(disabledReason != nil || isRunning(transform))

            if let disabledReason {
                Text(disabledReason)
                    .font(Theme.body(11))
                    .foregroundColor(Theme.textSecondary)
            } else if case .failed(let message) = runState[transform.id] {
                Text(message)
                    .font(Theme.body(11))
                    .foregroundColor(Theme.amberText)
            }
        }
    }

    private func buttonLabel(for transform: Transform) -> String {
        switch runState[transform.id] {
        case .running: return "Running…"
        case .copied:   return "Copied"
        default:        return "Run on last dictation"
        }
    }

    private func isRunning(_ transform: Transform) -> Bool {
        if case .running = runState[transform.id] { return true }
        return false
    }

    private func run(_ transform: Transform) {
        guard let text = lastDictationText else { return }
        runState[transform.id] = .running

        Task {
            do {
                let result = try await TransformRunner.run(
                    prompt: transform.prompt,
                    over: text,
                    openAIKey: openAIKeyProvider()
                )
                await MainActor.run {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(result, forType: .string)
                    runState[transform.id] = .copied
                }
                try? await Task.sleep(nanoseconds: UInt64(Theme.copyConfirmSeconds * 1_000_000_000))
                await MainActor.run {
                    if case .copied = runState[transform.id] {
                        runState[transform.id] = nil
                    }
                }
            } catch {
                await MainActor.run {
                    runState[transform.id] = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Edit

    private func editForm(for transform: Transform) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: $editName)
                .textFieldStyle(.plain)
                .font(Theme.body(13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .murmurGlassCard(cornerRadius: Theme.cornerRadiusCompact)
                .focused($focusedEditID, equals: transform.id)
                .onSubmit { saveEdit(for: transform) }

            TextEditor(text: $editPrompt)
                .font(Theme.body(13))
                .frame(height: 70)
                .scrollContentBackground(.hidden)
                .padding(8)
                .murmurGlassCard(cornerRadius: Theme.cornerRadiusCompact)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { cancelEdit() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .keyboardShortcut(.escape, modifiers: [])

                Button("Save") { saveEdit(for: transform) }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.lavender)
                    .font(.system(size: 12, weight: .semibold))
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(14)
        .murmurGlassCard()
        .onExitCommand { cancelEdit() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "wand.and.stars")
                .font(.system(size: 28))
                .foregroundColor(Theme.textSecondary)
            Text("No transforms yet")
                .font(Theme.body(13))
                .foregroundColor(Theme.textSecondary)
            Text("Create one to rewrite your last dictation")
                .font(Theme.body(12))
                .foregroundColor(Theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func beginEdit(_ transform: Transform) {
        editingID = transform.id
        editName = transform.name
        editPrompt = transform.prompt
        focusedEditID = transform.id
    }

    private func cancelEdit() {
        editingID = nil
        focusedEditID = nil
    }

    private func saveEdit(for transform: Transform) {
        var updated = transform
        updated.name = editName.trimmingCharacters(in: .whitespaces)
        updated.prompt = editPrompt.trimmingCharacters(in: .whitespaces)
        store.update(updated)
        editingID = nil
        focusedEditID = nil
    }
}
