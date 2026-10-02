import SwiftUI

/// The colours a run's outcome wears, on its glyphs — in Activity, the run
/// drawer, the sidebar's plan captions, a repository page's Plans rows — and
/// borrowed for the diff's change kinds. Native system colours only.
enum StatusPalette {
    static func status(_ outcome: RunRecord.Outcome) -> Color {
        switch outcome {
        case .succeeded: .green
        case .completedWithErrors: .orange
        case .failed: .red
        case .cancelled: .gray
        }
    }
}
