import AppKit
import Foundation

/// Persists the selected Style profile and pushes its formality instruction
/// onto the live `ASREngineSelector` — same UserDefaults + push pattern as
/// `SettingsStore`'s `codeAwareMode`. Supports optional per-app overrides
/// keyed by bundle identifier.
@MainActor
final class StyleStore: ObservableObject {

    private enum Keys {
        static let selectedStyle = "voice.settings.selectedStyle"
        static let appProfileMap = "voice.settings.appStyleProfiles"
    }

    @Published var selected: StyleProfile {
        didSet {
            UserDefaults.standard.set(selected.rawValue, forKey: Keys.selectedStyle)
            applyGlobalStyle()
        }
    }

    /// bundleID → StyleProfile raw value
    @Published private(set) var appProfileMap: [String: StyleProfile] = [:]

    /// Weak reference to the live selector, wired in by `AppDelegate` — same
    /// wiring shape as `SettingsStore.asrEngineSelector`.
    weak var asrEngineSelector: ASREngineSelector?

    init() {
        if let raw = UserDefaults.standard.string(forKey: Keys.selectedStyle),
           let profile = StyleProfile(rawValue: raw) {
            selected = profile
        } else {
            selected = .casual
        }

        if let data = UserDefaults.standard.data(forKey: Keys.appProfileMap),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            appProfileMap = decoded.compactMapValues { StyleProfile(rawValue: $0) }
        }
    }

    /// Pushes the persisted selection onto the live selector. Call once after
    /// `asrEngineSelector` is wired, mirroring `SettingsStore.applyOnLaunch()`.
    func applyOnLaunch() {
        applyGlobalStyle()
    }

    /// Applies the global selected profile instruction.
    func applyGlobalStyle() {
        asrEngineSelector?.styleInstruction = selected.instruction
    }

    /// Reads the frontmost app's bundle ID and applies a matching per-app
    /// style instruction when one exists; otherwise falls back to global.
    func applyStyleForFrontmostApp() {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            applyGlobalStyle()
            return
        }
        if let profile = appProfileMap[bundleID] {
            asrEngineSelector?.styleInstruction = profile.instruction
        } else {
            applyGlobalStyle()
        }
    }

    /// Assigns `profile` to the given app bundle identifier.
    func assignProfile(_ profile: StyleProfile, toBundleID bundleID: String) {
        appProfileMap[bundleID] = profile
        persistAppMap()
    }

    /// Removes a per-app override.
    func removeAssignment(forBundleID bundleID: String) {
        appProfileMap.removeValue(forKey: bundleID)
        persistAppMap()
    }

    /// Human-readable name for a bundle identifier, when available.
    func appDisplayName(for bundleID: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app.localizedName ?? bundleID
        }
        return bundleID
    }

    private func persistAppMap() {
        let raw = appProfileMap.mapValues { $0.rawValue }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Keys.appProfileMap)
        }
    }
}
