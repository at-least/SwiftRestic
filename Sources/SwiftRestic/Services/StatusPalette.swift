import SwiftUI

/// The colours a run's outcome wears, wherever its glyph shows. Native
/// system colours only. Success is quiet, as `Theme` says: it wears no glyph,
/// so its grey is never drawn.
enum StatusPalette {
    static func status(_ outcome: RunRecord.Outcome) -> Color {
        switch outcome {
        case .completedWithErrors: .orange
        case .failed: .red
        case .succeeded, .cancelled, .skipped: .gray
        }
    }
}
