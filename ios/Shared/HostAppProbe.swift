import Darwin
import UIKit

/// Best-effort host bundle ID. iOS exposes no public keyboard-host identity API.
enum HostAppProbe {
    static let messagesBundle = "com.apple.MobileSMS"

    /// KVC, SpringBoard frontmost, then Messages-composer inference.
    /// Never falls back to lastHost. Notes (Return key) stays empty → interstitial.
    static func probedBundleID(from controller: UIInputViewController) -> String? {
        if let id = sanitize(kvcBundleID(from: controller)) {
            HandoffDiagnostics.record("keyboard.host.probe", detail: "kvc=\(id)")
            return id
        }
        if let id = sanitize(sbsFrontmostBundleID()) {
            HandoffDiagnostics.record("keyboard.host.probe", detail: "sbs=\(id)")
            return id
        }
        if let id = sanitize(applicationFrontmostBundleID(from: controller)) {
            HandoffDiagnostics.record("keyboard.host.probe", detail: "uiapp=\(id)")
            return id
        }
        if let id = sanitize(workspaceFrontmostBundleID()) {
            HandoffDiagnostics.record("keyboard.host.probe", detail: "workspace=\(id)")
            return id
        }
        if looksLikeMessagesComposer(controller) {
            HandoffDiagnostics.record("keyboard.host.probe", detail: "inferred=\(messagesBundle)")
            return messagesBundle
        }
        HandoffDiagnostics.record("keyboard.host.probe", detail: "empty")
        return nil
    }

    static func bundleID(from controller: UIInputViewController) -> String? {
        probedBundleID(from: controller)
    }

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

    /// Messages uses Send. Notes uses Return. Do not treat email/URL pads as Messages.
    private static func looksLikeMessagesComposer(_ controller: UIInputViewController) -> Bool {
        let proxy = controller.textDocumentProxy
        guard proxy.returnKeyType == .send else { return false }
        switch proxy.keyboardType {
        case .emailAddress, .URL, .webSearch, .phonePad, .numberPad,
             .decimalPad, .asciiCapableNumberPad:
            return false
        default:
            return true
        }
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

    private static func sbsFrontmostBundleID() -> String? {
        let path = "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices"
        guard let handle = dlopen(path, RTLD_NOW) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SBSCopyFrontmostApplicationDisplayIdentifier") else { return nil }
        typealias CopyFn = @convention(c) () -> Unmanaged<CFString>?
        let fn = unsafeBitCast(symbol, to: CopyFn.self)
        return fn()?.takeRetainedValue() as String?
    }

    private static func applicationFrontmostBundleID(from controller: UIInputViewController) -> String? {
        var responder: UIResponder? = controller
        while let current = responder {
            if let application = current as? UIApplication {
                let selector = NSSelectorFromString("_accessibilityFrontMostApplication")
                if application.responds(to: selector),
                   let app = application.perform(selector)?.takeUnretainedValue() as? NSObject {
                    for key in ["bundleIdentifier", "displayIdentifier", "applicationIdentifier"] {
                        let idSelector = NSSelectorFromString(key)
                        if app.responds(to: idSelector),
                           let value = app.perform(idSelector)?.takeUnretainedValue() as? String {
                            return value
                        }
                    }
                }
            }
            responder = current.next
        }
        return nil
    }

    private static func workspaceFrontmostBundleID() -> String? {
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
