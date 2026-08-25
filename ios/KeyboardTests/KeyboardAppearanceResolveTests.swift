import XCTest

final class KeyboardAppearanceResolveTests: XCTestCase {
    func testExplicitLightIgnoresDarkTraits() {
        XCTAssertFalse(
            KeyboardAppearanceResolve.isDark(keyboardAppearance: .light, userInterfaceStyle: .dark)
        )
    }

    func testExplicitDarkIgnoresLightTraits() {
        XCTAssertTrue(
            KeyboardAppearanceResolve.isDark(keyboardAppearance: .dark, userInterfaceStyle: .light)
        )
    }

    func testDefaultFollowsInterfaceStyle() {
        XCTAssertTrue(
            KeyboardAppearanceResolve.isDark(keyboardAppearance: .default, userInterfaceStyle: .dark)
        )
        XCTAssertFalse(
            KeyboardAppearanceResolve.isDark(keyboardAppearance: .default, userInterfaceStyle: .light)
        )
    }
}
