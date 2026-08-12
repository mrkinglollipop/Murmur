import UIKit

/// Best-effort host bundle ID. iOS exposes no public keyboard-host identity API.
enum HostAppProbe {
    /// KVC first, then the frontmost app from `LSApplicationWorkspace`.
    /// Never invents Messages or falls back to lastHost.
    static func probedBundleID(from controller: UIInputViewController) -> String? {
        if let id = sanitize(kvcBundleID(from: controller)) {
            HandoffDiagnostics.record("keyboard.host.probe", detail: "kvc=\(id)")
            return id
        }
        if let id = sanitize(frontmostBundleID()) {
            HandoffDiagnostics.record("keyboard.host.probe", detail: "frontmost=\(id)")
            return id
        }
        HandoffDiagnostics.record("keyboard.host.probe", detail: "empty")
        return nil
    }

    /// Probe this take only. lastHost is not a host identity.
    static func bundleID(from controller: UIInputViewController) -> String? {
        probedBundleID(from: controller)
    }

    /// Persist only a real probed host.
    static func remember(_ bundleID: String) {
        guard sanitize(bundleID) != nil else { return }
        AppGroupStore.lastHostBundleID = bundleID
    }

    static func forget() {
        AppGroupStore.lastHostBundleID = ""
    }

    private static func sanitize(_ value: String?) -> String? {
        guard let value, value.contains(".") else { return nil }
        if value.hasPrefix("com.matt.murmur") { return nil }
        if value.hasPrefix("com.apple.springboard") { return nil }
        if value.contains("keyboard-service") { return nil }
        return value
    }

    private static func kvcBundleID(from controller: UIInputViewController) -> String? {
        var objects: [NSObject] = [controller, controller.view]
        if let context = controller.extensionContext { objects.append(context) }
        if let proxy = controller.textDocumentProxy as? NSObject { objects.append(proxy) }
        if let window = controller.view.window { objects.append(window) }
        let names = [
            "hostBundleID", "hostBundleIdentifier", "_hostBundleID",
            "_hostBundleIdentifier", "containingAppBundleID",
            "parentBundleIdentifier", "hostAppBundleIdentifier",
            "clientBundleIdentifier", "_clientBundleIdentifier",
            "targetBundleID", "_targetBundleID"
        ]
        for object in objects {
            for name in names {
                let selector = NSSelectorFromString(name)
                guard object.responds(to: selector),
                      let value = object.perform(selector)?.takeUnretainedValue() as? String
                else { continue }
                if let id = sanitize(value) { return id }
            }
        }
        return nil
    }

    /// Sideload-only. The keyboard overlays the host, so frontmost is often Notes/Messages.
    private static func frontmostBundleID() -> String? {
        let defaultSelector = NSSelectorFromString("defaultWorkspace")
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              workspaceClass.responds(to: defaultSelector),
              let workspace = workspaceClass.perform(defaultSelector)?.takeUnretainedValue() as? NSObject
        else { return nil }
        let getters = ["frontmostApplicationProxy", "frontmostApplication", "currentApplication"]
        let idKeys = ["bundleIdentifier", "applicationIdentifier", "bundleID"]
        for getter in getters {
            let selector = NSSelectorFromString(getter)
            guard workspace.responds(to: selector),
                  let app = workspace.perform(selector)?.takeUnretainedValue() as? NSObject
            else { continue }
            for key in idKeys {
                let idSelector = NSSelectorFromString(key)
                guard app.responds(to: idSelector),
                      let value = app.perform(idSelector)?.takeUnretainedValue() as? String
                else { continue }
                if let id = sanitize(value) { return id }
            }
        }
        return nil
    }
}
