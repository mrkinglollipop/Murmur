import XCTest

final class ReturnAppCatalogTests: XCTestCase {
    func testDefaultIDsAreKnownAndOrdered() {
        XCTAssertEqual(
            ReturnAppCatalog.defaultBundleIDs,
            [
                HostFingerprint.messagesBundle,
                HostFingerprint.notesBundle,
                HostFingerprint.mailBundle,
                HostFingerprint.safariBundle,
                "com.atebits.Tweetie2"
            ]
        )
        for id in ReturnAppCatalog.defaultBundleIDs {
            XCTAssertTrue(ReturnAppCatalog.knownBundleIDs.contains(id))
        }
    }

    func testSanitizeKeepsCustomIDsDropsMurmurAndDuplicates() {
        XCTAssertEqual(
            ReturnAppCatalog.sanitizedIDs([
                HostFingerprint.messagesBundle,
                "com.burbn.instagram",
                "  com.burbn.instagram  ",
                "",
                "com.matt.murmur.ios",
                "com.matt.murmur.ios.keyboard",
                HostFingerprint.notesBundle
            ]),
            [
                HostFingerprint.messagesBundle,
                "com.burbn.instagram",
                HostFingerprint.notesBundle
            ]
        )
        XCTAssertFalse(ReturnAppCatalog.isAllowed("com.matt.murmur.ios"))
        XCTAssertTrue(ReturnAppCatalog.isAllowed("com.burbn.instagram"))
    }

    func testMissingKeyUsesDefaultsEmptyKeyIsSwipeOnly() {
        XCTAssertEqual(
            ReturnAppCatalog.resolvedIDs(stored: nil, keyExists: false),
            ReturnAppCatalog.defaultBundleIDs
        )
        XCTAssertEqual(ReturnAppCatalog.resolvedIDs(stored: [], keyExists: true), [])
        XCTAssertEqual(
            ReturnAppCatalog.resolvedIDs(stored: [HostFingerprint.safariBundle], keyExists: true),
            [HostFingerprint.safariBundle]
        )
        XCTAssertEqual(
            ReturnAppCatalog.resolvedIDs(stored: ["com.burbn.instagram"], keyExists: true),
            ["com.burbn.instagram"]
        )
    }

    func testAppsFollowStoreOrderIncludingUnknown() {
        let apps = ReturnAppCatalog.apps(enabledIDs: [
            "com.burbn.instagram",
            HostFingerprint.safariBundle,
            HostFingerprint.messagesBundle
        ])
        XCTAssertEqual(apps.map(\.bundleID), [
            "com.burbn.instagram",
            HostFingerprint.safariBundle,
            HostFingerprint.messagesBundle
        ])
        XCTAssertEqual(apps[0].title, "Instagram")
        XCTAssertEqual(ReturnAppCatalog.displayTitle(for: HostFingerprint.messagesBundle), "Messages")
        XCTAssertEqual(ReturnAppCatalog.displayTitle(for: "com.hammerandchisel.discord"), "Discord")
        XCTAssertEqual(ReturnAppCatalog.displayTitle(for: "com.facebook.Facebook"), "Facebook")
        XCTAssertEqual(ReturnAppCatalog.displayTitle(for: "com.google.Gmail"), "Gmail")
        XCTAssertEqual(ReturnAppCatalog.displayTitle(for: "co.anysphere.sand"), "Grok Bot")
        XCTAssertEqual(ReturnAppCatalog.displayTitle(for: "com.anthropic.claude"), "Claude")
        XCTAssertEqual(ReturnAppCatalog.displayTitle(for: "co.anysphere.cursor"), "Cursor")
        XCTAssertTrue(ReturnAppCatalog.knownBundleIDs.contains("com.anthropic.claude"))
        XCTAssertTrue(ReturnAppCatalog.knownBundleIDs.contains("co.anysphere.cursor"))
        XCTAssertTrue(ReturnAppCatalog.knownBundleIDs.contains("co.anysphere.sand"))
        XCTAssertNil(ReturnAppCatalog.schemeURL(for: "co.anysphere.sand"))
        XCTAssertNil(ReturnAppCatalog.schemeURL(for: "com.anthropic.claude"))
        XCTAssertNil(ReturnAppCatalog.schemeURL(for: "co.anysphere.cursor"))
        XCTAssertEqual(ReturnAppCatalog.schemeURL(for: "com.google.Gmail")?.absoluteString, "googlegmail://")
    }

    func testSchemeFallbackForMessagesAndNotes() {
        XCTAssertEqual(
            ReturnAppCatalog.schemeURL(for: HostFingerprint.messagesBundle)?.absoluteString,
            "sms:"
        )
        XCTAssertEqual(
            ReturnAppCatalog.schemeURL(for: HostFingerprint.notesBundle)?.absoluteString,
            "mobilenotes://"
        )
        XCTAssertEqual(
            ReturnAppCatalog.schemeURL(for: "com.atebits.Tweetie2")?.absoluteString,
            "twitter://"
        )
    }

    func testReorderMovesOntoTargetAndPreservesOthers() {
        let start = ["a.one", "a.two", "a.three"]
        XCTAssertEqual(
            ReturnAppCatalog.reorderedIDs(start, moving: "a.one", onto: "a.three"),
            ["a.two", "a.three", "a.one"]
        )
        XCTAssertEqual(
            ReturnAppCatalog.reorderedIDs(start, moving: "a.three", onto: "a.one"),
            ["a.three", "a.one", "a.two"]
        )
        XCTAssertEqual(
            ReturnAppCatalog.reorderedIDs(start, moving: "a.one", onto: "a.one"),
            start
        )
    }
}
