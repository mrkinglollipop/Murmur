import Foundation
import CoreText
import os.log

// MARK: - Bundled Font Registration

/// Registers the bundled `.ttf` files (EB Garamond, Figtree — see
/// `Resources/Fonts/`) with Core Text at process launch, so SwiftUI's
/// `Font.custom("EB Garamond", size:)` / `Font.custom("Figtree", size:)`
/// resolve to the real bundled faces instead of falling back to system fonts.
///
/// Uses `CTFontManagerRegisterFontsForURL` directly rather than relying on
/// `ATSApplicationFontsPath` in Info.plist — that plist key only scans a
/// single flat directory relative to the bundle's Resources root, and its
/// exact bundle-layout behavior (does it recurse into `Fonts/`? does xcodegen
/// preserve the `Fonts/` subdirectory instead of flattening it into
/// Resources/?) isn't guaranteed without testing per build. Enumerating and
/// registering programmatically works regardless of where the resources
/// build phase places the files inside the bundle.
enum FontRegistrar {

    private static let logger = Logger(subsystem: "com.matt.voice-dictation", category: "fonts")

    /// Registers every `.ttf` found in the app bundle (recursively, so this
    /// works whether xcodegen flattens `Resources/Fonts/*.ttf` into the
    /// bundle root or preserves the `Fonts/` subdirectory). Safe to call more
    /// than once — `CTFontManagerRegisterFontsForURL` reports "already
    /// registered" as a (harmless, ignored) error rather than crashing.
    static func registerBundledFonts() {
        let fontURLs = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil)
            ?? []
        // Some resource layouts nest the fonts under a "Fonts" subdirectory
        // instead of flattening them into the Resources root — check both so
        // registration doesn't silently no-op if xcodegen changes layout.
        let nestedFontURLs = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts")
            ?? []

        let allURLs = Set(fontURLs).union(nestedFontURLs)

        guard !allURLs.isEmpty else {
            logger.error("FontRegistrar: no bundled .ttf files found — falling back to system fonts.")
            return
        }

        for url in allURLs {
            var cfError: Unmanaged<CFError>?
            let success = CTFontManagerRegisterFontsForURL(
                url as CFURL,
                .process,
                &cfError
            )
            if success {
                logger.info("FontRegistrar: registered \(url.lastPathComponent, privacy: .public)")
            } else if let cfError {
                let nsError = cfError.takeRetainedValue() as Error as NSError
                // errSecDuplicateItem-style "already registered" is expected
                // on repeated calls (e.g. multiple AppDelegate paths) — log
                // at info, not error, to avoid noise.
                logger.info("FontRegistrar: \(url.lastPathComponent, privacy: .public) registration result: \(nsError.localizedDescription, privacy: .public)")
            }
        }
    }
}
