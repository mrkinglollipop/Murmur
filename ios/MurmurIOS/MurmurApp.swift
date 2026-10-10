import SwiftUI
import UIKit

final class MurmurAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        let source = options[.sourceApplication] as? String ?? ""
        MurmurOpenURL.sourceApplication = source
        HandoffDiagnostics.record(
            "app.deeplink.uiapp",
            detail: "source=\(source.isEmpty ? "nil" : source)"
        )
        MurmurOpenURL.handle(url, sourceApplication: source)
        return true
    }
}

enum MurmurOpenURL {
    static var sourceApplication = ""

    @MainActor
    static func handle(_ url: URL, sourceApplication: String) {
        guard let request = DictationHandoff.request(from: url) else { return }
        HandoffDiagnostics.record("app.deeplink.received", detail: request.id)
        DictationController.shared.arm(
            id: request.id,
            hostBundleID: request.hostBundleID,
            hostPID: request.hostPID,
            keyboardStack: request.keyboardStack,
            sourceApplication: sourceApplication
        )
    }
}

@main
struct MurmurApp: App {
    @UIApplicationDelegateAdaptor(MurmurAppDelegate.self) private var appDelegate
    @ObservedObject private var session = DictationController.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppGroupStore.consumeGiphySeedIfNeeded()
        HandoffDiagnostics.record("app.initializing")
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                AppShellView()
                if session.isAwaitingHostReturn || session.isRecording || session.isBusy || session.isPaused {
                    SessionView()
                }
            }
            .onAppear {
                MurmurStores.dictionary.reload()
                session.restoreIfNeeded()
            }
            .onOpenURL { url in
                MurmurOpenURL.handle(url, sourceApplication: MurmurOpenURL.sourceApplication)
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    MurmurStores.dictionary.reload()
                    session.setForeground(true)
                    session.becomeActive()
                case .background:
                    session.setForeground(false)
                default:
                    break
                }
            }
        }
    }
}
