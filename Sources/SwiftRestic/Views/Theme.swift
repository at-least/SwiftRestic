import SwiftUI

/// Colour carries meaning only: accent for what can be clicked, orange and red
/// for trouble. Normal is quiet, so there is no success colour.
enum Theme {
    static let tint = Color.accentColor
    static let warning = Color.orange
    static let danger = Color.red
}

/// A run's outcome glyph, in its colour until a selected row's fill sits behind
/// it. Not the colour there: red on the selection measured 1.34–1.83:1.
struct StatusGlyph: View {
    @Environment(\.backgroundProminence) private var backgroundProminence
    let outcome: RunRecord.Outcome

    var body: some View {
        if let symbolName = outcome.symbolName {
            Image(systemName: symbolName)
                .foregroundStyle(
                    backgroundProminence == .increased
                        ? AnyShapeStyle(.primary)
                        : AnyShapeStyle(StatusPalette.status(outcome))
                )
        }
    }
}
