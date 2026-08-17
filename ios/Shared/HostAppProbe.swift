import Darwin
import ObjectiveC
import UIKit

/// Best-effort host bundle ID. iOS exposes no public keyboard-host identity API.
enum HostAppProbe {
    static let messagesBundle = HostFingerprint.messagesBundle

    /// KVC / ivars / host PID, SpringBoard, ChatKit fingerprint, then Send-key.
    /// Never falls back to lastHost. Unknown hosts stay empty → interstitial.
    static func probedBundleID(from controller: UIInputViewController) -> String? {
        let fingerprint = fingerprintSummary(from: controller)
        let objects = identityObjects(from: controller)
        let scan = HostIvarScanner.scan(objects)
        if let id = sanitize(kvcBundleID(from: controller)) {
            HandoffDiagnostics.record("keyboard.host.probe", detail: "kvc=\(id) \(fingerprint)")
            return id
        }
        if let id = scan.bundleIDs.compactMap(sanitize).first {
            HandoffDiagnostics.record("keyboard.host.probe", detail: "ivar=\(id) \(fingerprint)")
            return id
        }
        if let id = scan.connections.compactMap({ signingIdentifier(from: $0) }).compactMap(sanitize).first {
            HandoffDiagnostics.record("keyboard.host.probe", detail: "xpc-sign=\(id) \(fingerprint)")
            return id
        }
        for pid in scan.pids {
            if let id = bundleID(forPID: pid) {
                HandoffDiagnostics.record(
                    "keyboard.host.probe",
                    detail: "ivarpid=\(pid) id=\(id) \(fingerprint)"
                )
                return id
            }
        }
        if let pid = hostPID(from: controller),
           let id = bundleID(forPID: pid) {
            HandoffDiagnostics.record(
                "keyboard.host.probe",
                detail: "hostPID=\(pid) sbs=\(id) \(fingerprint)"
            )
            return id
        }
        if let id = sanitize(sbsFrontmostBundleID()) {
            HandoffDiagnostics.record("keyboard.host.probe", detail: "sbs=\(id) \(fingerprint)")
            return id
        }
        if let id = sanitize(applicationFrontmostBundleID(from: controller)) {
            HandoffDiagnostics.record("keyboard.host.probe", detail: "uiapp=\(id) \(fingerprint)")
            return id
        }
        if let id = sanitize(workspaceFrontmostBundleID()) {
            HandoffDiagnostics.record("keyboard.host.probe", detail: "workspace=\(id) \(fingerprint)")
            return id
        }
        if let id = sanitize(HostFingerprint.bundleID(fromClassNames: collectClassNames(from: controller))) {
            HandoffDiagnostics.record("keyboard.host.probe", detail: "class=\(id) \(fingerprint)")
            return id
        }
        if let id = sanitize(processPathBundleID()) {
            HandoffDiagnostics.record("keyboard.host.probe", detail: "proc=\(id) \(fingerprint)")
            return id
        }
        if looksLikeMessagesComposer(controller) {
            HandoffDiagnostics.record(
                "keyboard.host.probe",
                detail: "inferred=\(messagesBundle) \(fingerprint)"
            )
            return messagesBundle
        }
        recordEmptyProbe(fingerprint: fingerprint, scan: scan)
        return nil
    }

    static func discoveredPIDs(from controller: UIInputViewController) -> [pid_t] {
        HostIvarScanner.scan(identityObjects(from: controller)).pids
    }

