import SwiftUI

enum AppTheme {
    static let bg = Color(red: 0.937, green: 0.937, blue: 0.941)
    static let card = Color.white
    static let hero = Color(red: 0.965, green: 0.949, blue: 0.925)
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let muted = Color(red: 0.45, green: 0.45, blue: 0.48)
    static let hairline = Color.black.opacity(0.08)
    static let coral = Color(red: 0.847, green: 0.353, blue: 0.188)
    static let failed = Color(red: 0.85, green: 0.42, blue: 0.18)
    static let cardRadius: CGFloat = 22
    static let pillRadius: CGFloat = 28

    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}
