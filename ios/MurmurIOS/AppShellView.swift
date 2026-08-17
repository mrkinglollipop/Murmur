import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case home
    case dictionary
    case snippets
    case style
    case scratchpad

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .style: return "Style"
        case .scratchpad: return "Scratchpad"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .dictionary: return "book.closed"
        case .snippets: return "scissors"
        case .style: return "textformat.size"
        case .scratchpad: return "note.text"
        }
    }
}

struct AppShellView: View {
    @ObservedObject private var session = DictationController.shared
    @State private var tab: AppTab = .home
    @State private var showMenu = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                tabBody
            }
            .padding(.bottom, 78)

            VStack {
                Spacer()
                tabBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if showMenu {
                menuScrim
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsScreen()
        }
        .preferredColorScheme(.light)
    }

    private var header: some View {
        HStack {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { showMenu = true }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.ink)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Menu")

            Spacer()

            Text(tab == .home ? "Murmur" : tab.title)
                .font(AppTheme.sans(17, weight: .semibold))
                .foregroundStyle(AppTheme.ink)

            Spacer()

            if tab == .home {
                Toggle(
                    "Murmur is on",
                    isOn: Binding(
                        get: { session.isArmed },
                        set: { session.setSessionEnabled($0) }
                    )
                )
                .labelsHidden()
                .tint(AppTheme.coral)
                .frame(width: 52)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var tabBody: some View {
        switch tab {
        case .home:
            HomeView(onOpenSettings: { showSettings = true }, settingsOpen: showSettings)
        case .dictionary:
            DictionaryScreen()
        case .snippets:
            SnippetsScreen()
        case .style:
            StyleScreen()
        case .scratchpad:
            ScratchpadScreen()
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 18, weight: item == tab ? .semibold : .regular))
                        Text(item.title)
                            .font(AppTheme.sans(10, weight: item == tab ? .semibold : .regular))
                    }
                    .foregroundStyle(item == tab ? AppTheme.coral : AppTheme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(item == tab ? AppTheme.coral.opacity(0.14) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(item == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(AppTheme.card)
                .shadow(color: Color.black.opacity(0.08), radius: 16, y: 4)
        )
    }

    private var menuScrim: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) { showMenu = false }
                }

            VStack(alignment: .leading, spacing: 20) {
                Text("Murmur")
                    .font(AppTheme.serif(28))
                    .foregroundStyle(AppTheme.ink)

                Button {
                    showMenu = false
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .font(AppTheme.sans(17, weight: .medium))
                        .foregroundStyle(AppTheme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel("Settings")

                Spacer()
            }
            .padding(24)
            .frame(width: 280, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(AppTheme.card.ignoresSafeArea())
        }
    }
}
