import SwiftUI

/// Activity's drawer: what the selected run did and where to go from it —
/// the snapshot it wrote or read (Browse, Compare with Previous…), its
/// numbers, restic's exit code, the messages it left, and the log. Shown
/// for every selected run, clean ones included: the plan page's Last backup
/// value lands on exactly such a run, and an empty pane under the selection
/// reads as "nothing to see".
///
/// A fixed height, scrolling inside, buttons pinned under the scroll view
/// so Show Log… stays in reach whatever the messages list: 220 pt for a run
/// with nothing to say, 320 for one with messages, so a failure's diagnosis
/// does not push the facts under the fold. A constant per selected run,
/// never a measurement, also answers Activity's non-scrolling host: its
/// reply to the split view's zero-width minimum query is that number,
/// whatever the text wraps to.
struct RunDetailPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    let run: RunRecord
    var onCompare: (SnapshotDiffTarget) -> Void
    var onShowLog: (RunRecord) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    // A problem run leads with what went wrong, a clean run
                    // with what it made: the failure is not pushed under the
                    // fold below the grid.
                    if run.outcome == .succeeded {
                        DetailGrid { rows }
                        messages
                    } else {
                        messages
                        DetailGrid { rows }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            Divider()
            buttons
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(height: hasMessages ? 320 : 220)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            // Decorative beside words that already say the outcome — the
            // table cell keeps the glyph's own label.
            if let symbolName = run.outcome.symbolName {
                Image(systemName: symbolName)
                    .foregroundStyle(StatusPalette.status(run.outcome))
                    .accessibilityHidden(true)
            }
            // How long it took lives here, not in a table column of its own.
            Text("\(run.outcome.displayName) · finished \(Format.timestamp(run.finishedAt)) · \(Format.duration(run.duration))")
                .font(.headline)
        }
    }

    // MARK: - Facts

    private var repositoryName: String? { model.repository(id: run.repositoryID)?.name }

    @ViewBuilder
    private var rows: some View {
        switch run.kind {
        case .backup:
            if run.snapshotID != nil {
                DetailRow("Snapshot") { RunSnapshotRow(run: run, onCompare: onCompare) }
            }
            // Why there was nothing to back up — the Detail column's words.
            if run.outcome == .skipped, let reason = run.detailText {
                DetailRow("Skipped", reason)
            }
            // A standing skip: one record for every run the drive was away.
            if let since = run.skippedSince, let count = run.skipCount {
                DetailRow("Since", "\(Format.timestamp(since)) · \(count) runs")
            }
            if RunRecordPresentation.hasBackupNumbers(run) {
                DetailRow(
                    "Files",
                    "\(Format.count(run.filesNew)) new · \(Format.count(run.filesChanged)) changed · \(Format.count(run.filesUnmodified)) unmodified"
                )
                DetailRow("Size", "Processed \(Format.bytes(run.bytesProcessed)) · added \(Format.bytes(run.dataAdded))")
            }
            repositoryRow
            exitRow
        case .restore:
            if run.snapshotID != nil {
                DetailRow("Snapshot") { RunSnapshotRow(run: run, onCompare: onCompare) }
            }
            // Records that predate destination tracking have none; their
            // rows are left out rather than guessed.
            if let destination = run.destinationPath {
                // "Snapshot" beside the Snapshot row, as Copy Details says it;
                // "backup" is the Restore pane's word.
                if let paths = run.sourcePaths {
                    // The names in the row, every full path in the tooltip.
                    DetailRow("Items") {
                        Text(paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                            .help(paths.joined(separator: "\n"))
                    }
                } else {
                    DetailRow("Item") {
                        Text(run.sourcePath ?? "Entire snapshot")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(run.sourcePath ?? "Every folder in the snapshot, under its full original path")
                    }
                }
                DetailRow(run.outcome == .succeeded ? "Restored to" : "Destination") {
                    RevealRow(path: destination, runID: run.id)
                }
            }
            if run.outcome == .succeeded, run.filesRestored + run.filesSkipped > 0 {
                DetailRow("Files", RunRecordPresentation.restoreFiles(run))
            }
            repositoryRow
            exitRow
        default:
            repositoryRow
            // A check's verdict, or what Apply Retention Now… removed —
            // Copy Details' Result line.
            if run.kind == .check || run.kind == .forget, let result = run.detailText {
                DetailRow("Result") { Text(result).textSelection(.enabled) }
            }
            exitRow
        }
    }

    private var repositoryRow: some View {
        DetailRow("Repository", repositoryName ?? "No longer set up in SwiftRestic")
    }

    @ViewBuilder
    private var exitRow: some View {
        if let code = run.exitCode, let text = RunRecordPresentation.exitCodeText(code) {
            DetailRow("restic exit") { Text(text).textSelection(.enabled) }
        }
    }

    // MARK: - Messages

    /// What the run left in words: the failure in red, prune's
    /// output tail, what to do about the unreadable items, restic's item
    /// lines, and the hooks' own lines — which stay here, on this Mac, and
    /// never reach Copy Details. The unreadable items come under restic's
    /// count and end with how many were not stored, the way Copy Details
    /// and the Restore strip say it.
    private var hasMessages: Bool {
        run.failureMessage != nil || (run.kind == .prune && run.detailText != nil)
            || !run.itemErrors.isEmpty || !run.hookMessages.isEmpty
    }

    @ViewBuilder
    private var messages: some View {
        let unreadable = run.unreadableItems
        let unlisted = run.itemErrorCount - unreadable.count
        if hasMessages {
            VStack(alignment: .leading, spacing: 6) {
                if let failure = run.failureMessage {
                    Text(failure)
                        .foregroundStyle(Theme.danger)
                        .textSelection(.enabled)
                }
                if run.kind == .prune, let detail = run.detailText {
                    Text(detail)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                // Why the items could not be read and what fixes it, ahead
                // of the list it explains.
                ItemErrorHintsView(run: run)
                if run.itemErrorCount > 0 {
                    Text("Unreadable items (\(Format.count(run.itemErrorCount)))")
                        .font(.callout.weight(.semibold))
                }
                ForEach(Array(unreadable.enumerated()), id: \.offset) { _, message in
                    UnreadableItemLine(run: run, line: message)
                }
                if unlisted > 0 {
                    Text("… and \(Format.count(unlisted)) more")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                // The decoding gap and the retention skip explain themselves.
                ForEach(Array(run.itemErrors.dropFirst(unreadable.count).enumerated()), id: \.offset) { _, message in
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                ForEach(Array(run.hookMessages.enumerated()), id: \.offset) { _, message in
                    Label(message, systemImage: "terminal")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Buttons

    private var buttons: some View {
        HStack(spacing: 10) {
            if let planID = run.planID, model.plan(id: planID) != nil {
                Button("Open Plan") { router.selection = .plan(planID) }
            }
            // The run's other home, beside Open Plan. Only where the
            // repository still resolves — a removed one has no page to open,
            // and the Repository row above already says it is gone.
            if let repositoryID = run.repositoryID, repositoryName != nil {
                Button("Open Repository") { router.selection = .repository(repositoryID) }
            }
            if let fix = model.fix(for: run) {
                RunFixButton(fix: fix)
            }
            // A check's verdict stands a week with nothing on its page to
            // act on it; its re-run sits here, beside the fix. Greyed as
            // the menu's command is while the repository is busy.
            if let retry = RunRecordPresentation.maintenanceRetry(for: run, repositoryExists: repositoryName != nil) {
                Button(retry.title) {
                    switch retry {
                    case let .check(id): router.request(.confirm(.check(id)))
                    case let .prune(id): router.request(.confirm(.prune(id)))
                    }
                }
                .disabled(!model.repositoryCommands(for: .repository(retry.repositoryID)).canMaintain)
            }
            if let planID = run.planID, let plan = model.plan(id: planID) {
                // A retry only where there is something to retry: a clean
                // record's next step is not a pointless re-run.
                if run.kind == .backup, run.outcome != .succeeded, plan.isConfigurationComplete {
                    // The Plan menu's predicate, as the plan page's and the
                    // sidebar's buttons read it — without it the button is
                    // clickable while running or restic-less and quietly
                    // does nothing.
                    Button("Back Up Now") { model.runBackup(planID: planID) }
                        .disabled(!model.planCommands(for: .plan(planID)).canBackUp)
                        .help(
                            model.isRunning(planID: planID)
                                ? "This plan's backup is already running"
                                : "Run this plan's backup now"
                        )
                }
            }
            Spacer(minLength: 0)
            Button("Show Log…") { onShowLog(run) }
                .disabled(!run.hasLog)
                .help(
                    run.hasLog
                        ? "Show what restic printed during this run"
                        : "No log was saved for this run — runs recorded before SwiftRestic kept logs have none."
                )
            Button("Copy Details") {
                let text = RunRecordPresentation.detailsText(
                    for: run,
                    repositoryName: repositoryName,
                    versionsNow: .current(resticVersion: model.resticVersion)
                )
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .help("Copy this run's details as plain text")
        }
        .controlSize(.small)
    }
}

/// One unreadable item's line in the drawer, with the two fixes the
/// diagnosis above it names — Reveal in Finder, and Exclude from the plan —
/// in a menu at its end and in its context menu. Only where restic named the
/// item's path and the run stored it (`RunRecord.unreadableItemPaths`); older
/// records' lines stay plain text. Exclude asks first: it changes what the
/// plan backs up from now on.
private struct UnreadableItemLine: View {
    @Environment(AppModel.self) private var model
    let run: RunRecord
    let line: String
    /// Nil until the check lands; Reveal waits disabled until then.
    @State private var exists: Bool?
    @State private var isConfirmingExclude = false

    var body: some View {
        let path = run.unreadableItemPaths?[line]
        let plan = run.planID.flatMap { model.plan(id: $0) }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(line)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let path {
                Spacer(minLength: 4)
                Menu {
                    actions(path: path, plan: plan)
                } label: {
                    // Named by the item, so VoiceOver tells one line's menu
                    // from the next.
                    Label("Actions for \((path as NSString).lastPathComponent)", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Reveal this item in Finder, or exclude it from the plan")
            }
        }
        .contextMenu {
            if let path { actions(path: path, plan: plan) }
        }
        .confirmationDialog(
            "Exclude “\(path.map { ($0 as NSString).lastPathComponent } ?? "")” from “\(plan?.displayName ?? "")”?",
            isPresented: $isConfirmingExclude
        ) {
            if let path, let plan {
                Button("Exclude") { model.exclude(path: path, fromPlan: plan.id) }
            }
        } message: {
            Text("Its next backups skip \(path ?? "") — backups already made keep it. The plan's exclude patterns list it, and Edit takes it out again.")
        }
        .task(id: path) {
            guard let path else { return }
            exists = nil
            let found = await Task.detached(priority: .utility) {
                FileManager.default.fileExists(atPath: path)
            }.value
            guard !Task.isCancelled else { return }
            exists = found
        }
    }

    @ViewBuilder
    private func actions(path: String, plan: BackupPlan?) -> some View {
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        .disabled(exists != true)
        if let plan {
            Button("Exclude from “\(plan.displayName)”…") { isConfirmingExclude = true }
                .disabled(plan.excludePatterns.contains(ResticService.globEscaped(path)))
        }
    }
}

/// A failure's one known fix, through the Repository menu's own path: the
/// editor sheet, or the confirmed Remove Stale Locks.
struct RunFixButton: View {
    @Environment(AppRouter.self) private var router
    let fix: RunFix

    var body: some View {
        Button(fix.title) {
            switch fix {
            case let .editRepository(id), let .editRepositoryPath(id): router.request(.editRepository(id))
            case let .removeStaleLocks(id): router.request(.confirm(.unlock(id)))
            }
        }
        .help(fix.help)
    }
}

/// The drawer's Snapshot row, in its own view so the listing lookup behind
/// it reruns only when the run or the repository's listing changes — not on
/// every write the drawer's other rows observe. Browse opens the record
/// in the sidebar; Compare with Previous… is the diff's one way in.
private struct RunSnapshotRow: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    let run: RunRecord
    let onCompare: (SnapshotDiffTarget) -> Void

    var body: some View {
        let snapshotID = run.snapshotID ?? ""
        let short = String(snapshotID.prefix(8))
        let link = model.snapshotLink(for: run)
        HStack(spacing: 8) {
            switch link {
            case let .available(snapshot)?:
                identifier(short, made: run.kind == .restore ? (run.snapshotTime ?? snapshot.time) : nil)
                completenessMark(for: snapshot.id)
                browseButton(snapshot.id)
                if run.kind == .backup {
                    Button("Compare with Previous…") {
                        if let repositoryID = run.repositoryID {
                            onCompare(SnapshotDiffTarget(repositoryID: repositoryID, snapshot: snapshot))
                        }
                    }
                    .help("See what changed since the previous backup of these folders")
                }
            case .removed?:
                Text("\(short) — no longer in the repository")
                    .monospaced()
                    .textSelection(.enabled)
                    .help("Removed after this run — by retention, a prune, or another restic client.")
            case .unavailable?:
                let help = "This repository's snapshot list isn't loaded right now."
                identifier(short, made: run.kind == .restore ? run.snapshotTime : nil)
                completenessMark(for: snapshotID)
                Button("Browse") {}
                    .disabled(true)
                    .help(help)
                if run.kind == .backup {
                    Button("Compare with Previous…") {}
                        .disabled(true)
                        .help(help)
                }
            case .repositoryGone?, nil:
                identifier(short, made: run.kind == .restore ? run.snapshotTime : nil)
                    .help("This repository is no longer set up in SwiftRestic.")
            }
        }
        .controlSize(.small)
    }

    private func identifier(_ short: String, made: Date?) -> some View {
        HStack(spacing: 4) {
            Text(short)
                .monospaced()
                .textSelection(.enabled)
            if let made {
                Text("· \(Format.timestamp(made))")
            }
        }
    }

    /// The run itself for a backup; the backup that wrote the snapshot,
    /// for a restore.
    private func completenessMark(for snapshotID: String) -> some View {
        SnapshotCompletenessMark(run: run.kind == .backup ? run : model.backupRun(forSnapshot: snapshotID))
            .font(.caption)
            .frame(width: 14)
    }

    private func browseButton(_ snapshotID: String) -> some View {
        Button("Browse") {
            if let repositoryID = run.repositoryID {
                router.showRestore(repositoryID: repositoryID, snapshotID: snapshotID)
            }
        }
        .help("Show this snapshot's files in the Restore pane")
    }
}

/// A restore's landing path with Reveal in Finder. Whether anything is still
/// there is asked off the main actor when the run is shown — a destination
/// on an unreachable network volume can stall `fileExists`, and the render
/// path must never wait on that.
private struct RevealRow: View {
    let path: String
    let runID: UUID
    /// Nil until the check lands; the button waits disabled until then.
    @State private var exists: Bool?

    var body: some View {
        HStack(spacing: 8) {
            Text(path)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(path)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .controlSize(.small)
            .disabled(exists != true)
            .help(exists == false ? "Nothing is at this path any more." : "Show the restored item in Finder")
        }
        .task(id: runID) {
            exists = nil
            let path = path
            let found = await Task.detached(priority: .utility) {
                FileManager.default.fileExists(atPath: path)
            }.value
            // The selection moved to another restore while a stalled check
            // waited: cancelling this task does not stop the detached one
            // returning, and its answer is about a path no longer shown.
            guard !Task.isCancelled else { return }
            exists = found
        }
    }
}
