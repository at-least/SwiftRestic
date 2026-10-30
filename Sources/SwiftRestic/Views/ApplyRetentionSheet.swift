import SwiftUI

/// Apply Retention Now: restic's own dry run of the plan's rules first —
/// which snapshots would go, by date — then the real forget, only on a
/// deliberate click. The preview reads without a lock
/// (`forget --dry-run --no-lock`), so it works beside a backup; applying
/// waits for the repository to be free.
struct ApplyRetentionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let planID: UUID

    @State private var load = RetentionPreviewLoad()

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
            newestSnapshotID: model.latestSnapshot(in: plan?.repositoryID, planID: planID)?.id,
            retry: load.retry
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
        .task(id: previewKey) {
            await load.load { try await model.previewRetention(planID: planID) }
        }
    }

    @ViewBuilder
    private func content(_ plan: BackupPlan) -> some View {
        let state = model.planCommands(for: .plan(planID))
        VStack(alignment: .leading, spacing: 2) {
            Text("Apply Retention to “\(model.label(of: plan))”")
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)
            Text(plan.retention.summary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        // A policy with no rule previews nothing, which would read as "no
        // snapshots yet"; the blocker below says what is really wrong.
        if plan.retention.isSafeToRun {
            RetentionPreviewStatus(
                isLoading: load.isLoading,
                failure: load.failure,
                working: "Working out which backups these rules would remove…",
                onRetry: { load.requestRetry() }
            )
            if load.failure == nil, let preview = load.result {
                previewContent(preview, plan: plan)
            }
        }

        if let blocker = state.retentionBlocker {
            WarningLine(text: blocker)
        }

        HStack {
            Spacer()
            if let preview = load.result, preview.removed.isEmpty, !load.isLoading, load.failure == nil {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if let preview = load.result, !preview.removed.isEmpty {
                    // What Apply Retention Now was chosen for, so not marked
                    // destructive — the HIG's Empty Trash case — but no
                    // Return either: removing backups cannot be undone, and
                    // the HIG's way to make people read first is no default.
                    Button("Remove \(Format.plural(preview.removed.count, "Backup"))") {
                        model.applyRetention(planID: planID)
                        dismiss()
                    }
                    .disabled(load.isLoading || !state.canApplyRetention)
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
                ? "A cleanup runs right after and frees their space — slow on a large repository, and backups to it wait until it finishes."
                : "Their data stays in the repository until the next cleanup.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
