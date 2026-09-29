import XCTest
@testable import Voice

final class DownloadTicketBookTests: XCTestCase {

    func testCancelledDownloadCannotRetireAReDownloadsTicket() {
        var book = DownloadTicketBook()
        let first = book.issue(for: .whisperBase)
        book.revoke(for: .whisperBase)          // delete() cancels
        let second = book.issue(for: .whisperBase)  // user re-downloads

        // The first task's late catch/cleanup must be ignored...
        XCTAssertFalse(book.isCurrent(first, for: .whisperBase))
        XCTAssertFalse(book.retire(first, for: .whisperBase))
        // ...and must not have disturbed the re-download.
        XCTAssertTrue(book.isCurrent(second, for: .whisperBase))
        XCTAssertTrue(book.retire(second, for: .whisperBase))
    }

    func testTicketsAreScopedPerModel() {
        var book = DownloadTicketBook()
        let base = book.issue(for: .whisperBase)
        book.revoke(for: .whisperLargeV3)
        XCTAssertTrue(book.isCurrent(base, for: .whisperBase))
    }

    func testRetireIsOneShot() {
        var book = DownloadTicketBook()
        let id = book.issue(for: .whisperBase)
        XCTAssertTrue(book.retire(id, for: .whisperBase))
        XCTAssertFalse(book.retire(id, for: .whisperBase))
    }
}
