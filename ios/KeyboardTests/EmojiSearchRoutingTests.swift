import XCTest

final class EmojiSearchRoutingTests: XCTestCase {
    func testShowsCategoryBarInSearchAndGrid() {
        XCTAssertTrue(EmojiSearchRouting.showsCategoryBar(isSearchMode: true))
        XCTAssertTrue(EmojiSearchRouting.showsCategoryBar(isSearchMode: false))
    }

    func testConsumeDeleteInSearchNeverForwardsToHost() {
        XCTAssertTrue(EmojiSearchRouting.consumeDelete(isSearchMode: true, searchIsEmpty: true))
        XCTAssertTrue(EmojiSearchRouting.consumeDelete(isSearchMode: true, searchIsEmpty: false))
    }

    func testConsumeDeleteOutsideSearchForwardsToHost() {
        XCTAssertFalse(EmojiSearchRouting.consumeDelete(isSearchMode: false, searchIsEmpty: true))
        XCTAssertFalse(EmojiSearchRouting.consumeDelete(isSearchMode: false, searchIsEmpty: false))
    }
}
