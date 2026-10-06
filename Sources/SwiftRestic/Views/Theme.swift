import SwiftUI

/// SwiftRestic's design tokens — the single place that owns colour, spacing and
/// corner radii, so views never repeat literal values.
///
/// Colour is deliberately native: the app follows the user's system accent and
/// Apple's semantic status colours, which adapt to appearance and Increase
/// Contrast on their own. Only geometry (spacing, radii, type) is custom.
enum Theme {
    // MARK: Colour

    /// Brand tint: follows the accent colour chosen in System Settings.
    static let tint = Color.accentColor

    /// Successful completion. Checked runs, healthy plans, "no problems".
    static let success = Color.green

    /// Degraded but not failed. Warnings, skipped work, completed-with-errors.
    static let warning = Color.orange

    /// Failure and destructive confirmation.
    static let danger = Color.red

    // MARK: Spacing (points)

    enum Space {
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
}

/// Surface treatment shared by cards and KPI tiles: an opaque control-coloured
/// plate lifted off the window background by a hairline border.
struct CardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
            )
    }
}

extension View {
    func cardSurface() -> some View {
        modifier(CardSurface())
    }
}
