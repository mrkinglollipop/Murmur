import XCTest

final class EmojiCatalogTests: XCTestCase {
    func testCatalogHasEveryCategory() {
        for category in EmojiCatalog.Category.allCases {
            XCTAssertFalse(
                EmojiCatalog.items(in: category).isEmpty,
                "empty category \(category)"
            )
        }
        XCTAssertGreaterThan(EmojiCatalog.all.count, 1000)
    }

    func testSearchFireFindsFire() {
        let glyphs = EmojiCatalog.search(query: "fire").map(\.glyph)
        XCTAssertTrue(glyphs.contains("🔥"))
    }

    func testSearchHeartFindsRedHeart() {
        let glyphs = EmojiCatalog.search(query: "heart").map(\.glyph)
        XCTAssertTrue(glyphs.contains("❤️") || glyphs.contains("❤"))
    }

    func testSearchLolFindsJoy() {
        let glyphs = EmojiCatalog.search(query: "lol").map(\.glyph)
        XCTAssertTrue(glyphs.contains("😂"))
    }

    func testSearchIsCaseInsensitiveAndTokenized() {
        let lower = EmojiCatalog.search(query: "rolling floor").map(\.glyph)
        let upper = EmojiCatalog.search(query: "ROLLING FLOOR").map(\.glyph)
        XCTAssertEqual(lower, upper)
        XCTAssertTrue(lower.contains("🤣"))
    }

    func testBlankSearchIsEmpty() {
        XCTAssertTrue(EmojiCatalog.search(query: "   ").isEmpty)
        XCTAssertTrue(EmojiCatalog.search(query: "").isEmpty)
    }

    func testNoSkinToneModifiers() {
        let skin = CharacterSet(charactersIn: "\u{1F3FB}\u{1F3FC}\u{1F3FD}\u{1F3FE}\u{1F3FF}")
        for item in EmojiCatalog.all {
            XCTAssertNil(
                item.glyph.unicodeScalars.first { skin.contains($0) },
                item.glyph
            )
        }
    }

    func testFallbackRecentsAreNonEmpty() {
        XCTAssertEqual(EmojiCatalog.fallbackRecents.count, 36)
        XCTAssertTrue(EmojiCatalog.fallbackRecents.contains("😂"))
        XCTAssertTrue(EmojiCatalog.fallbackRecents.contains("🔥"))
    }

    func testRememberEmojiCapsAndDedupes() {
        let previous = AppGroupStore.recentEmoji
        defer { AppGroupStore.recentEmoji = previous }
        AppGroupStore.recentEmoji = []
        AppGroupStore.rememberEmoji("🔥")
        AppGroupStore.rememberEmoji("😂")
        AppGroupStore.rememberEmoji("🔥")
        let stored = AppGroupStore.recentEmoji
        XCTAssertEqual(stored.first, "🔥")
        XCTAssertEqual(stored.filter { $0 == "🔥" }.count, 1)
        XCTAssertTrue(stored.contains("😂"))
        XCTAssertLessThanOrEqual(stored.count, 36)
    }
}
