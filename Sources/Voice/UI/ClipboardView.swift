// PRO ONLY — this file is part of the paid clipboard manager and must never
// merge into `main`. Its target is the `pro` branch, gated behind a Pro
// entitlement check. See the "Clipboard manager" section of CLAUDE.md.

import AppKit
import SwiftUI

private let clipboardDayHeaderFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMMM d"
    return formatter
}()

private let clipboardTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
}()

/// Everything the user has copied, newest first — searchable, filterable by
/// kind, and restorable to the pasteboard with every representation intact.
///
/// Layout follows `plans/028-clipboard-mockup.html`; rows deliberately reuse
/// History's card shape so the two lists read as siblings.
struct ClipboardView: View {
    @ObservedObject var store: ClipboardStore

    @State private var searchText: String = ""
    @State private var kindFilter: KindFilter = .all
    @State private var copiedID: UUID?
    @State private var pendingDeleteEntry: ClipboardEntry?
    @State private var showDeleteConfirmation = false
    @State private var showClearAllConfirmation = false

    @FocusState private var isSearchFocused: Bool

    enum KindFilter: String, CaseIterable, Identifiable {
        case all, text, images, files
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .text: return "Text"
            case .images: return "Images"
            case .files: return "Files"
            }
        }

        func matches(_ entry: ClipboardEntry) -> Bool {
            switch self {
            case .all: return true
            case .text: return entry.kind == .text || entry.kind == .other
            case .images: return entry.kind == .image
            case .files: return entry.kind == .files
            }
        }
    }

    private var filteredEntries: [ClipboardEntry] {
        let byKind = store.entries.filter { kindFilter.matches($0) }
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return byKind }
        return byKind.filter {
            $0.preview.lowercased().contains(needle)
                || ($0.sourceBundleID.map { id in id.lowercased().contains(needle) } ?? false)
        }
    }

    /// `filteredEntries` bucketed by calendar day, newest day first. Same
    /// shape as `HistoryView.groupedEntries` — entries arrive newest-first, so
    /// first-seen day order is already correct.
    private var groupedEntries: [(day: Date, entries: [ClipboardEntry])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [ClipboardEntry]] = [:]

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
            if store.isKeyUnavailable {
                banner(
                    icon: "exclamationmark.triangle.fill",
                    tint: Theme.recordRed,
                    title: "Clipboard history is off",
                    message: "Murmur couldn't create an encryption key in your Keychain, so nothing is being saved. Your clipboard itself is unaffected."
                )
            } else if let skip = store.lastOversizedSkip {
                banner(
                    icon: "exclamationmark.circle.fill",
                    tint: Theme.amberBorder,
                    title: "One copy was too large to save",
                    message: "\(ByteCountFormatter.string(fromByteCount: Int64(skip.byteCount), countStyle: .file)) exceeds the \(ByteCountFormatter.string(fromByteCount: Int64(skip.limit), countStyle: .file)) limit, so it isn't in your history. It's still on your clipboard and can be pasted normally.",
                    actionTitle: "Dismiss",
                    action: { store.dismissOversizedSkip() }
                )
            } else if store.isLockedOut {
                banner(
                    icon: "lock.fill",
                    tint: Theme.amberBorder,
                    title: "History can't be opened",
                    message: "\(store.entries.count) items were encrypted with a key that isn't on this Mac — most likely restored from a backup or another machine. New copies are being saved normally.",
                    actionTitle: "Delete unreadable history",
                    action: { showClearAllConfirmation = true }
                )
            }

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    SearchBar(
                        text: $searchText,
                        placeholder: "Search clipboard",
                        resultCount: searchText.isEmpty ? nil : filteredEntries.count,
                        isFocused: $isSearchFocused
                    )
                    .frame(maxWidth: .infinity)

                    clearAllButton
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            filterChips
                .padding(.horizontal, 12)
                .padding(.top, 8)

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
            title: "Delete clipboard item?",
            onConfirm: {
                if let entry = pendingDeleteEntry {
                    withAnimation(Theme.easeOutOrNil()) { store.delete(entry) }
                }
                pendingDeleteEntry = nil
            }
        )
        .confirmDelete(
            isPresented: $showClearAllConfirmation,
            title: "Delete all clipboard history?",
            onConfirm: {
                withAnimation(Theme.easeOutOrNil()) { store.clearAll() }
            }
        )
    }

    // MARK: - Chrome

    private var clearAllButton: some View {
        Button {
            showClearAllConfirmation = true
        } label: {
            Text("Clear all")
                .font(Theme.body(12))
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 11)
                .frame(height: 28)
        }
        .buttonStyle(.plain)
        .murmurGlassCapsule()
        .disabled(store.entries.isEmpty)
        .opacity(store.entries.isEmpty ? 0.45 : 1)
        .help("Delete every saved clipboard item")
    }

    private var filterChips: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(KindFilter.allCases) { filter in
                    chip(for: filter)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func chip(for filter: KindFilter) -> some View {
        let isOn = kindFilter == filter
        let count = store.entries.filter { filter.matches($0) }.count
        return Button {
            withAnimation(Theme.easeOutOrNil()) { kindFilter = filter }
        } label: {
            HStack(spacing: 5) {
                Text(filter.title).font(Theme.body(12))
                Text("\(count)")
                    .font(Theme.body(11))
                    .opacity(0.65)
            }
            .foregroundColor(isOn ? Theme.lavenderText : Theme.textSecondary)
            .padding(.horizontal, 11)
            .frame(height: 26)
        }
        .buttonStyle(.plain)
        .murmurGlassCapsule(tint: isOn ? Theme.selectionTint : nil)
        .accessibilityLabel("\(filter.title), \(count) items")
    }

    private func banner(
        icon: String,
        tint: Color,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12))
                Text(title).font(Theme.body(13, weight: .semibold))
            }
            .foregroundColor(tint)

            Text(message)
                .font(Theme.body(12))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(Theme.body(12))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .murmurGlassCapsule()
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadiusCard)
                .stroke(tint.opacity(0.5), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusCard))
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6, pinnedViews: [.sectionHeaders]) {
                ForEach(groupedEntries, id: \.day) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            ClipboardRow(
                                entry: entry,
                                store: store,
                                isCopied: copiedID == entry.id,
                                onCopy: { copy(entry) },
                                onDelete: {
                                    pendingDeleteEntry = entry
                                    showDeleteConfirmation = true
                                }
                            )
                        }
                    } header: {
                        Text(clipboardDayHeaderFormatter.string(from: group.day))
                            .font(Theme.body(11))
                            .foregroundColor(Theme.textSecondary)
                            .textCase(.uppercase)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.bg)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
    }

    /// Reading a payload decrypts up to `maxItemBytes` on the calling thread,
    /// so the restore runs off the main thread and only the confirmation tick
    /// hops back.
    private func copy(_ entry: ClipboardEntry) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = store.copyToPasteboard(entry)
            DispatchQueue.main.async {
                guard ok else { return }
                copiedID = entry.id
                DispatchQueue.main.asyncAfter(deadline: .now() + Theme.copyConfirmSeconds) {
                    if copiedID == entry.id { copiedID = nil }
                }
            }
        }
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 26))
                .foregroundColor(Theme.primary.opacity(0.55))
            Text("Nothing copied yet")
                .font(Theme.body(13))
                .foregroundColor(Theme.textPrimary)
            Text("Anything you copy shows up here. Passwords and other concealed items are skipped.")
                .font(Theme.body(12))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        VStack(spacing: 6) {
            Text("No matches")
                .font(Theme.body(13))
                .foregroundColor(Theme.textPrimary)
            Text("Nothing in your clipboard history matches that filter.")
                .font(Theme.body(12))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One clipboard entry: kind icon or thumbnail, preview, source and time, with
/// copy/delete revealed on hover.
private struct ClipboardRow: View {
    let entry: ClipboardEntry
    let store: ClipboardStore
    let isCopied: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            leading

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.preview.isEmpty ? "(empty)" : entry.preview)
                    .font(entry.kind == .text ? Theme.body(13.5) : Theme.body(13.5, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 6) {
                    if let source = sourceName {
                        Text(source)
                        Text("·").opacity(0.45)
                    }
                    Text(clipboardTimeFormatter.string(from: entry.date))
                    Text("·").opacity(0.45)
                    Text(sizeLabel)
                }
                .font(Theme.body(11.5))
                .foregroundColor(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isHovering {
                HStack(spacing: 4) {
                    iconButton(
                        isCopied ? "checkmark" : "doc.on.doc",
                        tint: isCopied ? Theme.successGreen : Theme.textSecondary,
                        help: "Copy back to clipboard",
                        action: onCopy
                    )
                    iconButton("trash", tint: Theme.textSecondary, help: "Delete", action: onDelete)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .murmurGlassCard(cornerRadius: Theme.cornerRadiusCard)
        .onHover { hovering in
            withAnimation(Theme.easeOutOrNil(duration: 0.12)) { isHovering = hovering }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onCopy)
        .task(id: entry.id) { await loadThumbnail() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.kind.rawValue), \(entry.preview)")
    }

    @ViewBuilder
    private var leading: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 1)
                )
        } else {
            Image(systemName: iconName)
                .font(.system(size: 14))
                .foregroundColor(Theme.primary)
                .frame(width: 34, height: 34)
                .background(Theme.primary.opacity(0.13))
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusCompact))
        }
    }

    private func iconButton(
        _ systemName: String,
        tint: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11))
                .foregroundColor(tint)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .murmurGlassCard(cornerRadius: 6)
        .help(help)
    }

    /// Decrypts off the main thread — even a thumbnail read is file I/O plus
    /// an AES open, and this runs once per row as the list scrolls.
    private func loadThumbnail() async {
        guard entry.kind == .image else { return }
        let data: Data? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: store.thumbnail(for: entry))
            }
        }
        guard let data, let image = NSImage(data: data) else { return }
        thumbnail = image
    }

    private var iconName: String {
        switch entry.kind {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .files: return "doc"
        case .other: return "square.on.square"
        }
    }

    /// Bundle identifiers are noise in a list; show the last component, which
    /// is the app name often enough to be the better default.
    private var sourceName: String? {
        guard let bundleID = entry.sourceBundleID, !bundleID.isEmpty else { return nil }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: app.path)
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    private var sizeLabel: String {
        if entry.kind == .files {
            let count = entry.preview.split(separator: ",").count
            return count == 1 ? "1 file" : "\(count) files"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file)
    }
}

