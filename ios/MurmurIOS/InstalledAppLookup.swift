import Darwin
import ObjectiveC
import UIKit

@_silgen_name("proc_listallpids")
private func murmur_proc_listallpids(_ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

@_silgen_name("proc_pidpath")
private func murmur_proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ buffersize: UInt32) -> Int32

struct InstalledApp: Identifiable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let icon: UIImage?
}

/// Sideload app discovery. Bulk `LSApplicationWorkspace` lists are entitlement-gated
/// on modern iOS and must not be trusted when empty. Do not compile into the widget.
@MainActor
enum InstalledAppLookup {
    private static var cached: [InstalledApp]?
    private static var byID: [String: InstalledApp] = [:]
    private static var iconMemory: [String: UIImage] = [:]

    static func all() -> [InstalledApp] {
        if let cached { return cached }
        let apps = fetch()
        cached = apps
        for app in apps { byID[app.bundleID] = app }
        return apps
    }

    static func refresh() {
        cached = nil
        byID = [:]
        _ = all()
    }

    static func presentation(for bundleID: String) -> InstalledApp {
        if let hit = byID[bundleID] { return hit }
        let made = app(fromBundleID: bundleID)
        byID[bundleID] = made
        return made
    }

    static func remember(_ app: InstalledApp) {
        byID[app.bundleID] = app
        if let icon = app.icon {
            storeIcon(icon, for: app.bundleID)
        }
    }

