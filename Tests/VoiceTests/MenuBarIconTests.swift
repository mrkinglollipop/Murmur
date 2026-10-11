import AppKit
import XCTest
@testable import Voice

final class MenuBarIconTests: XCTestCase {

    @MainActor
    func testPreviousErrorExpiryPreservesNewListeningState() throws {
        guard isTestHost else {
            XCTFail("AppDelegate tests require isolated test-host stores and defaults")
            return
        }
        let delegate = AppDelegate()
        let button = NSStatusBarButton(frame: .zero)
        delegate.menuBarButton = button
        var expiries: [() -> Void] = []
        delegate.scheduleMenuBarErrorBadgeExpiry = { expiries.append($0) }

        delegate.handleDictationFailure(.transcriptionFailed)
        XCTAssertEqual(button.accessibilityLabel(), "Murmur — error")
        let previousExpiry = try XCTUnwrap(expiries.first)

        delegate.updateMenuBarIcon(for: .listening)
        XCTAssertEqual(button.accessibilityLabel(), "Murmur, listening")
        previousExpiry()

        XCTAssertEqual(button.accessibilityLabel(), "Murmur, listening")
        XCTAssertEqual(button.image?.accessibilityDescription, "Murmur, listening")
    }

    func testEveryStateIsATemplateImageAtMenuBarSize() {
        for icon in [MenuBarIcon.idle, .listening, .processing, .paused, .error] {
            let image = icon.image
            XCTAssertTrue(image.isTemplate, "\(icon)")
            XCTAssertEqual(image.size, NSSize(width: MenuBarIcon.pointSize, height: MenuBarIcon.pointSize), "\(icon)")
            XCTAssertEqual(image.accessibilityDescription, icon.accessibilityDescription, "\(icon)")
        }
    }

    func testRecordingStatesHaveDistinctAccessibilityDescriptions() {
        let descriptions = [MenuBarIcon.idle, .listening, .processing].map(\.accessibilityDescription)
        XCTAssertEqual(Set(descriptions).count, 3)
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