    static func bundleID(forPID pid: pid_t) -> String? {
        guard pid > 1 else { return nil }
        var parts = ["pid=\(pid)"]
        if let selfPID = springBoardPID(forBundleID: "com.matt.murmur.ios") {
            parts.append("selfSBS=\(selfPID)==\(getpid())")
        } else {
            parts.append("selfSBS=nil")
        }
        if let id = bundleIDMatchingSpringBoardPID(pid) {
            parts.append("match=\(id)")
            HandoffDiagnostics.record("host.pidLookup", detail: parts.joined(separator: " ") + " via=sbs-pid-match")
            return id
        }
        parts.append("match=nil")
        if let id = codeSigningBundleID(forPID: pid) {
            parts.append("cs=\(id)")
            HandoffDiagnostics.record("host.pidLookup", detail: parts.joined(separator: " ") + " via=csops")
            return id
        }
        parts.append("cs=nil")
        let table = kernelCommTable()
        parts.append("kall=\(table.count)")
        if let comm = kernelComm(pid: pid) ?? table[pid] {
            parts.append("comm=\(comm)")
            if let id = sanitize(HostFingerprint.bundleID(fromProcessPath: comm)) {
                HandoffDiagnostics.record("host.pidLookup", detail: parts.joined(separator: " ") + " via=kinfo")
                return id
            }
        } else {
            parts.append("comm=nil")
        }
        if let raw = sbsBundleID(forPID: pid) {
            parts.append("sbsRaw=\(raw)")
            if let id = sanitize(raw) ?? sanitize(HostFingerprint.bundleID(fromProcessPath: raw)) {
                HandoffDiagnostics.record("host.pidLookup", detail: parts.joined(separator: " ") + " via=sbs")
                return id
            }
        } else {
            parts.append("sbsRaw=nil")
        }
        if let name = processName(pid: pid) ?? shortBSDName(pid: pid) {
            parts.append("name=\(name)")
            if let id = sanitize(HostFingerprint.bundleID(fromProcessPath: name)) {
                HandoffDiagnostics.record("host.pidLookup", detail: parts.joined(separator: " ") + " via=name")
                return id
            }
        } else {
            parts.append("name=nil")
        }
        if let path = processArgsPath(pid: pid) ?? processPath(pid: pid) {
            parts.append("path=\(path)")
            if let id = sanitize(HostFingerprint.bundleID(fromProcessPath: path)) {
                HandoffDiagnostics.record("host.pidLookup", detail: parts.joined(separator: " ") + " via=path")
                return id
            }
        } else {
            parts.append("path=nil")
        }
        if let id = sanitize(launchServicesBundleID(forPID: pid)) {
            parts.append("ls=\(id)")
            HandoffDiagnostics.record("host.pidLookup", detail: parts.joined(separator: " ") + " via=ls")
            return id
        }
        parts.append("ls=nil")
        if let id = sanitize(runningBoardBundleID(forPID: pid)) {
            parts.append("rbs=\(id)")
            HandoffDiagnostics.record("host.pidLookup", detail: parts.joined(separator: " ") + " via=rbs")
            return id
        }
        parts.append("rbs=nil")
        HandoffDiagnostics.record("host.pidLookup", detail: parts.joined(separator: " ") + " unresolved")
        return nil
    }

    static func bundleID(from controller: UIInputViewController) -> String? {
        probedBundleID(from: controller)
    }

    static func remember(_ bundleID: String) {
        guard sanitize(bundleID) != nil else { return }
        AppGroupStore.lastHostBundleID = bundleID
    }

    static func remember(pid: pid_t, bundleID: String) {
        guard pid > 1, let id = sanitize(bundleID) else { return }
        var map = pidMap
        map[String(pid)] = id
        if map.count > 24, let first = map.keys.first {
            map.removeValue(forKey: first)
        }
        pidMap = map
    }

    static func rememberedBundleID(forPID pid: pid_t) -> String? {
        guard pid > 1, let id = pidMap[String(pid)] else { return nil }
        return sanitize(id)
    }

    struct FrontmostProbe {
        var sbs: String?
        var workspace: String?
        var sanitized: String?
    }

    static func frontmostBundleID() -> String? {
        frontmostProbe().sanitized
    }

