import XCTest
@testable import Voice

final class AcknowledgementsTests: XCTestCase {

    func testAllAcknowledgementsPresent() {
        XCTAssertEqual(Acknowledgements.all.count, 5)

        let names = Set(Acknowledgements.all.map(\.name))
        XCTAssertTrue(names.contains("WhisperKit"))
        XCTAssertTrue(names.contains("Sparkle"))
        XCTAssertTrue(names.contains("FluidAudio"))
        XCTAssertTrue(names.contains("EB Garamond"))
        XCTAssertTrue(names.contains("Figtree"))
    }

    func testBundledLicenseTextsAreNonEmpty() {
        for item in Acknowledgements.all {
            let text = Acknowledgements.licenseText(for: item)
            XCTAssertGreaterThan(text.count, 100, "Expected bundled license for \(item.name)")
        }
    }
}