    static func prefetchArtwork(for bundleIDs: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for id in bundleIDs {
                group.addTask { @MainActor in
                    _ = await artwork(for: id)
                }
            }
        }
    }

    /// Device icon if Launch Services will give it up; otherwise App Store artwork.
    static func artwork(for bundleID: String) async -> UIImage? {
        if let hit = iconMemory[bundleID] { return hit }
        if let disk = loadDiskIcon(for: bundleID) {
            iconMemory[bundleID] = disk
            mergeIcon(disk, into: bundleID)
            return disk
        }
        return await fetchArtwork(for: bundleID)
    }

    private static func fetch() -> [InstalledApp] {
        var seen = Set<String>()
        var out: [InstalledApp] = []
        func append(_ app: InstalledApp) {
            guard ReturnAppCatalog.isAllowed(app.bundleID) else { return }
            guard seen.insert(app.bundleID).inserted else { return }
            out.append(app)
        }

        for (id, name) in coreAppleApps {
            append(InstalledApp(bundleID: id, name: name, icon: icon(for: id)))
        }

        // Catalog apps are always offered. iOS 27 will not enumerate
        // SpringBoard, and Claude / Cursor / Grok Bot have no URL scheme
        // for canOpenURL, so an isInstalled probe leaves them invisible.
        for known in ReturnAppCatalog.all {
            append(app(fromBundleID: known.bundleID))
        }

        for record in applicationRecords() {
            if let app = app(from: record) { append(app) }
        }

        if let workspace = workspace() {
            for item in enumerateApplications(workspace) {
                guard let proxy = item as? NSObject, let app = app(from: proxy) else { continue }
                append(app)
            }
        }

        for id in sbsDisplayIdentifiers() {
            append(app(fromBundleID: id))
        }

        for app in appsFromFilesystem() {
            append(app)
        }

        for id in runningAppBundleIDs() {
            append(app(fromBundleID: id))
        }

        for (scheme, bundleID) in schemeBundleIDs {
            guard let url = URL(string: "\(scheme)://"),
                  UIApplication.shared.canOpenURL(url) else { continue }
            append(app(fromBundleID: bundleID))
        }

        for id in thirdPartyProbeIDs {
            guard !seen.contains(id), isInstalled(id) else { continue }
            append(app(fromBundleID: id))
        }

        HandoffDiagnostics.record("apps.list", detail: "count=\(out.count)")
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func searchAppStore(_ rawQuery: String) async -> [InstalledApp] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        var parts = URLComponents(string: "https://itunes.apple.com/search")
        parts?.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US")
        ]
        guard let url = parts?.url else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        var out: [InstalledApp] = []
        var seen = Set<String>()
        for row in results {
            guard let id = row["bundleId"] as? String, ReturnAppCatalog.isAllowed(id) else { continue }
            guard seen.insert(id).inserted else { continue }
            let name = (row["trackName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? ReturnAppCatalog.displayTitle(for: id)
            var image = icon(for: id) ?? iconMemory[id]
            if image == nil {
                image = await imageFromStoreRow(row)
            }
            if let image {
                storeIcon(image, for: id)
            }
            out.append(InstalledApp(bundleID: id, name: name, icon: image))
        }
        return out
    }

    private static func isInstalled(_ bundleID: String) -> Bool {
        if mcmContainerExists(bundleID) { return true }
        if workspaceSaysInstalled(bundleID) { return true }
        if applicationRecord(bundleID) != nil { return true }
        return false
    }

    private static func app(from object: NSObject) -> InstalledApp? {
        let bundleID = string(from: object, keys: [
            "applicationIdentifier",
            "bundleIdentifier"
        ])
        guard ReturnAppCatalog.isAllowed(bundleID) else { return nil }
        if bundleID.hasSuffix(".appex") { return nil }
        if bundleID.contains(".watchkitapp") { return nil }
        if bool(from: object, key: "isAppClip") { return nil }
        var name = string(from: object, keys: ["localizedName", "itemName", "name"])
        if name.isEmpty { name = ReturnAppCatalog.displayTitle(for: bundleID) }
        return InstalledApp(bundleID: bundleID, name: name, icon: icon(for: bundleID))
    }

    private static func app(fromBundleID bundleID: String) -> InstalledApp {
        if let record = applicationRecord(bundleID), let app = app(from: record) {
            return app
        }
        if let proxy = proxy(for: bundleID), let app = app(from: proxy) {
            return app
        }
        if let name = coreAppleApps.first(where: { $0.id == bundleID })?.name {
            return InstalledApp(bundleID: bundleID, name: name, icon: icon(for: bundleID))
        }
        return InstalledApp(
            bundleID: bundleID,
            name: ReturnAppCatalog.displayTitle(for: bundleID),
            icon: icon(for: bundleID)
        )
    }

    private static func workspace() -> NSObject? {
        let defaultSelector = NSSelectorFromString("defaultWorkspace")
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              workspaceClass.responds(to: defaultSelector),
              let workspace = workspaceClass.perform(defaultSelector)?.takeUnretainedValue() as? NSObject
        else { return nil }
        return workspace
    }

    private static func enumerateApplications(_ workspace: NSObject) -> [Any] {
        for name in ["enumerateApplicationsOfType:block:", "enumerateApplicationsOfType:usingBlock:"] {
            let sel = NSSelectorFromString(name)
            guard workspace.responds(to: sel) else { continue }
            typealias Block = @convention(block) (NSObject) -> Void
            typealias Fn = @convention(c) (AnyObject, Selector, Int, Block) -> Void
            let fn = unsafeBitCast(workspace.method(for: sel), to: Fn.self)
            var out: [Any] = []
            let block: Block = { proxy in out.append(proxy) }
            fn(workspace, sel, 0, block)
            fn(workspace, sel, 1, block)
            if !out.isEmpty { return out }
        }
        return []
    }

    private static func workspaceSaysInstalled(_ bundleID: String) -> Bool {
        guard let workspace = workspace() else { return false }
        let sel = NSSelectorFromString("applicationIsInstalled:")
        guard workspace.responds(to: sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, NSString) -> UInt8
        let fn = unsafeBitCast(workspace.method(for: sel), to: Fn.self)
        return fn(workspace, sel, bundleID as NSString) != 0
    }

    private static func proxy(for bundleID: String) -> NSObject? {
        guard let cls = NSClassFromString("LSApplicationProxy") as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("applicationProxyForIdentifier:")
        guard cls.responds(to: sel) else { return nil }
        return cls.perform(sel, with: bundleID)?.takeUnretainedValue() as? NSObject
    }

    private static func applicationRecord(_ bundleID: String) -> NSObject? {
        guard let cls = NSClassFromString("LSApplicationRecord") as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("applicationRecordWithBundleIdentifier:allowPlaceholder:error:")
        guard let method = class_getClassMethod(cls, sel) else { return nil }
        typealias Fn = @convention(c) (AnyClass, Selector, NSString, UInt8, UnsafeMutableRawPointer?) -> Unmanaged<AnyObject>?
        let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        return fn(cls, sel, bundleID as NSString, 0, nil)?.takeUnretainedValue() as? NSObject
    }

    private static func applicationRecords() -> [NSObject] {
        guard let cls = NSClassFromString("LSApplicationRecord") as? NSObject.Type else { return [] }
        let sel = NSSelectorFromString("enumeratorWithOptions:")
        guard let method = class_getClassMethod(cls, sel) else { return [] }
        typealias Fn = @convention(c) (AnyClass, Selector, UInt) -> Unmanaged<AnyObject>?
        let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        for option in [UInt(0), 1, 2, 8, 16] {
            guard let enumerator = fn(cls, sel, option)?.takeUnretainedValue() as? NSEnumerator else { continue }
            while let item = enumerator.nextObject() as? NSObject {
                if seen.insert(ObjectIdentifier(item)).inserted {
                    out.append(item)
                }
            }
            if out.count > 8 { break }
        }
        return out
    }

    private static func mcmContainerExists(_ bundleID: String) -> Bool {
        let path = "/System/Library/PrivateFrameworks/MobileContainerManager.framework"
        _ = Bundle(path: path)?.load()
        for className in ["MCMAppContainer", "MCMAppDataContainer"] {
            guard let cls = NSClassFromString(className) as? NSObject.Type else { continue }
            let sel = NSSelectorFromString("containerWithIdentifier:error:")
            guard cls.responds(to: sel) else { continue }
            if cls.perform(sel, with: bundleID, with: nil)?.takeUnretainedValue() != nil {
                return true
            }
        }
        return false
    }

    private static func sbsDisplayIdentifiers() -> [String] {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
            RTLD_NOW
        ) else { return [] }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SBSCopyApplicationDisplayIdentifiers") else { return [] }
        typealias Fn = @convention(c) (Bool, Bool) -> Unmanaged<CFArray>?
        let fn = unsafeBitCast(symbol, to: Fn.self)
        var ids: [String] = []
        for pair in [(false, false), (false, true), (true, false)] {
            guard let array = fn(pair.0, pair.1)?.takeRetainedValue() else { continue }
            for index in 0..<CFArrayGetCount(array) {
                let value = unsafeBitCast(CFArrayGetValueAtIndex(array, index), to: AnyObject.self)
                if let id = value as? String, !id.isEmpty {
                    ids.append(id)
                }
            }
        }
        return ids
    }

    private static func appsFromFilesystem() -> [InstalledApp] {
        var out: [InstalledApp] = []
        var seen = Set<String>()
        func consider(appURL: URL) {
            let info = appURL.appendingPathComponent("Info.plist")
            guard let plist = NSDictionary(contentsOf: info) else { return }
            guard let id = plist["CFBundleIdentifier"] as? String, ReturnAppCatalog.isAllowed(id) else { return }
            if id.hasSuffix(".appex") || id.contains(".watchkitapp") { return }
            guard seen.insert(id).inserted else { return }
            let name = (plist["CFBundleDisplayName"] as? String)
                ?? (plist["CFBundleName"] as? String)
                ?? ReturnAppCatalog.displayTitle(for: id)
            out.append(InstalledApp(bundleID: id, name: name, icon: icon(for: id)))
        }
        let fm = FileManager.default
        let roots = [
            "/Applications",
            "/System/Applications",
            "/private/var/containers/Bundle/Application",
            "/var/containers/Bundle/Application"
        ]
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: nil
            ) else { continue }
            for item in items {
                if item.pathExtension == "app" {
                    consider(appURL: item)
                    continue
                }
                guard let inner = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) else {
                    continue
                }
                for sub in inner where sub.pathExtension == "app" {
                    consider(appURL: sub)
                }
            }
        }
        return out
    }

    private static func runningAppBundleIDs() -> [String] {
        let needed = murmur_proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed))
        let filled = pids.withUnsafeMutableBufferPointer { buffer in
            murmur_proc_listallpids(buffer.baseAddress, Int32(MemoryLayout<pid_t>.stride * buffer.count))
        }
        guard filled > 0 else { return [] }
        var ids: [String] = []
        var path = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            let length = murmur_proc_pidpath(pid, &path, UInt32(path.count))
            guard length > 0 else { continue }
            let raw = String(cString: path)
            guard raw.contains(".app/") else { continue }
            guard let range = raw.range(of: ".app/", options: [.backwards]) else { continue }
            let appURL = URL(fileURLWithPath: String(raw[..<range.lowerBound]) + ".app")
            let info = appURL.appendingPathComponent("Info.plist")
            if let plist = NSDictionary(contentsOf: info),
               let id = plist["CFBundleIdentifier"] as? String,
               ReturnAppCatalog.isAllowed(id) {
                ids.append(id)
            }
        }
        return ids
    }

    private static func icon(for bundleID: String) -> UIImage? {
        if let image = iconMemory[bundleID] { return image }
        return loadDiskIcon(for: bundleID)
    }

    private static func systemIcon(for bundleID: String) -> UIImage? {
        let sel = NSSelectorFromString("_applicationIconImageForBundleIdentifier:format:scale:")
        guard let method = class_getClassMethod(UIImage.self, sel) else { return nil }
        typealias Fn = @convention(c) (AnyClass, Selector, NSString, NSInteger, CGFloat) -> UIImage?
        let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        let scale = UITraitCollection.current.displayScale
        for format: NSInteger in [2, 10, 1] {
            if let image = fn(UIImage.self, sel, bundleID as NSString, format, scale) {
                return image
            }
        }
        return nil
    }

    private static func fetchArtwork(for bundleID: String) async -> UIImage? {
        if let remote = await itunesArtwork(for: bundleID) {
            storeIcon(remote, for: bundleID)
            HandoffDiagnostics.record("apps.icon", detail: "id=\(bundleID) source=store")
            return remote
        }
        if let local = systemIcon(for: bundleID) {
            storeIcon(local, for: bundleID)
            HandoffDiagnostics.record("apps.icon", detail: "id=\(bundleID) source=system")
            return local
        }
        HandoffDiagnostics.record("apps.icon", detail: "id=\(bundleID) source=miss")
        return nil
    }

    private static func itunesArtwork(for bundleID: String) async -> UIImage? {
        var countries: [String] = []
        if let region = Locale.current.region?.identifier {
            countries.append(region)
        }
        if !countries.contains("US") {
            countries.append("US")
        }
        for country in countries {
            var parts = URLComponents(string: "https://itunes.apple.com/lookup")
            parts?.queryItems = [
                URLQueryItem(name: "bundleId", value: bundleID),
                URLQueryItem(name: "entity", value: "software"),
                URLQueryItem(name: "country", value: country)
            ]
            guard let url = parts?.url else { continue }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let row = results.first,
                  let image = await imageFromStoreRow(row)
            else { continue }
            return image
        }
        return nil
    }

    private static func imageFromStoreRow(_ row: [String: Any]) async -> UIImage? {
        guard let url = storeArtworkURL(from: row) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }

    private static func storeArtworkURL(from row: [String: Any]) -> URL? {
        if let value = row["artworkUrl512"] as? String, let url = URL(string: value) {
            return url
        }
        if let value = row["artworkUrl100"] as? String {
            let bigger = value.replacingOccurrences(of: "100x100bb", with: "256x256bb")
            return URL(string: bigger)
        }
        if let value = row["artworkUrl60"] as? String {
            return URL(string: value)
        }
        return nil
    }

    private static func storeIcon(_ image: UIImage, for bundleID: String) {
        iconMemory[bundleID] = image
        mergeIcon(image, into: bundleID)
        guard let file = iconFile(for: bundleID), let data = image.pngData() else { return }
        try? data.write(to: file, options: .atomic)
    }

    private static func mergeIcon(_ image: UIImage, into bundleID: String) {
        let name = byID[bundleID]?.name ?? ReturnAppCatalog.displayTitle(for: bundleID)
        byID[bundleID] = InstalledApp(bundleID: bundleID, name: name, icon: image)
    }

    private static func loadDiskIcon(for bundleID: String) -> UIImage? {
        guard let file = iconFile(for: bundleID),
              let data = try? Data(contentsOf: file) else { return nil }
        return UIImage(data: data)
    }

    private static func iconFile(for bundleID: String) -> URL? {
        let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupStore.suiteName
        )?.appendingPathComponent("Library/Caches/JumpBackIcons", isDirectory: true)
        guard let directory else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = bundleID.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safe).png")
    }

    private static func string(from object: NSObject, keys: [String]) -> String {
        for key in keys {
            let sel = NSSelectorFromString(key)
            guard object.responds(to: sel) else { continue }
            if let value = object.perform(sel)?.takeUnretainedValue() as? String, !value.isEmpty {
                return value
            }
        }
        return ""
    }

    private static func bool(from object: NSObject, key: String) -> Bool {
        let sel = NSSelectorFromString(key)
        guard object.responds(to: sel) else { return false }
        if let number = object.value(forKey: key) as? NSNumber {
            return number.boolValue
        }
        return (object.value(forKey: key) as? Bool) ?? false
    }

    /// Stock iPhone apps. Always offered — iOS will not enumerate SpringBoard for us.
    private static let coreAppleApps: [(id: String, name: String)] = [
        ("com.apple.mobilephone", "Phone"),
        ("com.apple.MobileSMS", "Messages"),
        ("com.apple.mobilemail", "Mail"),
        ("com.apple.mobilesafari", "Safari"),
        ("com.apple.mobilenotes", "Notes"),
        ("com.apple.reminders", "Reminders"),
        ("com.apple.mobilecal", "Calendar"),
        ("com.apple.DocumentsApp", "Files"),
        ("com.apple.Preferences", "Settings"),
        ("com.apple.camera", "Camera"),
        ("com.apple.mobileslideshow", "Photos"),
        ("com.apple.AppStore", "App Store"),
        ("com.apple.Maps", "Maps"),
        ("com.apple.Music", "Music"),
        ("com.apple.facetime", "FaceTime"),
        ("com.apple.MobileAddressBook", "Contacts"),
        ("com.apple.mobiletimer", "Clock"),
        ("com.apple.Passbook", "Wallet"),
        ("com.apple.Health", "Health"),
        ("com.apple.shortcuts", "Shortcuts"),
        ("com.apple.weather", "Weather"),
        ("com.apple.Fitness", "Fitness"),
        ("com.apple.Home", "Home"),
        ("com.apple.findmy", "Find My"),
        ("com.apple.VoiceMemos", "Voice Memos"),
        ("com.apple.podcasts", "Podcasts"),
        ("com.apple.tv", "TV"),
        ("com.apple.iBooks", "Books"),
        ("com.apple.news", "News"),
        ("com.apple.stocks", "Stocks"),
        ("com.apple.calculator", "Calculator"),
        ("com.apple.Translate", "Translate"),
        ("com.apple.Freeform", "Freeform"),
        ("com.apple.Journal", "Journal")
    ]

    private static let schemeBundleIDs: [(scheme: String, bundleID: String)] = [
        ("sms", "com.apple.MobileSMS"),
        ("mobilenotes", "com.apple.mobilenotes"),
        ("message", "com.apple.mobilemail"),
        ("x-web-search", "com.apple.mobilesafari"),
        ("x-apple-reminderkit", "com.apple.reminders"),
        ("calshow", "com.apple.mobilecal"),
        ("shareddocuments", "com.apple.DocumentsApp"),
        ("instagram", "com.burbn.instagram"),
        ("threads", "com.burbn.barcelona"),
        ("twitter", "com.atebits.Tweetie2"),
        ("fb", "com.facebook.Facebook"),
        ("fb-messenger", "com.facebook.Messenger"),
        ("whatsapp", "net.whatsapp.WhatsApp"),
        ("snapchat", "com.toyopagroup.picaboo"),
        ("snssdk1233", "com.zhiliaoapp.musically"),
        ("reddit", "com.reddit.Reddit"),
        ("linkedin", "com.linkedin.LinkedIn"),
        ("discord", "com.hammerandchisel.discord"),
        ("tg", "ph.telegra.Telegraph"),
        ("sgnl", "org.whispersystems.signal"),
        ("slack", "com.tinyspeck.chatlyio"),
        ("msteams", "com.microsoft.skype.teams"),
        ("zoomus", "us.zoom.videomeetings"),
        ("googlechrome", "com.google.chrome.ios"),
        ("googlegmail", "com.google.Gmail"),
        ("googledrive", "com.google.Drive"),
        ("comgooglemaps", "com.google.Maps"),
        ("youtube", "com.google.ios.youtube"),
        ("ms-outlook", "com.microsoft.Office.Outlook"),
        ("spotify", "com.spotify.client"),
        ("nflx", "com.netflix.Netflix"),
        ("aiv", "com.amazon.aiv.AIVApp"),
        ("uber", "com.ubercab.UberClient"),
        ("lyft", "com.lyft.lyft"),
        ("paypal", "com.paypal.PayPal"),
        ("venmo", "com.venmo.touch.v2"),
        ("cashme", "com.squareup.cash"),
        ("openai", "com.openai.chat"),
        ("github", "com.github.stormbreaker.prod")
    ]

    private static let thirdPartyProbeIDs: [String] = [
        "com.burbn.instagram",
        "com.burbn.barcelona",
        "com.atebits.Tweetie2",
        "com.facebook.Facebook",
        "com.facebook.Messenger",
        "net.whatsapp.WhatsApp",
        "net.whatsapp.WhatsAppSMB",
        "com.toyopagroup.picaboo",
        "com.zhiliaoapp.musically",
        "com.reddit.Reddit",
        "com.linkedin.LinkedIn",
        "com.hammerandchisel.discord",
        "ph.telegra.Telegraph",
        "org.whispersystems.signal",
        "xyz.blueskyweb.app",
        "com.tinyspeck.chatlyio",
        "com.microsoft.skype.teams",
        "us.zoom.videomeetings",
        "com.google.chrome.ios",
        "com.google.Gmail",
        "com.google.Drive",
        "com.google.Docs",
        "com.google.Sheets",
        "com.google.Maps",
        "com.google.GoogleMobile",
        "com.google.ios.youtube",
        "com.google.photos",
        "com.google.calendar",
        "com.google.Keep",
        "com.google.GoogleGemini",
        "com.microsoft.Office.Outlook",
        "com.microsoft.Office.Word",
        "com.microsoft.Office.Excel",
        "com.microsoft.Office.Powerpoint",
        "com.microsoft.onenote",
        "com.microsoft.skydrive",
        "com.spotify.client",
        "com.netflix.Netflix",
        "com.amazon.aiv.AIVApp",
        "com.disney.disneyplus",
        "com.amazon.Amazon",
        "com.ubercab.UberClient",
        "com.ubercab.UberEats",
        "com.lyft.lyft",
        "com.airbnb.app",
        "com.paypal.PayPal",
        "com.squareup.cash",
        "com.venmo.touch.v2",
        "org.mozilla.ios.Firefox",
        "com.brave.ios.browser",
        "com.openai.chat",
        "com.anthropic.claude",
        "ai.perplexity.app",
        "co.anysphere.sand",
        "co.anysphere.cursor",
        "com.github.stormbreaker.prod",
        "md.obsidian",
        "com.agiletortoise.Drafts5",
        "net.ia.IAWriter",
        "com.readdle.smartemail",
        "pinterest"
    ]
}