    /// Raw SpringBoard / workspace strings before Murmur/SpringBoard are stripped.
    /// Callers must log `sbs`/`workspace` — sanitize turns self into “empty.”
    static func frontmostProbe() -> FrontmostProbe {
        let sbs = sbsFrontmostBundleID()
        let workspace = workspaceFrontmostRaw()
        return FrontmostProbe(
            sbs: sbs,
            workspace: workspace,
            sanitized: sanitize(sbs) ?? sanitize(workspace)
        )
    }

    static func sanitizeForHost(_ value: String?) -> String? {
        sanitize(value)
    }

    static func forget() {
        AppGroupStore.lastHostBundleID = ""
    }

    private static var pidMap: [String: String] {
        get {
            UserDefaults(suiteName: AppGroupStore.suiteName)?
                .dictionary(forKey: "hostPIDBundleMap") as? [String: String] ?? [:]
        }
        set {
            UserDefaults(suiteName: AppGroupStore.suiteName)?
                .set(newValue, forKey: "hostPIDBundleMap")
        }
    }

    private static func sanitize(_ value: String?) -> String? {
        guard let value, value.contains(".") else { return nil }
        let parts = value.split(separator: ".")
        guard parts.count >= 2, parts[0].first?.isLetter == true else { return nil }
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

    private static func kvcObjects(from controller: UIInputViewController) -> [NSObject] {
        var objects = identityObjects(from: controller)
        objects.append(controller.view)
        if let window = controller.view.window { objects.append(window) }
        return objects
    }

    private static func identityObjects(from controller: UIInputViewController) -> [NSObject] {
        var objects: [NSObject] = [controller]
        if let context = controller.extensionContext { objects.append(context) }
        if let proxy = controller.textDocumentProxy as? NSObject { objects.append(proxy) }
        var ancestor: UIViewController? = controller.parent
        while let current = ancestor {
            objects.append(current)
            ancestor = current.parent
        }
        if let impl = keyboardImpl() { objects.append(impl) }
        return objects
    }

    private static func recordEmptyProbe(fingerprint: String, scan: HostIvarScanner.Hit) {
        let pids = scan.pids.map { pid in
            let path = processPath(pid: pid) ?? "nopath"
            return "\(pid):\(path)"
        }.joined(separator: ",")
        var detail = "empty \(fingerprint) pids=\(pids.isEmpty ? "none" : pids)"
        if !scan.xpcDescriptions.isEmpty {
            let xpc = scan.xpcDescriptions.prefix(2).joined(separator: "|")
            detail += " xpc=\(xpc)"
        }
        if !scan.inventory.isEmpty {
            let inventory = scan.inventory.prefix(24).joined(separator: ";")
            detail += " ivars=\(inventory)"
        }
        if detail.count > 700 { detail = String(detail.prefix(700)) }
        HandoffDiagnostics.record("keyboard.host.probe", detail: detail)
    }

    private static func kvcBundleID(from controller: UIInputViewController) -> String? {
        let names = [
            "hostBundleID", "hostBundleIdentifier", "_hostBundleID",
            "_hostBundleIdentifier", "containingAppBundleID",
            "parentBundleIdentifier", "hostAppBundleIdentifier",
            "clientBundleIdentifier", "_clientBundleIdentifier",
            "targetBundleID", "_targetBundleID"
        ]
        for object in kvcObjects(from: controller) {
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

    private static func hostPID(from controller: UIInputViewController) -> pid_t? {
        let names = ["hostPID", "_hostPID", "hostProcessIdentifier"]
        for object in identityObjects(from: controller) {
            for name in names {
                let selector = NSSelectorFromString(name)
                guard object.responds(to: selector),
                      let method = object.method(for: selector) else { continue }
                typealias Getter = @convention(c) (AnyObject, Selector) -> Int
                let fn = unsafeBitCast(method, to: Getter.self)
                let value = fn(object, selector)
                if value > 1, value < 1_000_000 { return pid_t(value) }
            }
        }
        return nil
    }

    private static func bundleIDMatchingSpringBoardPID(_ pid: pid_t) -> String? {
        var identifiers = HostFingerprint.dictationHostBundleIDs
        identifiers.append(contentsOf: springBoardRunningIdentifiers())
        var seen = Set<String>()
        for bundleID in identifiers where seen.insert(bundleID).inserted {
            if springBoardPID(forBundleID: bundleID) == pid { return bundleID }
        }
        return nil
    }

    private static func springBoardPID(forBundleID bundleID: String) -> pid_t? {
        let path = "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices"
        guard let handle = dlopen(path, RTLD_NOW) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SBSProcessIDForDisplayIdentifier") else { return nil }
        typealias PIDFn = @convention(c) (CFString, UnsafeMutablePointer<pid_t>) -> Bool
        let fn = unsafeBitCast(symbol, to: PIDFn.self)
        var out: pid_t = 0
        guard fn(bundleID as CFString, &out), out > 1 else { return nil }
        return out
    }

    private static func springBoardRunningIdentifiers() -> [String] {
        let path = "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices"
        guard let handle = dlopen(path, RTLD_NOW) else { return [] }
        defer { dlclose(handle) }
        let names = [
            "SBSCopyApplicationDisplayIdentifiers",
            "SBSCopyRunningApplicationDisplayIdentifiers"
        ]
        for name in names {
            guard let symbol = dlsym(handle, name) else { continue }
            if name == "SBSCopyRunningApplicationDisplayIdentifiers" {
                typealias CopyRunning = @convention(c) () -> Unmanaged<CFArray>?
                let fn = unsafeBitCast(symbol, to: CopyRunning.self)
                if let array = fn()?.takeRetainedValue() as? [String] { return array }
            } else {
                typealias CopyApps = @convention(c) (Bool, Bool) -> Unmanaged<CFArray>?
                let fn = unsafeBitCast(symbol, to: CopyApps.self)
                if let array = fn(true, false)?.takeRetainedValue() as? [String] { return array }
            }
        }
        return []
    }

    private static func processName(pid: pid_t) -> String? {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "proc_name") else { return nil }
        typealias NameFn = @convention(c) (pid_t, UnsafeMutablePointer<CChar>?, UInt32) -> Int32
        let fn = unsafeBitCast(symbol, to: NameFn.self)
        var buffer = [CChar](repeating: 0, count: 64)
        let count = fn(pid, &buffer, 64)
        guard count > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func shortBSDName(pid: pid_t) -> String? {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "proc_pidinfo") else { return nil }
        typealias InfoFn = @convention(c) (pid_t, Int32, UInt64, UnsafeMutableRawPointer?, Int32) -> Int32
        let fn = unsafeBitCast(symbol, to: InfoFn.self)
        var buffer = [UInt8](repeating: 0, count: 64)
        let written = fn(pid, 13, 0, &buffer, Int32(buffer.count))
        guard written >= 32 else { return nil }
        let comm = buffer[16..<32]
        if let end = comm.firstIndex(of: 0) {
            return String(bytes: comm[..<end], encoding: .utf8)
        }
        return String(bytes: comm, encoding: .utf8)
    }

    private static func processArgsPath(pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, 49, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        let pathBytes = buffer.dropFirst(4)
        guard let end = pathBytes.firstIndex(of: 0) else { return nil }
        return String(bytes: pathBytes[..<end], encoding: .utf8)
    }

    private static func launchServicesBundleID(forPID pid: pid_t) -> String? {
        guard let cls = NSClassFromString("LSApplicationProxy") else { return nil }
        for name in [
            "applicationProxyForPid:",
            "applicationProxyForProcessID:",
            "applicationProxyForProcessIdentifier:"
        ] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getClassMethod(cls, selector) else { continue }
            typealias ProxyFn = @convention(c) (AnyClass, Selector, Int32) -> Unmanaged<AnyObject>?
            let fn = unsafeBitCast(method_getImplementation(method), to: ProxyFn.self)
            guard let proxy = fn(cls, selector, pid)?.takeUnretainedValue() as? NSObject else { continue }
            for key in ["bundleIdentifier", "applicationIdentifier"] {
                let idSelector = NSSelectorFromString(key)
                if proxy.responds(to: idSelector),
                   let value = proxy.perform(idSelector)?.takeUnretainedValue() as? String {
                    return value
                }
            }
        }
        return nil
    }

    private static func runningBoardBundleID(forPID pid: pid_t) -> String? {
        let path = "/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices"
        dlopen(path, RTLD_NOW)
        guard let identClass = NSClassFromString("RBSProcessIdentifier") as? NSObject.Type,
              let handleClass = NSClassFromString("RBSProcessHandle") as? NSObject.Type else { return nil }
        let identSelector = NSSelectorFromString("identifierWithPid:")
        guard let identMethod = class_getClassMethod(identClass, identSelector) else { return nil }
        typealias IdentFn = @convention(c) (AnyClass, Selector, Int32) -> Unmanaged<AnyObject>?
        let identFn = unsafeBitCast(method_getImplementation(identMethod), to: IdentFn.self)
        guard let identifier = identFn(identClass, identSelector, pid)?.takeUnretainedValue() else { return nil }
        let handleSelector = NSSelectorFromString("handleForIdentifier:error:")
        guard handleClass.responds(to: handleSelector),
              let handle = handleClass.perform(handleSelector, with: identifier, with: nil)?
                .takeUnretainedValue() as? NSObject else { return nil }
        let description = handle.debugDescription
        HandoffDiagnostics.record("host.rbs", detail: "pid=\(pid) \(description.prefix(160))")
        if let id = HostFingerprint.bundleID(fromProcessPath: description) { return id }
        if handle.responds(to: NSSelectorFromString("identity")),
           let identity = handle.perform(NSSelectorFromString("identity"))?.takeUnretainedValue() as? NSObject {
            let identityDescription = identity.debugDescription
            if let id = HostFingerprint.bundleID(fromProcessPath: identityDescription) { return id }
            for key in ["embeddedApplicationIdentifier", "applicationBundleIdentifier", "executablePath"] {
                let idSelector = NSSelectorFromString(key)
                guard identity.responds(to: idSelector),
                      let value = identity.perform(idSelector)?.takeUnretainedValue() as? String,
                      let id = sanitize(value) ?? sanitize(HostFingerprint.bundleID(fromProcessPath: value)) else { continue }
                return id
            }
        }
        for key in ["bundleIdentifier", "executablePath", "executable"] {
            let idSelector = NSSelectorFromString(key)
            guard handle.responds(to: idSelector),
                  let value = handle.perform(idSelector)?.takeUnretainedValue() else { continue }
            if let string = value as? String {
                if let id = HostFingerprint.bundleID(fromProcessPath: string) { return id }
                if string.contains(".") { return string }
            }
            if let url = value as? URL,
               let id = HostFingerprint.bundleID(fromProcessPath: url.path) {
                return id
            }
        }
        return nil
    }

    private static func codeSigningBundleID(forPID pid: pid_t) -> String? {
        if let identity = csopsString(pid: pid, ops: 12) {
            if let id = sanitize(identity) { return id }
            if let id = sanitize(HostFingerprint.bundleID(fromProcessPath: identity)) { return id }
        }
        if let path = csopsString(pid: pid, ops: 4) {
            if let id = sanitize(HostFingerprint.bundleID(fromProcessPath: path)) { return id }
        }
        return nil
    }

    private static func csopsString(pid: pid_t, ops: UInt32) -> String? {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "csops") else { return nil }
        typealias CSOps = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer?, Int) -> Int32
        let fn = unsafeBitCast(symbol, to: CSOps.self)
        var buffer = [UInt8](repeating: 0, count: 1024)
        let status = buffer.withUnsafeMutableBytes { raw in
            fn(pid, ops, raw.baseAddress, raw.count)
        }
        guard status == 0 else { return nil }
        if let direct = String(bytes: buffer.prefix(while: { $0 != 0 }), encoding: .utf8),
           !direct.isEmpty {
            return direct
        }
        guard buffer.count > 4 else { return nil }
        let length = Int(buffer.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) })
        guard length > 0, length < 1000 else { return nil }
        let slice = buffer.dropFirst(4).prefix(length)
        return String(bytes: slice.prefix(while: { $0 != 0 }), encoding: .utf8)
    }

    private static func kernelComm(pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return nil }
            let name = String(cString: base)
            return name.isEmpty ? nil : name
        }
    }

    private static func kernelCommTable() -> [pid_t: String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size >= MemoryLayout<kinfo_proc>.stride else {
            return [:]
        }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count + 8)
        var bufferSize = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 3, &procs, &bufferSize, nil, 0) == 0 else { return [:] }
        let actual = bufferSize / MemoryLayout<kinfo_proc>.stride
        var result: [pid_t: String] = [:]
        for index in 0..<actual {
            let pid = procs[index].kp_proc.p_pid
            guard pid > 1 else { continue }
            let name = withUnsafeBytes(of: procs[index].kp_proc.p_comm) { raw -> String? in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return nil }
                let value = String(cString: base)
                return value.isEmpty ? nil : value
            }
            if let name { result[pid] = name }
        }
        return result
    }

    private static func signingIdentifier(from connection: NSXPCConnection) -> String? {
        guard let token = auditToken(from: connection) else { return nil }
        return signingIdentifier(fromAuditToken: token)
    }

    private static func auditToken(from connection: NSXPCConnection) -> audit_token_t? {
        let selector = NSSelectorFromString("auditToken")
        guard connection.responds(to: selector),
              let method = connection.method(for: selector) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> audit_token_t
        let fn = unsafeBitCast(method, to: Fn.self)
        return fn(connection, selector)
    }

    private static func signingIdentifier(fromAuditToken token: audit_token_t) -> String? {
        guard let handle = dlopen(
            "/System/Library/Frameworks/Security.framework/Security",
            RTLD_NOW
        ) else { return nil }
        guard let createSym = dlsym(handle, "SecTaskCreateWithAuditToken"),
              let copySym = dlsym(handle, "SecTaskCopySigningIdentifier") else { return nil }
        typealias Create = @convention(c) (CFAllocator?, audit_token_t) -> Unmanaged<AnyObject>?
        typealias CopyID = @convention(c) (
            AnyObject, UnsafeMutablePointer<Unmanaged<CFError>?>?
        ) -> Unmanaged<CFString>?
        let create = unsafeBitCast(createSym, to: Create.self)
        let copyID = unsafeBitCast(copySym, to: CopyID.self)
        guard let task = create(nil, token)?.takeRetainedValue() else { return nil }
        var error: Unmanaged<CFError>?
        guard let identifier = copyID(task, &error)?.takeRetainedValue() as String?,
              !identifier.isEmpty else { return nil }
        return identifier
    }

    private static func sbsBundleID(forPID pid: pid_t) -> String? {
        let path = "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices"
        guard let handle = dlopen(path, RTLD_NOW) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SBSCopyDisplayIdentifierForProcessID") else { return nil }
        typealias CopyFn = @convention(c) (pid_t) -> Unmanaged<CFString>?
        let fn = unsafeBitCast(symbol, to: CopyFn.self)
        return fn(pid)?.takeRetainedValue() as String?
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
        sanitize(workspaceFrontmostRaw())
    }

    private static func workspaceFrontmostRaw() -> String? {
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
                      let value = app.perform(idSelector)?.takeUnretainedValue() as? String,
                      !value.isEmpty
                else { continue }
                return value
            }
        }
        return nil
    }

    private static func collectClassNames(from controller: UIInputViewController) -> [String] {
        var names: [String] = [NSStringFromClass(type(of: controller))]
        names.append(NSStringFromClass(type(of: controller.textDocumentProxy as AnyObject)))
        if let context = controller.extensionContext {
            names.append(NSStringFromClass(type(of: context)))
        }
        var ancestor: UIViewController? = controller.parent
        while let current = ancestor {
            names.append(NSStringFromClass(type(of: current)))
            ancestor = current.parent
        }
        names.append(contentsOf: keyboardImplClassNames())
        names.append(contentsOf: ivarClassNames(from: controller))
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private static func keyboardImpl() -> NSObject? {
        guard let cls = NSClassFromString("UIKeyboardImpl") as? NSObject.Type else { return nil }
        for name in ["sharedInstance", "activeInstance"] {
            let selector = NSSelectorFromString(name)
            if cls.responds(to: selector),
               let value = cls.perform(selector)?.takeUnretainedValue() as? NSObject {
                return value
            }
        }
        return nil
    }

    private static func keyboardImplClassNames() -> [String] {
        var names: [String] = []
        guard let impl = keyboardImpl() else { return names }
        names.append(NSStringFromClass(type(of: impl)))
        for key in ["delegate", "inputDelegate", "legacyInputDelegate", "responder", "textInputDelegate"] {
            let selector = NSSelectorFromString(key)
            guard impl.responds(to: selector),
                  let value = impl.perform(selector)?.takeUnretainedValue() else { continue }
            names.append(NSStringFromClass(type(of: value as AnyObject)))
        }
        return names
    }

    private static func ivarClassNames(from controller: UIInputViewController) -> [String] {
        var names: [String] = []
        for object in identityObjects(from: controller) {
            var cls: AnyClass? = object_getClass(object)
            while let current = cls {
                var count: UInt32 = 0
                if let ivars = class_copyIvarList(current, &count) {
                    defer { free(ivars) }
                    for i in 0..<Int(count) {
                        let ivar = ivars[i]
                        guard let encodingC = ivar_getTypeEncoding(ivar),
                              String(cString: encodingC).hasPrefix("@"),
                              let value = object_getIvar(object, ivar) else { continue }
                        names.append(NSStringFromClass(type(of: value as AnyObject)))
                    }
                }
                cls = class_getSuperclass(current)
            }
        }
        return names
    }

    private static func processPathBundleID() -> String? {
        for path in processPaths() {
            if let id = HostFingerprint.bundleID(fromProcessPath: path) { return id }
        }
        return nil
    }

    private static func processPaths() -> [String] {
        [getpid(), getppid()].compactMap { processPath(pid: $0) }
    }

    private static func processPath(pid: pid_t) -> String? {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "proc_pidpath") else { return nil }
        typealias PathFn = @convention(c) (pid_t, UnsafeMutablePointer<CChar>?, UInt32) -> Int32
        let fn = unsafeBitCast(symbol, to: PathFn.self)
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let count = fn(pid, &buffer, UInt32(MAXPATHLEN))
        guard count > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func fingerprintSummary(from controller: UIInputViewController) -> String {
        let proxy = controller.textDocumentProxy
        let returnRaw = proxy.returnKeyType?.rawValue ?? -1
        let keyboardRaw = proxy.keyboardType?.rawValue ?? -1
        let names = collectClassNames(from: controller).prefix(8).joined(separator: ",")
        let paths = processPaths().map { ($0 as NSString).lastPathComponent }.joined(separator: "|")
        let summary = "return=\(returnRaw) kb=\(keyboardRaw) names=\(names) proc=\(paths)"
        if summary.count <= 240 { return summary }
        return String(summary.prefix(240))
    }
}
