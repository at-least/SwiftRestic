import SwiftUI

/// Colour is native: the app follows the user's system accent and Apple's
/// semantic status colours, which adapt to appearance and Increase Contrast
/// on their own. Only geometry (spacing, radii, type) is custom.
enum Theme {
    static let tint = Color.accentColor

    /// Successful completion. Checked runs, healthy plans, "no problems".
    static let success = Color.green

    /// Degraded but not failed. Warnings, skipped work, completed-with-errors.
    static let warning = Color.orange

    /// Failure and destructive confirmation.
    static let danger = Color.red

    enum Space {
        static let section: CGFloat = 16
        static let cardPadding: CGFloat = 14
        static let pane: CGFloat = 20
    }

    enum Radius {
        static let card: CGFloat = 10
        static let chip: CGFloat = 7
    }

    static let statValue: Font = .system(.title3, design: .rounded).weight(.semibold)
}

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
