import UIKit

/// Returns to the keyboard host after the containing app activates the microphone.
/// LSApplicationWorkspace is private API, used here for sideload testing.
@MainActor
enum HostReturn {
    static let messagesBundle = "com.apple.MobileSMS"

    static func bounceBack(keyboardStack: Bool, hostBundleID: String?) {
        let host = resolvedHost(hostBundleID)
        HandoffDiagnostics.record("app.return.requested", detail: "host=\(host) stack=\(keyboardStack)")
        AppGroupStore.lastHostBundleID = host
        openWorkspace(host)
    }

    private static func resolvedHost(_ bundleID: String?) -> String {
        if let bundleID, !bundleID.isEmpty { return bundleID }
        let last = AppGroupStore.lastHostBundleID
        return last.isEmpty ? messagesBundle : last
    }

    private static func openWorkspace(_ bundleID: String) {
        let defaultSelector = NSSelectorFromString("defaultWorkspace")
        let openSelector = NSSelectorFromString(
            "openApplicationWithBundleIdentifier:configuration:completionHandler:"
        )
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              workspaceClass.responds(to: defaultSelector),
              let workspace = workspaceClass.perform(defaultSelector)?.takeUnretainedValue() as? NSObject,
              workspace.responds(to: openSelector) else {
            HandoffDiagnostics.record("app.return.workspaceUnavailable", detail: bundleID)
            openScheme(bundleID, reason: "workspace unavailable")
            return
        }
        typealias Completion = @convention(block) (Bool, NSError?) -> Void
        typealias OpenApplication = @convention(c) (
            AnyObject, Selector, NSString, AnyObject?, Completion
        ) -> Void
        let startedAt = Date.now.timeIntervalSince1970
        let fallbackTask = Task { @MainActor in
            try await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            HandoffDiagnostics.record("app.return.workspace.timeout", detail: bundleID)
            openScheme(bundleID, reason: "workspace timeout")
        }
        let completion: Completion = { opened, error in
            let elapsed = Date.now.timeIntervalSince1970 - startedAt
            let detail = "\(bundleID) opened=\(opened) elapsed=\(elapsed) error=\(error?.localizedDescription ?? "none")"
            Task { @MainActor in
                fallbackTask.cancel()
                HandoffDiagnostics.record("app.return.workspace.completed", detail: detail)
                if !opened { openScheme(bundleID, reason: "workspace rejected") }
            }
        }
        let function = unsafeBitCast(workspace.method(for: openSelector), to: OpenApplication.self)
        HandoffDiagnostics.record("app.return.workspace.dispatched", detail: bundleID)
        function(workspace, openSelector, bundleID as NSString, nil, completion)
    }

    private static func openScheme(_ bundleID: String, reason: String) {
        guard let url = schemeURL(for: bundleID) else {
            HandoffDiagnostics.record("app.return.noFallback", detail: "\(bundleID) reason=\(reason)")
            return
        }
        HandoffDiagnostics.record(
            "app.return.scheme.requested",
            detail: "\(url.absoluteString) reason=\(reason)"
        )
        UIApplication.shared.open(url, options: [:]) { opened in
            HandoffDiagnostics.record("app.return.scheme.completed", detail: String(opened))
        }
    }

    private static func schemeURL(for bundleID: String) -> URL? {
        let schemes = [
            "com.apple.MobileSMS": "sms:",
            "com.apple.mobilenotes": "mobilenotes://",
            "com.apple.mail": "message://",
            "com.apple.mobilemail": "message://"
        ]
        guard let value = schemes[bundleID] else { return nil }
        return URL(string: value)
    }
}
