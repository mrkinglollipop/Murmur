import XCTest

final class SpokenCapitalizationTests: XCTestCase {
    func testLockedGoldenSingleCapital() {
        XCTAssertEqual(
            SpokenCapitalization.apply("api key for x capital x"),
            "api key for X"
        )
    }

    func testPreservesCommasWhenNoCommand() {
        XCTAssertEqual(
            SpokenCapitalization.apply("Hello, world"),
            "Hello, world"
        )
    }

    func testBareNATOWordIsNotALetter() {
        XCTAssertEqual(
            SpokenCapitalization.apply("book a hotel tonight"),
            "book a hotel tonight"
        )
    }
}

final class DotCompoundNumberNormalizerTests: XCTestCase {
    func testFluxOne() {
        XCTAssertEqual(DotCompoundNumberNormalizer.apply("flux.one"), "flux.1")
    }

    func testChapterOneUnchanged() {
        XCTAssertEqual(DotCompoundNumberNormalizer.apply("chapter one"), "chapter one")
    }
}

final class TranscriptPostProcessorTests: XCTestCase {
    func testCapsThenDotCompound() {
        XCTAssertEqual(
            TranscriptPostProcessor.applySpokenPasses("see flux.one for x capital x"),
            "see flux.1 for X"
        )
    }

    func testIdentityWhenNothingApplies() {
        XCTAssertEqual(
            TranscriptPostProcessor.applySpokenPasses("Hello, world"),
            "Hello, world"
        )
    }
}
