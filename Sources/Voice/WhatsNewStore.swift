import Foundation

enum WhatsNewStore {
    static let lastSeenBuildKey = "whatsNew.lastSeenBuild"

    static func currentBuild(bundle: Bundle = .main) -> Int? {
        guard let raw = bundle.infoDictionary?["CFBundleVersion"] as? String else { return nil }
        return Int(raw)
    }

    static func lastSeenBuild(defaults: UserDefaults) -> Int {
        guard let raw = defaults.string(forKey: lastSeenBuildKey) else { return 0 }
        return Int(raw) ?? 0
    }

    static func shouldPresent(
        currentBuild: Int?,
        lastSeenBuild: Int,
        catalogNonEmpty: Bool
    ) -> Bool {
        guard let currentBuild, catalogNonEmpty else { return false }
        return currentBuild > lastSeenBuild
    }

    static func shouldPresent(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) -> Bool {
        shouldPresent(
            currentBuild: currentBuild(bundle: bundle),
            lastSeenBuild: lastSeenBuild(defaults: defaults),
            catalogNonEmpty: !WhatsNewCatalog.load(bundle: WhatsNewCatalog.resourceBundle).isEmpty
        )
    }

    static func markSeen(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        guard let current = currentBuild(bundle: bundle) else { return }
        defaults.set(String(current), forKey: lastSeenBuildKey)
    }

    static func releasesToPresent(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) -> [WhatsNewRelease] {
        let lastSeen = lastSeenBuild(defaults: defaults)
        let newer = WhatsNewCatalog.releases(withBuildGreaterThan: lastSeen)
        if !newer.isEmpty {
            return newer
        }
        if let latest = WhatsNewCatalog.latest() {
            return [latest]
        }
        return []
    }
}
