import XCTest
@testable import Voice

final class DotCompoundNumberNormalizerTests: XCTestCase {

    func testAllNumberWords() {
        let cases: [(String, String)] = [
            ("flux.zero", "flux.0"),
            ("flux.one", "flux.1"),
            ("flux.two", "flux.2"),
            ("flux.three", "flux.3"),
            ("flux.four", "flux.4"),
            ("flux.five", "flux.5"),
            ("flux.six", "flux.6"),
            ("flux.seven", "flux.7"),
            ("flux.eight", "flux.8"),
            ("flux.nine", "flux.9"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(DotCompoundNumberNormalizer.apply(input), expected, "Failed for \(input)")
        }
    }

    func testMixedCaseNumberWord() {
        XCTAssertEqual(DotCompoundNumberNormalizer.apply("flux.ONE"), "flux.1")
    }

    func testMultipleDotCompoundsInSentence() {
        XCTAssertEqual(
            DotCompoundNumberNormalizer.apply("see flux.one and v.two here"),
            "see flux.1 and v.2 here"
        )
    }

    func testChapterOneUnchanged() {
        XCTAssertEqual(DotCompoundNumberNormalizer.apply("chapter one"), "chapter one")
    }

    func testSpaceAfterDotUnchanged() {
        XCTAssertEqual(DotCompoundNumberNormalizer.apply("i.e. one"), "i.e. one")
    }

    func testBareNumberWordUnchanged() {
        XCTAssertEqual(DotCompoundNumberNormalizer.apply("one"), "one")
    }

    func testDecimalVersionUnchanged() {
        XCTAssertEqual(
            DotCompoundNumberNormalizer.apply("version 2.5"),
            "version 2.5"
        )
    }
}
