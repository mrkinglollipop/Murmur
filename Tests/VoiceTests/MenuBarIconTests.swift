import XCTest
@testable import Voice

final class MenuBarIconTests: XCTestCase {

    func testEveryStateIsATemplateImageAtMenuBarSize() {
        for icon in [MenuBarIcon.idle, .listening, .processing, .paused, .error] {
            let image = icon.image
            XCTAssertTrue(image.isTemplate, "\(icon)")
            XCTAssertEqual(image.size, NSSize(width: MenuBarIcon.pointSize, height: MenuBarIcon.pointSize), "\(icon)")
            XCTAssertEqual(image.accessibilityDescription, icon.accessibilityDescription, "\(icon)")
        }
    }

    func testPausedIsFlatAndIdleIsNot() {
        XCTAssertEqual(Set(MenuBarIcon.barHeights(for: .paused)).count, 1)
        XCTAssertGreaterThan(Set(MenuBarIcon.barHeights(for: .idle)).count, 1)
    }

    func testBarsFitInsideTheGlyph() {
        for icon in [MenuBarIcon.idle, .listening, .processing, .paused, .error] {
            XCTAssertLessThanOrEqual(MenuBarIcon.barHeights(for: icon).max() ?? 0, MenuBarIcon.pointSize - 4, "\(icon)")
        }
    }

    func testPausedAndErrorAnnounceTheirState() {
        XCTAssertEqual(MenuBarIcon.paused.accessibilityDescription, "Murmur, paused")
        XCTAssertNotEqual(MenuBarIcon.error.accessibilityDescription, MenuBarIcon.idle.accessibilityDescription)
    }
}
