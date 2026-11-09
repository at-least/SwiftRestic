import SwiftUI

/// Activity's drawer: what the selected run did and where to go from it —
/// the snapshot it wrote or read (Show in Backups), its
/// numbers, restic's exit code, the messages it left, and the log. Shown
/// for every selected run, clean ones included: the plan page's Last backup
/// value lands on exactly such a run, and an empty pane under the selection
/// reads as "nothing to see".
///
/// A fixed height, scrolling inside, buttons pinned under the scroll view
/// so Show Log stays in reach whatever the messages list: 220 pt for a run
/// with nothing to say, 320 for one with messages, so a failure's diagnosis
/// does not push the facts under the fold. A constant per selected run,
/// never a measurement, also answers Activity's non-scrolling host: its
/// reply to the split view's zero-width minimum query is that number,
/// whatever the text wraps to.
struct RunDetailPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    let run: RunRecord
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

    private var repositoryName: String? { model.repository(id: run.repositoryID).map { model.label(of: $0) } }

    @ViewBuilder
    private var rows: some View {
        switch run.kind {
        case .backup:
            if let snapshotID = run.snapshotID {
                DetailRow("Backup") { RunSnapshotRow(run: run, snapshotID: snapshotID) }
            }
            if run.outcome == .skipped, let reason = run.detailText {
                DetailRow("Reason", reason)
            }
            // A standing skip: one record for every run the drive was away.
            if let since = run.skippedSince, let count = run.skipCount {
                DetailRow(run.outcome == .failed ? "Failing since" : "Skipped since", "\(Format.timestamp(since)) · \(Format.plural(count, "time"))")
            }
            if RunRecordPresentation.hasBackupNumbers(run) {
                DetailRow("Files", RunRecordPresentation.backupFiles(run))
                DetailRow("Size", RunRecordPresentation.backupSize(run))
            }
            repositoryRow
        case .restore:
            if let snapshotID = run.snapshotID {
                DetailRow("Backup") { RunSnapshotRow(run: run, snapshotID: snapshotID) }
            }
            // Records that predate destination tracking have none; their
            // rows are left out rather than guessed.
            if let destination = run.destinationPath {
                if let paths = run.sourcePaths {
                    DetailRow("Items") {
                        Text(paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                            .help(paths.joined(separator: "\n"))
                    }
                } else {
                    DetailRow("Item") {
                        Text(run.sourcePath ?? "Entire backup")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(run.sourcePath ?? "Every folder in the backup, under its full original path")
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
        default:
            repositoryRow
            // A check's verdict, or what a retention run removed:
            // Copy Details' Result line.
            if run.kind == .check || run.kind == .forget, let result = run.detailText {
                DetailRow("Result") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(result).textSelection(.enabled)
                        // The verdict advises restic's repair commands: the console
                        // is where it runs with the password supplied.
                        if let id = RunRecordPresentation.repairRoute(for: run, repositoryExists: repositoryName != nil) {
                            ConsoleRouteButton(repositoryID: id)
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    /// Where the run belongs, each name a link to its page — the run's
    /// two homes, said once, rather than a fact row and a button apart.
    /// A plan gone has no row; a repository gone says so.
    @ViewBuilder
    private var repositoryRow: some View {
        if let planID = run.planID, let plan = model.plan(id: planID) {
            DetailRow("Plan") {
                Button(model.label(of: plan)) { router.selection = .plan(planID) }
                    .buttonStyle(.link)
                    .help("Open this plan")
            }
        }
        if let repositoryID = run.repositoryID, let repositoryName {
            DetailRow("Location") {
                Button(repositoryName) { router.selection = .repository(repositoryID) }
                    .buttonStyle(.link)
                    .help("Open this location")
            }
        } else {
            DetailRow("Location", "No longer set up in SwiftRestic")
        }
    }

    private var hasMessages: Bool {
        (run.failureMessage != nil && run.failureMessage != run.outcome.displayName)
            || (run.kind == .prune && run.detailText != nil)
            || !run.itemErrors.isEmpty || !run.hookMessages.isEmpty
    }

    /// What the run left in words: the failure, prune's output tail, what to do about the unreadable items, restic's item
    /// lines, and the hooks' own lines — which stay here, on this Mac, and
    /// never reach Copy Details. The unreadable items come under restic's
    /// count and end with how many were not stored, the way Copy Details
    /// and the Restore strip say it.
    @ViewBuilder
    private var messages: some View {
        let (unreadable, unlisted) = run.unreadableItemListing()
        if hasMessages {
            VStack(alignment: .leading, spacing: 6) {
                if let failure = run.failureMessage, failure != run.outcome.displayName {
                    Text(failure)
                        .textSelection(.enabled)
                }
                if run.kind == .prune, let detail = run.detailText {
                    Text(detail)
                        .font(.callout)
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
                ForEach(Array(run.trailingItemErrorsOnScreen.enumerated()), id: \.offset) { _, message in
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                ForEach(Array(run.hookMessages.enumerated()), id: \.offset) { _, message in
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
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
                    // The Backup menu's predicate, as the plan page's and the
                    // sidebar's buttons read it — without it the button is
                    // clickable while running or restic-less and quietly
                    // does nothing.
                    Button("Back Up Now") { model.runBackup(planID: planID) }
                        .disabled(!model.planCommands(for: .plan(planID)).canBackUp)
                        .modifier(TileHelp(help: model.isRunning(planID: planID)
                            ? "This plan’s backup is already running"
                            : model.planCommands(for: .plan(planID)).backUpDisabledReason))
                }
            }
            Spacer(minLength: 0)
            Button("Show Log") { onShowLog(run) }
                .disabled(!run.hasLog)
                .modifier(TileHelp(help: run.hasLog ? nil : "No log was saved for this run"))
            Button("Copy Details") {
                let text = RunRecordPresentation.detailsText(
                    for: run,
                    repositoryName: repositoryName,
                    versionsNow: .current(resticVersion: model.resticVersion)
                )
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        .controlSize(.small)
    }
}

/// A failure's one known fix, through the menus' own path: an editor
/// sheet, or a confirmed command.
struct RunFixButton: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppModel.self) private var model
    let fix: RunFix

    var body: some View {
        Button(fix.title) {
            switch fix {
            case let .editRepository(id), let .editRepositoryShare(id):
                router.request(.editRepository(id))
            case let .newPlan(id): router.request(.newPlanIn(id))
            case .addRepository: router.request(.newRepository)
            case let .locate(id): locate(id)
            case let .editPlanShare(id): router.request(.editPlan(id))
            case let .editPlanRetention(id): router.request(.editPlan(id, tab: .retention))
            case let .pruneNow(id): router.request(.confirm(.prune(id)))
            }
        }
        .modifier(TileHelp(help: fix.help))
    }

    private func locate(_ id: UUID) {
        guard let repository = model.repository(id: id),
              let url = FilePicker.chooseDirectory(message: "Choose the folder “\(model.label(of: repository))” moved to")
        else { return }
        Task {
            do {
                try await model.locateRepository(id: id, atPath: url.path)
            } catch {
                model.post(Banner(title: "Couldn’t use that folder", message: error.localizedDescription, isError: true))
            }
        }
    }
}

/// Opens the restic console on a repository whose check found damage. It
/// types nothing: repair stays a command the user writes, and the console
/// asks before running it.
struct ConsoleRouteButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let repositoryID: UUID

    var body: some View {
        Button("Show restic Console") {
            model.pointConsole(at: repositoryID)
            openWindow(id: SwiftResticApp.consoleWindowID)
        }
        // The Location menu's console item's own rule.
        .disabled(!model.isResticAvailable)
        .help("Type repair index, then repair snapshots. The password is supplied")
    }
}

/// The drawer's Backup row, in its own view so the listing lookup behind
/// it reruns only when the run or the repository's listing changes — not on
/// every write the drawer's other rows observe. Show in Backups opens the
/// backup on its page's Backups tab; restic's short ID stays in Copy
/// Details, the backup's time names it for a restore.
private struct RunSnapshotRow: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    let run: RunRecord
    let snapshotID: String

    var body: some View {
        let link = model.snapshotLink(for: run)
        HStack(spacing: 8) {
            switch link {
            case let .available(snapshot)?:
                madeTime(run.snapshotTime ?? snapshot.time)
                completenessMark(for: snapshot.id)
                showInBackupsButton(snapshot.id)
            case .removed?:
                Text("Removed since — by this plan’s rules or another app")
                    .foregroundStyle(.secondary)
            case .unavailable?:
                madeTime(run.snapshotTime)
                completenessMark(for: snapshotID)
            // No Show in Backups until the list loads; with the location
            // gone the Location row says so.
            case .repositoryGone?, nil:
                madeTime(run.snapshotTime)
            }
        }
        .controlSize(.small)
    }

    /// A restore's backup, by when it was made; a backup run's own row
    /// needs no time — the drawer's header has it.
    @ViewBuilder
    private func madeTime(_ made: Date?) -> some View {
        if run.kind == .restore, let made {
            Text(Format.timestamp(made))
        }
    }

    /// The run itself for a backup; the backup that wrote the snapshot,
    /// for a restore.
    private func completenessMark(for snapshotID: String) -> some View {
        SnapshotCompletenessMark(run: run.kind == .backup ? run : model.backupRun(forSnapshot: snapshotID))
            .font(.caption)
            .frame(width: 14)
    }

    private func showInBackupsButton(_ snapshotID: String) -> some View {
        Button("Show in Backups") {
            if let repositoryID = run.repositoryID,
               let page = model.page(ofBackup: snapshotID, in: repositoryID) {
                router.showBackup(snapshotID, on: page, repositoryID: repositoryID)
            }
        }
    }
}

/// A restore's landing path with Show in Finder. Whether anything is still
/// there is asked off the main actor when the run is shown — a destination
/// on an unreachable network volume can stall `fileExists`, and the render
/// path must never wait on that.
private struct RevealRow: View {
    let path: String
    let runID: UUID
    @State private var existence = PathExistence()

    var body: some View {
        HStack(spacing: 8) {
            Text(path)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(path)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .controlSize(.small)
            .disabled(existence.exists != true)
            .modifier(TileHelp(help: existence.exists == false ? "Nothing is at this path any more" : nil))
        }
        .task(id: runID) {
            await existence.check(path)
        }
    }
}

/// Activity's drawer's rows. Not `LabeledContent`: outside a `Form` it renders
/// the value hard against the label. They go in a `Grid` so values line up.
private struct DetailRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: () -> Value

    init(_ label: String, @ViewBuilder value: @escaping () -> Value) {
        self.label = label
        self.value = value
    }

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(minWidth: 110, alignment: .trailing)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension DetailRow where Value == Text {
    init(_ label: String, _ value: String) {
        self.init(label) { Text(value) }
    }
}

private struct DetailGrid<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            content()
        }
    }
}
