import XCTest

final class HostFingerprintTests: XCTestCase {
    func testChatKitIsMessagesAndCloudKitIsNot() {
        XCTAssertEqual(
            HostFingerprint.bundleID(fromClassNames: ["CKMessageEntryRichTextView"]),
            HostFingerprint.messagesBundle
        )
        XCTAssertEqual(
            HostFingerprint.bundleID(fromClassNames: ["CKBrowserSwitcherViewController"]),
            HostFingerprint.messagesBundle
        )
        XCTAssertNil(HostFingerprint.bundleID(fromClassNames: ["CKRecord", "CKContainer"]))
    }

    func testNotesMailSafariAndProcessPaths() {
        XCTAssertEqual(
            HostFingerprint.bundleID(fromClassNames: ["ICNoteEditorViewController"]),
            HostFingerprint.notesBundle
        )
        XCTAssertEqual(
            HostFingerprint.bundleID(fromClassNames: ["MFComposeRecipientView"]),
            HostFingerprint.mailBundle
        )
        XCTAssertEqual(
            HostFingerprint.bundleID(fromClassNames: ["WKContentView"]),
            HostFingerprint.safariBundle
        )
        XCTAssertEqual(
            HostFingerprint.bundleID(fromProcessPath: "/Applications/MobileSMS.app/MobileSMS"),
            HostFingerprint.messagesBundle
        )
        XCTAssertEqual(
            HostFingerprint.bundleID(fromProcessPath: "MobileSMS"),
            HostFingerprint.messagesBundle
        )
        XCTAssertEqual(
            HostFingerprint.bundleID(fromProcessPath: "Notes"),
            HostFingerprint.notesBundle
        )
        XCTAssertEqual(
            HostFingerprint.bundleID(fromProcessPath: "MobileNotes"),
            HostFingerprint.notesBundle
        )
        XCTAssertEqual(
            HostFingerprint.bundleID(
                fromProcessPath: "<NSXPCConnection: 0x1> connection from pid 11908 named MobileSMS"
            ),
            HostFingerprint.messagesBundle
        )
        XCTAssertEqual(
            HostFingerprint.bundleID(fromProcessPath: "com.apple.MobileNotes.viewservice"),
            HostFingerprint.notesBundle
        )
        XCTAssertTrue(
            HostFingerprint.dictationHostBundleIDs.contains(HostFingerprint.messagesBundle)
        )
    }

    func testChatKitWinsOverWebKitInTheSameList() {
        XCTAssertEqual(
            HostFingerprint.bundleID(fromClassNames: ["WKContentView", "CKMessageEntryView"]),
            HostFingerprint.messagesBundle
        )
    }
}
