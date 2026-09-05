import AppKit
import SwiftUI

/// SwiftRestic's design tokens — the single place that owns colour, spacing,
/// corner radii and display type, so views never hard-code hex values or raw
/// system colours.
///
/// The brand hue is the app icon's indigo (`0x5C8BFF → 0x3B4FD8 → 0x1E2160`);
/// every colour here is a light/dark dynamic pair whose steps were selected for
/// its own surface rather than flipped from the other, and the status hues are
/// reserved for run state and validation — never decoration.
enum Theme {
    // MARK: Colour

    /// Brand tint: buttons, selection, links, folder glyphs, chart series 1.
    static let tint = dynamic(light: 0x3B4FD8, dark: 0x5C8BFF)

    /// Deeper tint step for gradient hero tiles on either surface.
    static let tintDeep = dynamic(light: 0x2B3AA0, dark: 0x3B4FD8)

    /// Successful completion. Checked runs, healthy plans, "no problems".
    static let success = dynamic(light: 0x177A3D, dark: 0x53C578)

    /// Degraded but not failed. Warnings, skipped work, completed-with-errors.
    static let warning = dynamic(light: 0xA85E0A, dark: 0xE8A33D)

    /// Failure and destructive confirmation.
    static let danger = dynamic(light: 0xC22F2F, dark: 0xF0716F)

    // MARK: Spacing (points)

    enum Space {
        /// Gap between KPI tiles in a row.
        static let tile: CGFloat = 12
        /// Gap between cards in a detail pane.
        static let section: CGFloat = 16
        /// Inner padding of a card.
        static let cardPadding: CGFloat = 14
        /// Padding around a detail pane's content.
        static let pane: CGFloat = 20
    }

    // MARK: Corner radii

    enum Radius {
        static let card: CGFloat = 10
        static let chip: CGFloat = 7
    }

    // MARK: Display type

    /// Numerals that carry a dashboard: large, rounded, tabular.
    static let statValue: Font = .system(.title3, design: .rounded).weight(.semibold)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return nsColor(isDark ? dark : light)
        })
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Surface treatment shared by cards and KPI tiles: an opaque control-coloured
/// plate lifted off the window background by a hairline border.
struct CardSurface: ViewModifier {
    var cornerRadius: CGFloat = Theme.Radius.card

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
            )
    }
}

extension View {
    func cardSurface(cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius))
    }
}
