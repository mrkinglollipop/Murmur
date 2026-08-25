import UIKit

/// Host `keyboardAppearance` wins. Do not sample traits we ourselves paint —
/// that looped the keyboard light↔dark.
enum KeyboardAppearanceResolve {
    static func isDark(
        keyboardAppearance: UIKeyboardAppearance,
        userInterfaceStyle: UIUserInterfaceStyle
    ) -> Bool {
        switch keyboardAppearance {
        case .light:
            return false
        case .dark:
            return true
        default:
            return userInterfaceStyle == .dark
        }
    }
}
