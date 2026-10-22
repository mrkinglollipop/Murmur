import AppKit
import XCTest
@testable import Voice

final class TransformClipboardTests: XCTestCase {

    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard.withUniqueName()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    func testCopiesResultWhenClipboardUnchanged() {
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        let started = pasteboard.changeCount

        XCTAssertTrue(TransformRunner.copyResultIfClipboardUnchanged("result", on: pasteboard, startedAtChangeCount: started))
        XCTAssertEqual(pasteboard.string(forType: .string), "result")
    }

    func testLateResultDoesNotClobberNewerCopy() {
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        let started = pasteboard.changeCount

        pasteboard.clearContents()
        pasteboard.setString("copied on iPhone while transform ran", forType: .string)

        XCTAssertFalse(TransformRunner.copyResultIfClipboardUnchanged("result", on: pasteboard, startedAtChangeCount: started))
        XCTAssertEqual(pasteboard.string(forType: .string), "copied on iPhone while transform ran")
    }

    func testMurmurOwnPasteLaneAndDeferredRestoreDoNotBlockResult() {
        TextInjector.resetOwnedChangeCountsForTesting()
        pasteboard.clearContents()
        pasteboard.setString("user clip", forType: .string)
        let saved = TextInjector.pasteboardSnapshot(from: pasteboard)
        let started = pasteboard.changeCount

        TextInjector.preparePasteboardForPaste("dictated", on: pasteboard)
        var scheduled: (() -> Void)?
        TextInjector.scheduleDeferredPasteboardRestore(
            injectedText: "dictated", savedPasteboard: saved, on: pasteboard,
            asyncAfter: { _, work in scheduled = work }
        )
        scheduled?()
        XCTAssertEqual(pasteboard.string(forType: .string), "user clip")
        XCTAssertNotEqual(pasteboard.changeCount, started)

        XCTAssertTrue(TransformRunner.copyResultIfClipboardUnchanged("result", on: pasteboard, startedAtChangeCount: started))
        XCTAssertEqual(pasteboard.string(forType: .string), "result")
    }

    func testUserCopyDuringMurmurWritesStillSkipsResult() {
        TextInjector.resetOwnedChangeCountsForTesting()
        pasteboard.clearContents()
        pasteboard.setString("user clip", forType: .string)
        let started = pasteboard.changeCount

        TextInjector.preparePasteboardForPaste("dictated", on: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("real user copy", forType: .string)

        XCTAssertFalse(TransformRunner.copyResultIfClipboardUnchanged("result", on: pasteboard, startedAtChangeCount: started))
        XCTAssertEqual(pasteboard.string(forType: .string), "real user copy")
    }
}
