import Foundation
import Observation

/// The retention dry-run's state, shared by the two surfaces that each held
/// an equal copy — the adopt sheet's preview and Apply Retention Now's: the
/// answer, the failure that replaces it, the spinner, and Try Again's count.
/// Each view keeps its own task key and re-runs `load` from `.task(id:)`, so
/// a cancelled attempt — a newer key, or the sheet closing — leaves the
/// state to its successor.
@MainActor
@Observable
final class RetentionPreviewLoad {
    /// The last preview that came back. Kept while a re-run loads, so the
    /// sheet does not jump; a failure clears it.
    private(set) var result: RetentionPreview?
    private(set) var failure: String?
    private(set) var isLoading = true
    /// Bumped by Try Again; the view reads it into its task key, so the
    /// reload cancels like any other key change.
    private(set) var retry = 0

    func requestRetry() {
        retry += 1
    }

    func load(_ fetch: @MainActor () async throws -> RetentionPreview) async {
        isLoading = true
        failure = nil
        do {
            let preview = try await fetch()
            // A newer key (or the sheet closing) cancelled this read; its
            // successor owns the state now.
            guard !Task.isCancelled else { return }
            result = preview
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
            result = nil
        }
        isLoading = false
    }
}
