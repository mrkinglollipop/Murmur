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
}
