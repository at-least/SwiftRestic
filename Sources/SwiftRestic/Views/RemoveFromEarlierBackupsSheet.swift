import SwiftUI

/// The Excluding card's line for the paths the plan skips by name that its
/// earlier backups still hold, with the way to remove them — absent while
/// there are none. Read from the index, so it costs no restic run.
struct EarlierBackupsLine: View {
    @Environment(AppModel.self) private var model
    let plan: BackupPlan

    @State private var items: [EarlierBackupItem] = []
    @State private var isConfirming = false

    private struct ReadKey: Hashable {
        var listedAt: Date?
        var indexGeneration: UInt64?
        var excludePatterns: [String]
    }

    private var readKey: ReadKey {
        ReadKey(
            listedAt: plan.repositoryID.flatMap { model.snapshotsLoadedAt(for: $0) },
            indexGeneration: plan.repositoryID.flatMap { model.indexTakenGeneration[$0] },
            excludePatterns: plan.excludePatterns
        )
    }

    var body: some View {
        Group {
            if !items.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(items.count == 1
                        ? "Earlier backups still hold an item this plan now skips."
                        : "Earlier backups still hold \(Format.count(items.count)) items this plan now skips.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Remove from Earlier Backups…") { isConfirming = true }
                        .controlSize(.small)
                }
            }
        }
        .task(id: readKey) {
            // A failed read offers nothing: the index's failure is the Files
            // tab's to say, and this line is only an offer.
            guard let found = try? await model.itemsInEarlierBackups(planID: plan.id), !Task.isCancelled else { return }
            items = found
        }
        .sheet(isPresented: $isConfirming) {
            RemoveFromEarlierBackupsSheet(planID: plan.id, items: items)
                .environment(model)
        }
    }
}

/// Remove from Earlier Backups: the items and how many backups hold each,
/// then `restic rewrite --forget` only on a deliberate click.
struct RemoveFromEarlierBackupsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let planID: UUID
    let items: [EarlierBackupItem]

    @State private var isIndexComplete = true

    /// Every backup holding any of the items.
    private var backupCount: Int {
        Set(items.flatMap { $0.backups.map(\.id) }).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let plan = model.plan(id: planID) {
                content(plan)
            } else {
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
        .task {
            guard let repositoryID = model.plan(id: planID)?.repositoryID else { return }
            isIndexComplete = await model.indexIsComplete(repositoryID: repositoryID)
        }
    }

    @ViewBuilder
    private func content(_ plan: BackupPlan) -> some View {
        let blocker = model.removeFromEarlierBackupsBlocker(planID: planID)
        Text("Remove \(Format.plural(items.count, "Item")) from Earlier Backups?")
            .font(.headline)
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline) {
                        Text((item.excluded.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(item.excluded.path)
                        Spacer(minLength: 12)
                        Text("in \(Format.plural(item.backups.count, "backup"))")
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
        Text("This rewrites \(Format.plural(backupCount, "backup")) of “\(model.label(of: plan))” without \(items.count == 1 ? "it" : "them"). \(items.count == 1 ? "It" : "They") can no longer be restored from those backups. \(cleanupSentence(plan))")
            .fixedSize(horizontal: false, vertical: true)
        if !isIndexComplete {
            Text("SwiftRestic is still reading some of this plan’s backups, so more of them may hold these items. They are rewritten too.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let blocker {
            WarningLine(text: blocker)
        }
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            // No Return: rewriting backups cannot be undone, and the HIG's
            // way to make people read first is no default button.
            Button("Remove from \(Format.plural(backupCount, "Backup"))", role: .destructive) {
                model.removeFromEarlierBackups(planID: planID, items: items.map(\.excluded))
                dismiss()
            }
            .disabled(blocker != nil || model.activity[planID] != nil)
        }
    }

    /// When the space comes back: the repository's next scheduled cleanup,
    /// or the one the user runs.
    private func cleanupSentence(_ plan: BackupPlan) -> String {
        guard let repository = model.repository(id: plan.repositoryID),
              let next = repository.maintenance.nextDate(for: .prune, addedAt: repository.createdAt)
        else { return "Their space is freed when you next clean up the repository." }
        return "Their space is freed at the next cleanup, \(Format.timestamp(max(next, .now)))."
    }
}
