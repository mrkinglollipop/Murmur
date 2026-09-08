import XCTest
@testable import Voice

final class HesitationNormalizerTests: XCTestCase {
    func testRemovesStandaloneHesitationFromLongProse() {
        XCTAssertEqual(
            HesitationNormalizer.normalize("as an, uh, complete audit", codeAware: false, enabled: true),
            "as an, complete audit"
        )
        XCTAssertEqual(
            HesitationNormalizer.normalize("Um, this is a complete audit", codeAware: false, enabled: true),
            "This is a complete audit"
        )
    }

    func testPreservesQuotedCodeAndShortUtterances() {
        XCTAssertEqual(
            HesitationNormalizer.normalize("write 'uh' as a literal token", codeAware: false, enabled: true),
            "write 'uh' as a literal token"
        )
        XCTAssertEqual(
            HesitationNormalizer.normalize("uh config um value now", codeAware: true, enabled: true),
            "uh config um value now"
        )
        XCTAssertEqual(
            HesitationNormalizer.normalize("uh okay", codeAware: false, enabled: true),
            "uh okay"
        )
    }

    func testPreservesQuotedOrIdentifierLikeOccurrences() {
        XCTAssertEqual(
            HesitationNormalizer.normalize("he wrote \"uh 'um' okay\" in the complete note", codeAware: false, enabled: true),
            "he wrote \"uh 'um' okay\" in the complete note"
        )
        XCTAssertEqual(
            HesitationNormalizer.normalize("he started \"uh then finished the complete audit", codeAware: false, enabled: true),
            "he started \"uh then finished the complete audit"
        )
        XCTAssertEqual(
            HesitationNormalizer.normalize("keep uh_config and /uh/path in the complete audit", codeAware: false, enabled: true),
            "keep uh_config and /uh/path in the complete audit"
        )
        XCTAssertEqual(
            HesitationNormalizer.normalize("the letters uh appear in this complete audit", codeAware: false, enabled: true),
            "the letters uh appear in this complete audit"
        )
        XCTAssertEqual(
            HesitationNormalizer.normalize("Keep \"uh  um , yes\" exactly as written", codeAware: false, enabled: true),
            "Keep \"uh  um , yes\" exactly as written"
        )
    }

    func testTextWithoutEligibleHesitationIsByteForByteUnchanged() {
        XCTAssertEqual(
            HesitationNormalizer.normalize("Keep  this , spacing exactly", codeAware: false, enabled: true),
            "Keep  this , spacing exactly"
        )
    }

    func testPreservesInlineCodeWhileRemovingProseHesitation() {
        XCTAssertEqual(
            HesitationNormalizer.normalize("Run `uh --help` and, um, keep the result", codeAware: false, enabled: true),
            "Run `uh --help` and, keep the result"
        )
    }

    func testDisabledLeavesTextUntouched() {
        XCTAssertEqual(
            HesitationNormalizer.normalize("as an, uh, complete audit", codeAware: false, enabled: false),
            "as an, uh, complete audit"
        )
    }
}
