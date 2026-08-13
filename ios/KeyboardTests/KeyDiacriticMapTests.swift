import XCTest

final class KeyDiacriticMapTests: XCTestCase {
    func testVowelsIncludeExpectedMarks() {
        assertContains("a", "à")
        assertContains("e", "é")
        assertContains("i", "î")
        assertContains("o", "ö")
        assertContains("u", "ü")
    }

    func testExtraLatinLetters() {
        assertContains("n", "ñ")
        assertContains("c", "ç")
        assertContains("s", "ß")
        assertContains("y", "ÿ")
        assertContains("z", "ž")
    }

    func testUnknownLetterIsEmpty() {
        XCTAssertEqual(KeyDiacriticMap.alternatives(for: "q"), [])
        XCTAssertEqual(KeyDiacriticMap.alternatives(for: "1"), [])
        XCTAssertEqual(KeyDiacriticMap.alternatives(for: ""), [])
        XCTAssertEqual(KeyDiacriticMap.alternatives(for: "ee"), [])
    }

    func testPreservesCase() {
        let upper = KeyDiacriticMap.alternatives(for: "E")
        XCTAssertEqual(upper.first, "E")
        XCTAssertTrue(upper.contains("É"))
        XCTAssertFalse(upper.contains("é"))
    }

    func testBaseGlyphIsFirst() {
        XCTAssertEqual(KeyDiacriticMap.alternatives(for: "a").first, "a")
        XCTAssertEqual(KeyDiacriticMap.alternatives(for: "N").first, "N")
    }

    private func assertContains(_ glyph: String, _ expected: String) {
        let alts = KeyDiacriticMap.alternatives(for: glyph)
        XCTAssertTrue(alts.contains(expected), "\(glyph) should include \(expected); got \(alts)")
    }
}
