import XCTest

final class KeyboardChromeMetricsTests: XCTestCase {
    func testPortraitHeightsAtCanonicalWidths() {
        XCTAssertEqual(KeyboardChromeMetrics.metrics(width: 375, isLandscape: false).keyboardHeight, 232)
        XCTAssertEqual(KeyboardChromeMetrics.metrics(width: 402, isLandscape: false).keyboardHeight, 248)
        XCTAssertEqual(KeyboardChromeMetrics.metrics(width: 430, isLandscape: false).keyboardHeight, 260)
    }

    func testLandscapeHeightsAtCanonicalWidths() {
        XCTAssertEqual(KeyboardChromeMetrics.metrics(width: 375, isLandscape: true).keyboardHeight, 162)
        XCTAssertEqual(KeyboardChromeMetrics.metrics(width: 402, isLandscape: true).keyboardHeight, 176)
        XCTAssertEqual(KeyboardChromeMetrics.metrics(width: 430, isLandscape: true).keyboardHeight, 188)
    }

    func testBuckets() {
        XCTAssertEqual(KeyboardChromeMetrics.metrics(width: 375, isLandscape: false).bucket, .compact)
        XCTAssertEqual(KeyboardChromeMetrics.metrics(width: 389, isLandscape: false).bucket, .compact)
        XCTAssertEqual(KeyboardChromeMetrics.metrics(width: 390, isLandscape: false).bucket, .regular)
        XCTAssertEqual(KeyboardChromeMetrics.metrics(width: 402, isLandscape: false).bucket, .regular)
        XCTAssertEqual(KeyboardChromeMetrics.metrics(width: 429, isLandscape: false).bucket, .regular)
        XCTAssertEqual(KeyboardChromeMetrics.metrics(width: 430, isLandscape: false).bucket, .max)
    }

    func testPortraitLetterFonts() {
        XCTAssertEqual(KeyboardChromeMetrics.metrics(width: 375, isLandscape: false).letterFont, 22)
        XCTAssertEqual(KeyboardChromeMetrics.metrics(width: 402, isLandscape: false).letterFont, 24)
        XCTAssertEqual(KeyboardChromeMetrics.metrics(width: 430, isLandscape: false).letterFont, 25)
    }

    func testSpaceVersusModeUnitRatios() {
        let metrics = KeyboardChromeMetrics.metrics(width: 430, isLandscape: false)
        XCTAssertEqual(metrics.spaceUnits / metrics.modeUnits, 5.0 / 1.5, accuracy: 0.0001)
        XCTAssertEqual(metrics.spaceUnitsWithoutEmoji / metrics.modeUnits, 6.25 / 1.5, accuracy: 0.0001)
        XCTAssertEqual(metrics.modeUnits, 1.5)
        XCTAssertEqual(metrics.returnUnits, 1.8)
        XCTAssertEqual(metrics.emojiUnits, 1.25)
    }

    func testGapsScaleWithBucket() {
        let compact = KeyboardChromeMetrics.metrics(width: 375, isLandscape: false)
        let regular = KeyboardChromeMetrics.metrics(width: 402, isLandscape: false)
        let max = KeyboardChromeMetrics.metrics(width: 430, isLandscape: false)
        XCTAssertLessThan(compact.sideInset, regular.sideInset + 2)
        XCTAssertGreaterThan(compact.sideInset, max.sideInset)
        XCTAssertLessThan(compact.rowGap, max.rowGap)
        XCTAssertLessThanOrEqual(compact.keyGap, max.keyGap)
        XCTAssertEqual(max.sideInset, 3)
        XCTAssertEqual(max.rowGap, 12)
        XCTAssertEqual(max.keyGap, 6)
        XCTAssertEqual(max.letterKeyHeight, 43)
        XCTAssertEqual(max.accessoryHeight, 44)
        XCTAssertEqual(max.bottomInset, 8)
    }

    func testChromeTopRadiusIsAppliedOnce() {
        XCTAssertEqual(KeyboardChromeTokens.chromeCornerRadius, 28)
    }

    func testMaxPortraitMatchesTokenWrapper() {
        XCTAssertEqual(
            KeyboardChromeMetrics.metrics(width: 430, isLandscape: false).keyboardHeight,
            KeyboardChromeTokens.portraitHeight
        )
        XCTAssertEqual(
            KeyboardChromeMetrics.metrics(width: 430, isLandscape: true).keyboardHeight,
            KeyboardChromeTokens.landscapeHeight
        )
    }

    func testGifSearchPanelHeights() {
        XCTAssertEqual(KeyboardChromeMetrics.metrics(width: 375, isLandscape: false).gifSearchPanelHeight, 140)
        XCTAssertEqual(KeyboardChromeMetrics.metrics(width: 402, isLandscape: false).gifSearchPanelHeight, 148)
        XCTAssertEqual(KeyboardChromeMetrics.metrics(width: 430, isLandscape: false).gifSearchPanelHeight, 160)
        XCTAssertEqual(KeyboardChromeMetrics.metrics(width: 430, isLandscape: true).gifSearchPanelHeight, 108)
    }
}
