import SwiftUI

/// Apply Retention Now…: restic's own dry run of the plan's rules first —
/// which snapshots would go, by date — then the real forget, only on a
/// deliberate click. The preview reads without a lock
/// (`forget --dry-run --no-lock`), so it works beside a backup; applying
/// waits for the repository to be free.
struct ApplyRetentionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let planID: UUID

    /// The last preview that came back. Kept while a re-preview runs, with
    /// its button disabled, so the sheet does not jump.
    @State private var preview: RetentionPreview?
    @State private var isLoading = true
    @State private var failure: String?
    @State private var retry = 0

    /// What the preview depends on: the rules, the plan's newest snapshot in
    /// the listing — a backup landing while the sheet is open re-previews,
    /// since its snapshot changes what the rules keep — and Try Again.
    private struct PreviewKey: Hashable {
        var retention: RetentionPolicy?
        var newestSnapshotID: String?
        var retry: Int
    }

    private var previewKey: PreviewKey {
        let plan = model.plan(id: planID)
        return PreviewKey(
            retention: plan?.retention,
            newestSnapshotID: model.snapshots(for: plan?.repositoryID, planID: planID).first?.id,
            retry: retry
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let plan = model.plan(id: planID) {
                content(plan)
            } else {
                // Deleted while the sheet was open.
                Text("Plan not found")
                    .font(.headline)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .task(id: previewKey) { await loadPreview() }
    }

    @ViewBuilder
    private func content(_ plan: BackupPlan) -> some View {
        let state = model.planCommands(for: .plan(planID))
        VStack(alignment: .leading, spacing: 2) {
            Text("Apply Retention to “\(plan.displayName)”")
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)
            Text("Rules: \(plan.retention.summary)")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        // A policy with no rule previews nothing, which would read as "no
        // snapshots yet"; the blocker below says what is really wrong.
        if plan.retention.isSafeToRun {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking restic which snapshots these rules would remove…")
                        .foregroundStyle(.secondary)
                }
            }
            if let failure {
                warning(Format.firstSentence(failure))
                    .help(failure)
                Button("Try Again") { retry += 1 }
                    .controlSize(.small)
            } else if let preview {
                previewContent(preview, plan: plan)
            }
        }

        if let blocker = state.retentionBlocker {
            warning(blocker)
        }

        HStack {
            Spacer()
            if let preview, preview.removed.isEmpty, !isLoading, failure == nil {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if let preview, !preview.removed.isEmpty {
                    // No Return: removing snapshots is a deliberate click,
                    // the quit alert's rule for a destructive button.
                    Button("Remove \(Format.plural(preview.removed.count, "Snapshot"))", role: .destructive) {
                        model.applyRetention(planID: planID)
                        dismiss()
                    }
                    .disabled(isLoading || !state.canApplyRetention)
                }
            }
        }
    }

    @ViewBuilder
    private func previewContent(_ preview: RetentionPreview, plan: BackupPlan) -> some View {
        Text(preview.summary)
            .fixedSize(horizontal: false, vertical: true)
        if !preview.removed.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(preview.removed) { snapshot in
                        HStack {
                            Text(Format.timestamp(snapshot.time))
                            Spacer(minLength: 12)
                            Text(snapshot.shortID)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 160)
            .fixedSize(horizontal: false, vertical: true)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Text(plan.retention.runPrune
                ? "Prune runs right after and reclaims their space — slow on a large repository, and it locks the repository until it finishes."
                : "Their data stays in the repository until the next prune (Repository › Prune Now…).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Orange on the glyph only, the words secondary — the contrast rule the
    /// sidebar's captions follow.
    private func warning(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadPreview() async {
        isLoading = true
        failure = nil
        do {
            let result = try await model.previewRetention(planID: planID)
            // A newer key (or the sheet closing) cancelled this read; its
            // successor owns the state now.
            guard !Task.isCancelled else { return }
            preview = result
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
            preview = nil
        }
        isLoading = false
    }
}
