import UIKit

/// Best-effort host bundle ID. iOS exposes no public keyboard-host identity API.
enum HostAppProbe {
    static func bundleID(from controller: UIInputViewController) -> String? {
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
        let last = AppGroupStore.lastHostBundleID
        return last.isEmpty ? nil : last
    }

    static func remember(_ bundleID: String) {
        guard bundleID.contains("."), !bundleID.hasPrefix("com.matt.murmur") else { return }
        AppGroupStore.lastHostBundleID = bundleID
    }
}
