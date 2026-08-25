import UIKit

/// Keyboard-only tokens. Do not import Mac `Theme.swift`.
enum KeyboardChromeTokens {
    static var accessoryHeight: CGFloat {
        KeyboardChromeMetrics.metrics(width: 430, isLandscape: false).accessoryHeight
    }
    static var portraitHeight: CGFloat {
        KeyboardChromeMetrics.metrics(width: 430, isLandscape: false).keyboardHeight
    }
    static var landscapeHeight: CGFloat {
        KeyboardChromeMetrics.metrics(width: 430, isLandscape: true).keyboardHeight
    }
    /// One rounded top on the chrome fill. Do not also round the input view or
    /// add `UIGlassContainerEffect` — that stacked a second card / lip.
    static let chromeCornerRadius: CGFloat = 28
    static let chromeTopCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    static let bottomInset: CGFloat = 6
    static let keyCornerRadius: CGFloat = 8.5
    static let chipCornerRadius: CGFloat = 8
    static let rowGap: CGFloat = 8
    static let keyGap: CGFloat = 6
    static let letterFontSize: CGFloat = 25
    static let specialFontSize: CGFloat = 17
    static let coral = UIColor(red: 0.847, green: 0.353, blue: 0.188, alpha: 1) // #D85A30
    static let coralLight = UIColor(red: 0.941, green: 0.600, blue: 0.482, alpha: 1) // #F0997B

    static func keyboardBackdrop(dark: Bool) -> UIColor {
        dark
            ? UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
            : UIColor(red: 226 / 255, green: 226 / 255, blue: 228 / 255, alpha: 1)
    }

    static func letterKeyFill(dark: Bool) -> UIColor {
        dark ? UIColor(white: 0.50, alpha: 1) : UIColor(white: 1, alpha: 1)
    }

    static func specialKeyFill(dark: Bool) -> UIColor {
        dark ? UIColor(white: 0.22, alpha: 1) : UIColor(red: 0.68, green: 0.70, blue: 0.73, alpha: 1)
    }

    static func keyLip(dark: Bool, special: Bool) -> UIColor {
        if dark {
            return special ? UIColor(white: 0.10, alpha: 1) : UIColor(white: 0.32, alpha: 1)
        }
        return special
            ? UIColor(red: 0.52, green: 0.54, blue: 0.57, alpha: 1)
            : UIColor(white: 0.72, alpha: 1)
    }

    static func keyShadow(dark: Bool) -> UIColor {
        dark ? UIColor.black : UIColor(white: 0.35, alpha: 1)
    }

    static func quickTypeSeparator(dark: Bool) -> UIColor {
        dark ? UIColor(white: 1, alpha: 0.18) : UIColor(white: 0, alpha: 0.18)
    }

    static func pressedKeyFill(dark: Bool) -> UIColor {
        dark ? UIColor(white: 0.62, alpha: 1) : UIColor(white: 0.82, alpha: 1)
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
