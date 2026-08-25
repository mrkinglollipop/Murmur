import SwiftUI
import UIKit

/// Home-screen-style icon grid for jump-back apps. Edit mode adds / removes /
/// drag-reorders; pick mode just launches.
struct JumpBackAppGrid: View {
    let bundleIDs: [String]
    var showsAdd: Bool = false
    var showsRemove: Bool = false
    var allowsReorder: Bool = false
    var onSelect: ((String) -> Void)?
    var onAdd: (() -> Void)?
    var onRemove: ((String) -> Void)?
    var onReorder: ((String, String) -> Void)?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
    private let iconSize: CGFloat = 56

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(bundleIDs, id: \.self) { id in
                tile(for: id)
            }
            if showsAdd {
                addTile
            }
        }
        .onAppear {
            let ids = bundleIDs
            Task { @MainActor in
                await InstalledAppLookup.prefetchArtwork(for: ids)
            }
        }
    }

    @ViewBuilder
    private func tile(for bundleID: String) -> some View {
        let app = InstalledAppLookup.presentation(for: bundleID)
        let title = app.name
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                JumpBackAppIcon(app: app, size: iconSize)
                if showsRemove {
                    Button {
                        onRemove?(bundleID)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.red)
                            .font(.system(size: 18))
                            .offset(x: 6, y: -6)
                    }
                    .accessibilityLabel("Remove \(title)")
                }
            }
            Text(title)
                .font(AppTheme.sans(11, weight: .medium))
                .foregroundStyle(AppTheme.ink)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !showsRemove {
                onSelect?(bundleID)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(showsRemove ? [] : .isButton)
        .accessibilityHint(allowsReorder ? "Drag to rearrange" : "Returns to \(title)")
        .modifier(JumpBackReorderModifier(
            bundleID: bundleID,
            enabled: allowsReorder,
            onReorder: onReorder
        ))
        .accessibilityAction(named: "Move left") {
            move(bundleID, by: -1)
        }
        .accessibilityAction(named: "Move right") {
            move(bundleID, by: 1)
        }
    }

    private var addTile: some View {
        Button(action: { onAdd?() }) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: iconSize * 0.2237, style: .continuous)
                        .fill(Color(white: 0.94))
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(AppTheme.coral)
                }
                .frame(width: iconSize, height: iconSize)
                Text("Add")
                    .font(AppTheme.sans(11, weight: .medium))
                    .foregroundStyle(AppTheme.coral)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityLabel("Add app")
    }

    private func move(_ bundleID: String, by delta: Int) {
        guard let from = bundleIDs.firstIndex(of: bundleID) else { return }
        let to = from + delta
        guard bundleIDs.indices.contains(to) else { return }
        onReorder?(bundleID, bundleIDs[to])
    }
}

private struct JumpBackReorderModifier: ViewModifier {
    let bundleID: String
    let enabled: Bool
    var onReorder: ((String, String) -> Void)?

    func body(content: Content) -> some View {
        Group {
            if enabled {
                content
                    .draggable(bundleID)
                    .dropDestination(for: String.self) { items, _ in
                        guard let moving = items.first, moving != bundleID else { return false }
                        onReorder?(moving, bundleID)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        return true
                    }
            } else {
                content
            }
        }
    }
}

private struct JumpBackAppIcon: View {
    let app: InstalledApp
    var size: CGFloat
    @State private var loaded: UIImage?

    var body: some View {
        let radius = size * 0.2237
        let image = loaded ?? app.icon
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color(white: 0.92))
                    Image(systemName: ReturnAppCatalog.displaySymbol(for: app.bundleID))
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(AppTheme.ink)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
        )
        .onAppear {
            if loaded == nil {
                loaded = app.icon
            }
            let id = app.bundleID
            Task { @MainActor in
                if let image = await InstalledAppLookup.artwork(for: id) {
                    loaded = image
                }
            }
        }
    }
}

struct AddJumpBackAppSheet: View {
    let alreadyPicked: Set<String>
    var onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var apps: [InstalledApp] = []
    @State private var storeApps: [InstalledApp] = []
    @State private var loading = true
    @State private var searchTask: Task<Void, Never>?

    private var filtered: [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = apps.filter { !alreadyPicked.contains($0.bundleID) }
        if !q.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(q)
                    || $0.bundleID.localizedCaseInsensitiveContains(q)
            }
            for app in storeApps where !alreadyPicked.contains(app.bundleID) {
                if !list.contains(where: { $0.bundleID == app.bundleID }) {
                    list.append(app)
                }
            }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Loading apps…")
                        .font(AppTheme.sans(15))
                        .foregroundStyle(AppTheme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if filtered.isEmpty {
                            Text(
                                query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? "Search by name to add any app on your phone."
                                    : "No apps matched that name."
                            )
                            .font(AppTheme.sans(14))
                            .foregroundStyle(AppTheme.muted)
                        }
                        ForEach(filtered) { app in
                            Button {
                                InstalledAppLookup.remember(app)
                                onPick(app.bundleID)
                            } label: {
                                HStack(spacing: 12) {
                                    JumpBackAppIcon(app: app, size: 40)
                                    Text(app.name)
                                        .font(AppTheme.sans(16, weight: .semibold))
                                        .foregroundStyle(AppTheme.ink)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search any app by name")
            .navigationTitle("Add app")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                loading = true
                InstalledAppLookup.refresh()
                apps = InstalledAppLookup.all()
                loading = false
            }
            .onChange(of: query) { _, newValue in
                searchTask?.cancel()
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 2 else {
                    storeApps = []
                    return
                }
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(280))
                    guard !Task.isCancelled else { return }
                    let hits = await InstalledAppLookup.searchAppStore(trimmed)
                    guard !Task.isCancelled else { return }
                    storeApps = hits
                }
            }
        }
        .preferredColorScheme(.light)
    }
}
