import AppIntents

/// Action Button / Spotlight / Shortcuts: opens Murmur and starts a take.
struct StartDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Dictation"
    static var description = IntentDescription(
        "Opens Murmur and starts listening. Stop in the app to copy the transcript."
    )
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DictationController.shared.startFromActionButton()
        return .result()
    }
}

struct MurmurShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: [
                "Start dictation with \(.applicationName)",
                "Dictate with \(.applicationName)"
            ],
            shortTitle: "Start Dictation",
            systemImageName: "mic.fill"
        )
    }
}
