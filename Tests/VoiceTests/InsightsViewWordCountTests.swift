import XCTest
@testable import Voice

final class InsightsViewWordCountTests: XCTestCase {

    func testMetricsWordCount_multilineText() {
        let text = "one two\nthree\n\nfour five"
        XCTAssertEqual(InsightsView.metricsWordCount(text), 5)
    }

    func testMetricsWordCount_whitespaceOnlyReturnsZero() {
        XCTAssertEqual(InsightsView.metricsWordCount("  \n\t  "), 0)
    }

    func testMetricsWordCount_singleSpaceSeparated() {
        XCTAssertEqual(InsightsView.metricsWordCount("hello world"), 2)
    }
}
