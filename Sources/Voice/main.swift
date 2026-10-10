import AppKit
import Darwin

// Explicit entry point.
//
// A code-only (nib-less) AppKit app must NOT rely on `@main` /
// `NSApplicationMain`: that path expects a main storyboard or nib to
// instantiate and wire the application delegate. Without one, NSApplication
// starts with a nil delegate — none of the app's startup code (menu bar,
// event tap, etc.) ever runs, even though the process stays alive in its
// run loop. We therefore create the app, set the delegate, and run it here.

// `AppDelegate` is `@MainActor`-isolated (it owns `@MainActor` stores like
// `ModelManager`/`SettingsStore`). This top-level entry point isn't itself
// annotated `@MainActor`, but it always runs on the main thread — it's the
// process entry point, executed before `app.run()` starts the run loop —
// so `assumeIsolated` is a correct, not just convenient, way to construct it.
let app = NSApplication.shared
// Hosted unit tests must not start global hotkeys, microphone services, or
// stores backed by the signed-in user's data.
let isTestHost = NSClassFromString("XCTestCase") != nil
    || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

private let voiceTestDefaultsSuiteName = "com.matt.voice-dictation.tests.\(UUID().uuidString)"

private func removeVoiceTestDefaultsDomain() {
    UserDefaults(suiteName: voiceTestDefaultsSuiteName)?.removePersistentDomain(forName: voiceTestDefaultsSuiteName)
}

/// Single test-host selector for stateful defaults. A unique suite prevents a
/// hosted test run from reading or mutating the signed-in user's preferences.
enum VoiceDefaults {
    static let shared: UserDefaults = {
        guard isTestHost else { return .standard }
        let defaults = UserDefaults(suiteName: voiceTestDefaultsSuiteName)!
        defaults.removePersistentDomain(forName: voiceTestDefaultsSuiteName)
        atexit(removeVoiceTestDefaultsDomain)
        return defaults
    }()
}

let delegate: AppDelegate? = isTestHost ? nil : MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(isTestHost ? .prohibited : .regular)
app.run()
