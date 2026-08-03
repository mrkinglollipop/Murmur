import XCTest
@testable import Voice

final class SparkleSupportTests: XCTestCase {

    func testEnabledWhenAllGatesPass() {
        XCTAssertEqual(
            SparkleSupport.classify(
                hasFeed: true,
                hasKey: true,
                bundleSignatureValid: true,
                hasDeveloperID: true
            ),
            .enabled
        )
    }

    func testBrokenSignatureWinsOverMissingFeed() {
        // Seal damage must surface even if Info.plist feed/key look fine —
        // that was the silent grey-menu failure mode.
        XCTAssertEqual(
            SparkleSupport.classify(
                hasFeed: true,
                hasKey: true,
                bundleSignatureValid: false,
                hasDeveloperID: false
            ),
            .brokenSignature
        )
    }

    func testAppleDevelopmentIsNotDeveloperIDNotBroken() {
        XCTAssertEqual(
            SparkleSupport.classify(
                hasFeed: true,
                hasKey: true,
                bundleSignatureValid: true,
                hasDeveloperID: false
            ),
            .notDeveloperID
        )
    }

    func testMissingFeed() {
        XCTAssertEqual(
            SparkleSupport.classify(
                hasFeed: false,
                hasKey: true,
                bundleSignatureValid: true,
                hasDeveloperID: true
            ),
            .missingFeed
        )
    }

    func testMissingKey() {
        XCTAssertEqual(
            SparkleSupport.classify(
                hasFeed: true,
                hasKey: false,
                bundleSignatureValid: true,
                hasDeveloperID: true
            ),
            .missingPublicKey
        )
    }
}
