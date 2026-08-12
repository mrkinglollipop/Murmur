import SwiftUI

@main
struct MurmurApp: App {
    @ObservedObject private var session = DictationController.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        HandoffDiagnostics.record("app.initializing")
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if session.isArmed {
                    SessionView()
                } else {
                    OnboardingView()
                }
            }
            .onAppear { session.restoreIfNeeded() }
            .onOpenURL { url in
                if let request = DictationHandoff.request(from: url) {
                    HandoffDiagnostics.record("app.deeplink.received", detail: request.id)
                    session.arm(
                        id: request.id,
                        hostBundleID: request.hostBundleID,
                        keyboardStack: request.keyboardStack
                    )
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    session.becomeActive()
                }
            }
        }
    }
}
