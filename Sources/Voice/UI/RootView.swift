import SwiftUI

extension Notification.Name {
    /// Posted to select a main-window tab. `userInfo["tab"]` is a `RootTab.rawValue` string.
    static let murmurSelectTab = Notification.Name("murmurSelectTab")
}

/// Which top-level view is showing in the main window.
enum RootTab: String, CaseIterable, Identifiable {
    case history
    case insights
    case dictionary
    case snippets
    case style
    case transforms
    case scratchpad
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: return "Recent activity"
        case .insights: return "Insights"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .style: return "Style"
        case .transforms: return "Transforms"
        case .scratchpad: return "Scratchpad"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .insights: return "chart.bar"
        case .dictionary: return "book.closed"
        case .snippets: return "scissors"
        case .style: return "textformat"
        case .transforms: return "wand.and.stars"
        case .scratchpad: return "note.text"
        case .settings: return "gearshape"
        }
    }
}

/// The main window's root content: a left sidebar (wordmark + History /
/// Dictionary nav, Settings pinned at bottom) beside a content area with a
/// large serif section header over the active view.
struct RootView: View {
    @ObservedObject var historyStore: HistoryStore
    @ObservedObject var dictionaryStore: DictionaryStore
    @ObservedObject var snippetsStore: SnippetsStore
    @ObservedObject var styleStore: StyleStore
    @ObservedObject var transformsStore: TransformsStore
    @ObservedObject var scratchpadStore: ScratchpadStore
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var modelManager: ModelManager

    /// Resolves the BYO cloud (OpenAI) key for Transforms' cloud fallback —
    /// wired by `AppDelegate`, forwarded straight through to `TransformsView`.
    var openAIKeyProvider: () -> String?

    /// Resolves the live ASR selector for History retry — wired by `AppDelegate`.
    var asrEngineSelector: () -> ASREngineSelector?

    /// Replays the first-launch onboarding flow — wired by `AppDelegate`.
    var onReplayOnboarding: () -> Void

    @State private var selectedTab: RootTab = .history
    @State private var showWhatsNew = false

    var body: some View {
        HStack(spacing: 0) {
            SidebarNav(selectedTab: $selectedTab)
            Divider().overlay(Theme.hairline)
            content
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: .murmurSelectTab)) { notification in
            guard let raw = notification.userInfo?["tab"] as? String,
                  let tab = RootTab(rawValue: raw) else { return }
            withAnimation(Theme.easeOutOrNil()) {
                selectedTab = tab
            }
        }
        .task {
            if WhatsNewStore.shouldPresent() {
                showWhatsNew = true
            }
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewSheetView(
                releases: WhatsNewStore.releasesToPresent(),
                onDismiss: {
                    WhatsNewStore.markSeen()
                    showWhatsNew = false
                }
            )
        }
    }

    /// The active view's content area: a large serif section header over the
    /// tab-appropriate view.
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(selectedTab.title)
                .font(Theme.serifTitle(26, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 12)

            Group {
                switch selectedTab {
                case .history:
                    HistoryView(
                        store: historyStore,
                        dictionaryStore: dictionaryStore,
                        asrEngineSelector: asrEngineSelector
                    )
                case .insights:
                    InsightsView(historyStore: historyStore, dictionaryStore: dictionaryStore)
                case .dictionary:
                    DictionaryView(store: dictionaryStore)
                case .snippets:
                    SnippetsView(store: snippetsStore)
                case .style:
                    StyleView(store: styleStore, settingsStore: settingsStore)
                case .transforms:
                    TransformsView(store: transformsStore, historyStore: historyStore, openAIKeyProvider: openAIKeyProvider)
                case .scratchpad:
                    ScratchpadView(store: scratchpadStore)
                case .settings:
                    SettingsView(
                        settingsStore: settingsStore,
                        modelManager: modelManager,
                        onReplayOnboarding: onReplayOnboarding
                    )
                }
            }
            .transition(.opacity)
            .animation(Theme.easeOutOrNil(), value: selectedTab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}
