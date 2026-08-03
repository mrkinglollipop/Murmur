import AppKit
import SwiftUI

/// Design tokens for the main window UI, matching the approved dark-first
/// Liquid Glass mockup (`plans/015-briefs/mockup-v3.html` — the HTML comment
/// block at the top of that file is the authoritative spec: palette, glass
/// emulation tokens, per-frame layout). The floating HUD pill is a separate
/// dark surface and is untouched by this file.
enum Theme {

    // MARK: - Colors

    /// Screen background — #101014.
    static let bg = Color(red: 0.063, green: 0.063, blue: 0.078)

    /// Flat surface wash — rgba(255,255,255,0.07), the mockup's glass-fill
    /// emulation token. Real surfaces use `.murmurGlassCard()` et al (live
    /// Liquid Glass); this remains for literal-fill uses like hover states
    /// and as the emulation reference for offscreen render harnesses.
    static let surface = Color.white.opacity(0.07)

    /// Active icon / link / highlight accent — #F0997B. (The mockup's coral
    /// fill #D85A30 is `lavender` below; this is the lighter "active state"
    /// coral used for icons, tinted text, and progress/selection tints.)
    static let primary = Color(red: 0.941, green: 0.600, blue: 0.482)

    /// Coral fill accent for CTA pills and selection backgrounds — #D85A30.
    /// Named `lavender` for historical reasons (pre-retheme this held the
    /// light-lavender selection color); kept to avoid a call-site rename
    /// across every view during a color-only retheme.
    static let lavender = Color(red: 0.847, green: 0.353, blue: 0.188)

    /// Text/icon color for content sitting on a `lavender` coral fill —
    /// #f5f5f7 (same as `textPrimary`; near-white reads cleanly on solid
    /// coral, unlike the old deep-purple-on-light-lavender pairing).
    static let lavenderText = Color(red: 0.961, green: 0.961, blue: 0.969)

    /// Primary text color — #f5f5f7.
    static let textPrimary = Color(red: 0.961, green: 0.961, blue: 0.969)

    /// Secondary / muted text color — #9a9aa2.
    static let textSecondary = Color(red: 0.604, green: 0.604, blue: 0.635)

    /// Hairline / divider color — rgba(255,255,255,0.10). Also the unselected
    /// outline on glass cards (the selected outline uses coral `lavender`).
    static let hairline = Color.white.opacity(0.10)

    /// Amber accent for "not injected / left on clipboard" rows — a dark
    /// glass wash. Same amber hue as the pre-retheme light palette
    /// (#ffa946), just re-balanced for dark-bg contrast: the fill becomes a
    /// translucent wash instead of a pale cream, and the text lightens
    /// (the old #a05e10 dark-amber-on-cream would be near-invisible on
    /// #101014).
    static let amberBg = Color(red: 1.0, green: 0.663, blue: 0.275).opacity(0.14)
    /// Failed-row wash at `amberBg` × 0.6 — avoids double-attenuating at call sites.
    static let amberBgSubtle = Color(red: 1.0, green: 0.663, blue: 0.275).opacity(0.084)
    static let amberBorder = Color(red: 1.0, green: 0.663, blue: 0.275) // #ffa946
    static let amberText = Color(red: 0.949, green: 0.722, blue: 0.502) // lightened for dark-bg contrast

    /// Success accent — #1D9E75.
    static let successGreen = Color(red: 0.114, green: 0.620, blue: 0.459)

    /// Record-in-progress / error accent — #E24B4A. Doubles as the "failed
    /// transcription" indicator in History (previously a bare `Color.red`).
    static let recordRed = Color(red: 0.886, green: 0.294, blue: 0.290)

    // MARK: - Glass surface

    /// Coral selection tint applied to glass (sidebar selection pill,
    /// selected list rows) — the mockup's Dictate-key coral glass
    /// rgba(216,90,48,0.82) family.
    static let selectionTint = lavender.opacity(0.82)

    // MARK: - Typography

    /// Serif display font — bundled EB Garamond (`Resources/Fonts/EBGaramond.ttf`
    /// + `EBGaramond-Italic.ttf`, registered at launch by `FontRegistrar`).
    /// `Font.custom` falls back to the system serif automatically if the
    /// family name isn't registered (e.g. registration failed), so this stays
    /// safe even if the bundled font is ever missing.
    static func serifTitle(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .custom("EB Garamond", size: size)
            .weight(weight)
    }

    /// Default body font — bundled Figtree (`Resources/Fonts/Figtree.ttf` +
    /// `Figtree-Italic.ttf`, registered at launch by `FontRegistrar`). Falls
    /// back to the system sans if "Figtree" isn't registered.
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Figtree", size: size)
            .weight(weight)
    }

    // MARK: - Metrics

    static let cornerRadiusWindow: CGFloat = 12
    static let cornerRadiusCard: CGFloat = 10
    static let cornerRadiusCompact: CGFloat = 8
    static let cornerRadiusPill: CGFloat = 99

    /// Duration before copy-to-clipboard confirm icons revert to default.
    static let copyConfirmSeconds: TimeInterval = 1.2

    // MARK: - Accessibility

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// Returns a standard ease-out animation, or `nil` when Reduce Motion is on.
    static func easeOutOrNil(duration: Double = 0.2) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: duration)
    }
}

// MARK: - Glass card modifiers

// Deployment floor is macOS 26 (plan 015: all-in Liquid Glass) — these use
// the real `.glassEffect(_:in:)` API unconditionally; the old macOS 14–15
// flat rgba fallback branches are gone. Wrap clusters of these (chip rows,
// card lists, button groups) in a `GlassEffectContainer` at the call site so
// adjacent glass shapes sample and blend correctly.

extension View {
    /// Applies the card/list Liquid Glass surface at the given corner
    /// radius. Pass `tint` for a colored glass (e.g.
    /// `Theme.selectionTint` on selected rows).
    func murmurGlassCard(cornerRadius: CGFloat = Theme.cornerRadiusCard, tint: Color? = nil) -> some View {
        Group {
            if Theme.reduceTransparency {
                self
                    .background(tint ?? Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                glassEffect(
                    tint.map { Glass.regular.tint($0) } ?? .regular,
                    in: RoundedRectangle(cornerRadius: cornerRadius)
                )
            }
        }
    }

    /// Applies the Liquid Glass surface clipped to a capsule (chips,
    /// pills). Pass `tint` for colored glass.
    func murmurGlassCapsule(tint: Color? = nil) -> some View {
        Group {
            if Theme.reduceTransparency {
                self
                    .background(tint ?? Theme.surface)
                    .clipShape(Capsule())
            } else {
                glassEffect(
                    tint.map { Glass.regular.tint($0) } ?? .regular,
                    in: Capsule()
                )
            }
        }
    }

    /// Full-bleed Liquid Glass panel (sidebar-adjacent panes, editor
    /// surfaces) — square-cornered glass.
    func murmurGlassPanel() -> some View {
        Group {
            if Theme.reduceTransparency {
                self.background(Theme.surface)
            } else {
                glassEffect(.regular, in: Rectangle())
            }
        }
    }
}
