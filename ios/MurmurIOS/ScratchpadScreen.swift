import SwiftUI

struct ScratchpadScreen: View {
    @ObservedObject private var store = MurmurStores.scratchpad
    @State private var editing: IdentifiedUUID?
    @State private var pendingDelete: UUID?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if store.notes.isEmpty {
                    Text("Notes you jot here stay on this phone.")
                        .font(AppTheme.sans(15))
                        .foregroundStyle(AppTheme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(20)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(grouped, id: \.day) { group in
                                Text(group.day)
                                    .font(AppTheme.sans(13, weight: .medium))
                                    .foregroundStyle(AppTheme.muted)
                                    .padding(.horizontal, 4)
                                ForEach(group.notes) { note in
                                    Button {
                                        editing = IdentifiedUUID(id: note.id)
                                    } label: {
                                        noteCard(note)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("Delete", role: .destructive) {
                                            pendingDelete = note.id
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 88)
                    }
                }
            }

            Button {
                editing = IdentifiedUUID(id: store.newNote().id)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(AppTheme.coral))
                    .shadow(color: AppTheme.coral.opacity(0.35), radius: 8, y: 3)
            }
            .accessibilityLabel("New note")
            .padding(.trailing, 22)
            .padding(.bottom, 12)
        }
        .sheet(item: $editing) { item in
            ScratchpadEditor(noteID: item.id)
        }
        .confirmationDialog("Delete note?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = pendingDelete {
                    store.delete(id: id)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    private var grouped: [(day: String, notes: [ScratchpadNote])] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let groups = Dictionary(grouping: store.notes) { formatter.string(from: $0.updatedAt) }
        return groups.keys.sorted { lhs, rhs in
            let left = groups[lhs]?.first?.updatedAt ?? .distantPast
            let right = groups[rhs]?.first?.updatedAt ?? .distantPast
            return left > right
        }.map { day in
            (day, groups[day] ?? [])
        }
    }

    private func noteCard(_ note: ScratchpadNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note.title.isEmpty ? "Untitled" : note.title)
                .font(AppTheme.sans(17, weight: .semibold))
                .foregroundStyle(AppTheme.ink)
            if !note.body.isEmpty {
                Text(note.body)
                    .font(AppTheme.sans(15))
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(3)
            }
            Text(note.updatedAt, format: .dateTime.hour().minute())
                .font(AppTheme.sans(13))
                .foregroundStyle(AppTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
    }
}

private struct IdentifiedUUID: Identifiable {
    let id: UUID
}

private struct ScratchpadEditor: View {
    let noteID: UUID
    @ObservedObject private var store = MurmurStores.scratchpad
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var bodyText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Title", text: $title)
                    .font(AppTheme.sans(22, weight: .semibold))
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                TextEditor(text: $bodyText)
                    .font(AppTheme.sans(17))
                    .padding(.horizontal, 16)
                    .scrollContentBackground(.hidden)
            }
            .background(AppTheme.bg)
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if let note = store.notes.first(where: { $0.id == noteID }) {
                    title = note.title
                    bodyText = note.body
                }
            }
            .onChange(of: title) { _, value in
                store.update(id: noteID, title: value, body: bodyText)
            }
            .onChange(of: bodyText) { _, value in
                store.update(id: noteID, title: title, body: value)
            }
            .onDisappear {
                store.flush()
            }
        }
        .preferredColorScheme(.light)
    }
}
