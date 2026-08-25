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
    @State private var menuOpen = false
    @State private var menuDrag: CGFloat = 0
    @State private var menuDragLocked: Bool?
    @State private var showSettings = false

    private let menuWidth: CGFloat = 280
    private let menuEdge: CGFloat = 32

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

            menuEdgeGrab
            menuLayer
        }
        .sheet(isPresented: $showSettings) {
            SettingsScreen()
        }
        .preferredColorScheme(.light)
    }

    private var menuReveal: CGFloat {
        let base: CGFloat = menuOpen ? menuWidth : 0
        return min(menuWidth, max(0, base + menuDrag))
    }

    private var header: some View {
        HStack {
            Button {
                setMenuOpen(true)
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

    /// Leading-edge pull to open. Stops short of the header (hamburger still
    /// tappable) and the tab bar.
    private var menuEdgeGrab: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: 52)
                    .allowsHitTesting(false)
                Color.clear
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .highPriorityGesture(menuPan)
                Color.clear
                    .frame(height: 86)
                    .allowsHitTesting(false)
            }
            .frame(width: menuEdge)
            Spacer(minLength: 0)
        }
        .allowsHitTesting(!menuOpen)
        .accessibilityHidden(true)
    }

    private var menuLayer: some View {
        let progress = menuReveal / menuWidth
        return ZStack(alignment: .leading) {
            Color.black.opacity(0.28 * progress)
                .ignoresSafeArea()
                .onTapGesture { setMenuOpen(false) }

            VStack(alignment: .leading, spacing: 20) {
                Text("Murmur")
                    .font(AppTheme.serif(28))
                    .foregroundStyle(AppTheme.ink)

                Spacer()

                Button {
                    setMenuOpen(false)
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .font(AppTheme.sans(17, weight: .medium))
                        .foregroundStyle(AppTheme.ink)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 8)
            .safeAreaPadding(.bottom)
            .frame(width: menuWidth, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(AppTheme.card.ignoresSafeArea())
            .offset(x: menuReveal - menuWidth)
            .accessibilityHidden(progress < 0.5)
        }
        .allowsHitTesting(menuOpen)
        .gesture(menuPan)
    }

    private var menuPan: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .onChanged { value in
                if menuDragLocked == nil {
                    let horizontal = abs(value.translation.width) >= abs(value.translation.height)
                    menuDragLocked = horizontal && (menuOpen || value.startLocation.x <= menuEdge)
                }
                guard menuDragLocked == true else { return }
                if menuOpen {
                    menuDrag = min(0, value.translation.width)
                } else {
                    menuDrag = max(0, value.translation.width)
                }
            }
            .onEnded { value in
                let tracked = menuDragLocked == true
                menuDragLocked = nil
                guard tracked else {
                    menuDrag = 0
                    return
                }
                let projected = menuReveal + value.velocity.width * 0.18
                setMenuOpen(projected > menuWidth * 0.45)
            }
    }

    private func setMenuOpen(_ open: Bool) {
        withAnimation(.easeOut(duration: 0.22)) {
            menuOpen = open
            menuDrag = 0
        }
    }
}