/// What a free user sees on the Clipboard tab: the pitch, not the feature.
/// Deliberately visible (Matt, 2026-08-24) — the locked tab IS the ad. No
/// history exists to protect here; the watcher never runs un-entitled.
struct ClipboardLockedView: View {
    @ObservedObject var authFlow: AuthFlowController

    @State private var showSignInSheet = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 30))
                .foregroundColor(Theme.primary.opacity(0.6))
                .padding(.bottom, 2)

            HStack(spacing: 7) {
                Text("Clipboard history")
                    .font(Theme.serifTitle(19, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                ProChip()
            }

            Text("Everything you copy — text, images, files — saved, searchable, and encrypted on this Mac. Passwords and other concealed items are never recorded.")
                .font(Theme.body(12.5))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            switch authFlow.state {
            case .signedIn:
                Text("Murmur Pro isn't active on this account yet.")
                    .font(Theme.body(12))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.top, 6)
            default:
                Button {
                    showSignInSheet = true
                } label: {
                    Text("Sign in to unlock")
                        .font(Theme.body(13, weight: .semibold))
                        .foregroundColor(Theme.lavenderText)
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                }
                .buttonStyle(.plain)
                .murmurGlassCapsule(tint: Theme.selectionTint)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showSignInSheet) {
            SignInSheetView(authFlow: authFlow, onDismiss: { showSignInSheet = false })
        }
    }
}
