import AppKit

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
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)  // normal Dock app: shows in the Dock, Cmd-Q quits
app.run()
