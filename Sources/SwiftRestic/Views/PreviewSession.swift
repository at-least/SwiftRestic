import QuickLook
import QuickLookUI
import SwiftUI

/// One pane's Quick Look look at a file in a backup, before restoring it: the
/// file copied out of the repository into a temporary folder
/// (`AppModel.previewCopy`), shown, and deleted when the preview ends —
/// whichever way it ends. The file pane, the Restore pane and Find Files each
/// hold one (`previewSession(_:)`).
@MainActor @Observable
final class PreviewSession {
    /// What Quick Look shows; nil closes it.
    var url: URL?
    /// Why the last preview could not open — the size gate or the copy's
    /// failure — until the next starts.
    private(set) var failure: String?
    var isCopying: Bool { task != nil }
    /// The copy this session made and has not deleted yet — apart from
    /// `url`, so each copy is deleted exactly once.
    private var copy: URL?
    private var task: Task<Void, Never>?

    /// Copies the file out and shows it. `node` is the file as restic lists
    /// it in that backup — awaited, for a hit whose node the index does not
    /// carry — and refused before any copy when it is too large to look at
    /// (`VersionPreview`).
    func start(
        _ model: AppModel,
        repositoryID: UUID,
        snapshotID: String,
        node: @escaping @MainActor () async throws -> SnapshotNode
    ) {
        end()
        failure = nil
        task = Task {
            do {
                let file = try await node()
                if let reason = VersionPreview.unavailableReason(size: file.size, isReading: false) {
                    failure = reason
                    task = nil
                    return
                }
                let url = try await model.previewCopy(repositoryID: repositoryID, snapshotID: snapshotID, node: file)
                guard !Task.isCancelled else {
                    discard(url)
                    return
                }
                copy = url
                self.url = url
            } catch {
                // A cancelled dump is the pane's own doing, not a failure.
                if !Task.isCancelled { failure = error.localizedDescription }
            }
            if !Task.isCancelled { task = nil }
        }
    }

    /// Stops a copy in flight, closes Quick Look and deletes the copy it
    /// showed. Safe to call any number of times.
    func end() {
        task?.cancel()
        task = nil
        url = nil
        if let copy {
            self.copy = nil
            discard(copy)
        }
    }

    /// The pane going: the modifier goes with it, so the url's nil would
    /// never reach the panel, which would stay up over a deleted copy
    /// beside another pane — closed here.
    fileprivate func endForDisappear() {
        let wasPreviewing = url != nil
        end()
        if wasPreviewing, QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().close()
        }
    }

    private func discard(_ url: URL) {
        do {
            try AppModel.removePreviewCopy(url)
        } catch {
            failure = "The preview's copy could not be deleted: \(error.localizedDescription)"
        }
    }
}

extension View {
    /// Shows `session`'s preview with Quick Look and deletes its copy when
    /// the preview closes or the view goes.
    func previewSession(_ session: PreviewSession) -> some View {
        @Bindable var session = session
        return quickLookPreview($session.url)
            .onChange(of: session.url) { _, url in
                if url == nil { session.end() }
            }
            .onDisappear { session.endForDisappear() }
    }
}
