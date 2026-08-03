import XCTest
@testable import Voice

final class PhoneticMatcherTests: XCTestCase {

    func testEncodeVectors() {
        assertEncode("hyzer", primary: "HSR", secondary: nil)
        assertEncode("Heiser", primary: "HSR", secondary: nil)
        assertEncode("Groq", primary: "KRK", secondary: nil)
        assertEncode("grok", primary: "KRK", secondary: nil)
        assertEncode("Kubernetes", primary: "KPRNTS", secondary: nil)
        assertEncode("Kubernettes", primary: "KPRNTS", secondary: nil)
        assertEncode("Schwartz", primary: "XRTS", secondary: "XFRTS")
        assertEncode("wispr", primary: "ASPR", secondary: "FSPR")
        assertEncode("whisper", primary: "ASPR", secondary: nil)
        assertEncode("cat", primary: "KT", secondary: nil)
        assertEncode("kite", primary: "KT", secondary: nil)
        // Regression vectors for the mid-word GH infinite loop (processG once
        // failed to advance on GH-after-vowel at positions 1-2, hanging the
        // encoder on "night") plus the flagship shared-primary pair.
        assertEncode("night", primary: "NT", secondary: nil)
        assertEncode("hyzer", primary: "HSR", secondary: nil)
        assertEncode("Heiser", primary: "HSR", secondary: nil)
    }

    func testGuardAccepts() {
        XCTAssertTrue(PhoneticMatcher.guardAccepts(heard: "cast", candidate: "cost"))
        XCTAssertFalse(PhoneticMatcher.guardAccepts(heard: "cat", candidate: "kite"))
        XCTAssertTrue(PhoneticMatcher.guardAccepts(heard: "wispr", candidate: "whisper"))
        // Flagship case (plans/021 P2): identical primary keys (HSR) relax the
        // lexical bar to 0.4, so similarity 0.5 passes. Without the primary
        // match the strict 0.6 bar applies and the pair is rejected.
        XCTAssertTrue(PhoneticMatcher.guardAccepts(heard: "hyzer", candidate: "Heiser", primaryKeyMatch: true))
        XCTAssertFalse(PhoneticMatcher.guardAccepts(heard: "hyzer", candidate: "Heiser", primaryKeyMatch: false))
    }

    private func assertEncode(
        _ input: String,
        primary: String,
        secondary: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let encoded = PhoneticMatcher.encode(input)
        XCTAssertEqual(encoded.primary, primary, file: file, line: line)
        XCTAssertEqual(encoded.secondary, secondary, file: file, line: line)
    }
}
