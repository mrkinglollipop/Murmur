import UIKit

/// Best-effort host bundle ID. iOS exposes no public keyboard-host identity API.
enum HostAppProbe {
    /// KVC probe only — never invents Messages or falls back to lastHost.
    static func probedBundleID(from controller: UIInputViewController) -> String? {
        let objects: [NSObject] = [controller, controller.view, controller.extensionContext].compactMap { $0 }
        let names = ["hostBundleID", "hostBundleIdentifier", "_hostBundleID",
                     "_hostBundleIdentifier", "containingAppBundleID",
                     "parentBundleIdentifier", "hostAppBundleIdentifier"]
        for object in objects {
            for name in names {
                let selector = NSSelectorFromString(name)
                guard object.responds(to: selector),
                      let value = object.perform(selector)?.takeUnretainedValue() as? String,
                      value.contains("."), !value.hasPrefix("com.matt.murmur") else { continue }
                return value
            }
        }
        return nil
    }

    /// Probe this take only. lastHost is not a host identity.
    static func bundleID(from controller: UIInputViewController) -> String? {
        probedBundleID(from: controller)
    }

    /// Persist only a real probed host.
    static func remember(_ bundleID: String) {
        guard bundleID.contains("."), !bundleID.hasPrefix("com.matt.murmur") else { return }
        AppGroupStore.lastHostBundleID = bundleID
    }

    static func forget() {
        AppGroupStore.lastHostBundleID = ""
    }
}
