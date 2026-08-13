import UIKit

/// Keyboard-only tokens. Do not import Mac `Theme.swift`.
enum KeyboardChromeTokens {
    static let accessoryHeight: CGFloat = 48
    static let portraitHeight: CGFloat = 296
    static let landscapeHeight: CGFloat = 188
    static let chromeCornerRadius: CGFloat = 24
    static let bottomInset: CGFloat = 14
    static let keyCornerRadius: CGFloat = 9
    static let chipCornerRadius: CGFloat = 10
    static let rowGap: CGFloat = 7
    static let keyGap: CGFloat = 5
    static let letterFontSize: CGFloat = 22
    static let specialFontSize: CGFloat = 15
    static let coral = UIColor(red: 0.847, green: 0.353, blue: 0.188, alpha: 1) // #D85A30
    static let coralLight = UIColor(red: 0.941, green: 0.600, blue: 0.482, alpha: 1) // #F0997B

    static func keyboardBackdrop(dark: Bool) -> UIColor {
        dark
            ? UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
            : UIColor(red: 0.82, green: 0.83, blue: 0.85, alpha: 1)
    }

    static func letterKeyFill(dark: Bool) -> UIColor {
        dark ? UIColor(white: 0.28, alpha: 0.92) : UIColor(white: 1, alpha: 0.92)
    }

    static func specialKeyFill(dark: Bool) -> UIColor {
        dark ? UIColor(white: 0.20, alpha: 0.92) : UIColor(red: 0.68, green: 0.70, blue: 0.73, alpha: 0.95)
    }

    static func pressedKeyFill(dark: Bool) -> UIColor {
        dark ? UIColor(white: 0.50, alpha: 1) : UIColor(white: 0.82, alpha: 1)
    }

    static func glyphColor(dark: Bool) -> UIColor {
        dark ? .white : .black
    }

    static func listeningFill(dark: Bool) -> UIColor {
        dark
            ? UIColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1)
            : UIColor(red: 0.88, green: 0.89, blue: 0.91, alpha: 1)
    }

    static func candidateFill(dark: Bool) -> UIColor {
        dark ? UIColor(white: 0.22, alpha: 0.85) : UIColor(white: 1, alpha: 0.72)
    }
}
