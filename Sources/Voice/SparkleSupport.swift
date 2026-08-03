import Foundation
import Security

/// Sparkle requires a Developer ID–signed app, a real appcast feed, and a
/// non-empty SUPublicEDKey. Ad-hoc / Apple Development / placeholder builds
/// skip the updater so launch is not blocked by XPC errors.
///
/// A *broken* sealed-resource signature (orphan files left by a merge-install)
/// also fails the Developer ID gate — and is called out separately so launch
/// can alert instead of silently greying "Check for Updates…".
enum SparkleSupport {

    enum Status: Equatable {
        case enabled
        case missingFeed
        case missingPublicKey
        /// Bundle seal invalid (e.g. leftover `*.bak` after `ditto` merge).
        case brokenSignature
        /// Valid signature but not Developer ID Application (Xcode / ad-hoc).
        case notDeveloperID
    }

    static var isEnabled: Bool { status == .enabled }

    static var status: Status {
        classify(
            hasFeed: hasRealFeedURL,
            hasKey: hasNonEmptyPublicEDKey,
            bundleSignatureValid: isBundleSignatureValid,
            hasDeveloperID: hasDeveloperIDSignature
        )
    }

    /// Pure gate — unit-tested without Security.framework.
    static func classify(
        hasFeed: Bool,
        hasKey: Bool,
        bundleSignatureValid: Bool,
        hasDeveloperID: Bool
    ) -> Status {
        if !bundleSignatureValid { return .brokenSignature }
        if !hasFeed { return .missingFeed }
        if !hasKey { return .missingPublicKey }
        if !hasDeveloperID { return .notDeveloperID }
        return .enabled
    }

    private static var hasRealFeedURL: Bool {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
            return false
        }
        let trimmed = feed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !trimmed.contains("example.com")
    }

    private static var hasNonEmptyPublicEDKey: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            return false
        }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when the *app bundle* signature verifies (resources + nested code).
    /// Orphan files under Contents/ (merge-install leftovers) fail this.
    private static var isBundleSignatureValid: Bool {
        let url = Bundle.main.bundleURL
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return false }
        // Check nested code (Sparkle.framework XPCs) the same way `codesign --deep` does.
        let flags = SecCSFlags(rawValue: kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
    }

    /// True only for Developer ID Application–signed binaries.
    /// Rejects Apple Development, ad-hoc, and unsigned (team ID alone is not enough).
    /// Also fails when the bundle seal is broken.
    private static var hasDeveloperIDSignature: Bool {
        guard let url = Bundle.main.executableURL else { return false }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return false }

        // Leaf OID 1.2.840.113635.100.6.1.13 = Developer ID Application
        // (not Apple Development / Mac App Store).
        var requirement: SecRequirement?
        let req =
            "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13]"
            as CFString
        guard SecRequirementCreateWithString(req, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
