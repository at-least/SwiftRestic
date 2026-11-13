import SwiftUI

/// Activity's drawer for the selected run, clean ones included: the plan
/// page's Last backup value lands on exactly such a run.
///
/// A fixed height, scrolling inside, buttons pinned under the scroll view so
/// the fix stays in reach. A constant per run, never a measurement:
/// Activity's non-scrolling host answers the split view's zero-width minimum
/// query with it, whatever the text wraps to.
struct RunDetailPanel: View {
    private static let quietHeight: CGFloat = 220
    /// Taller, so a failure's diagnosis does not push the facts under the fold.
    private static let messagesHeight: CGFloat = 320

    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    let run: RunRecord

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
        .frame(height: hasMessages ? Self.messagesHeight : Self.quietHeight)
    }

    // No outcome glyph: the selected row above already wears it. How long
    // it took lives here, not in a table column of its own.
    private var header: some View {
        Text("\(run.outcomeName) · finished \(Format.timestamp(run.finishedAt)) · \(Format.duration(run.duration))")
            .font(.headline)
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
            // A check's verdict, what a retention run removed, or the space a
            // prune freed: the copied details' Result line.
            if run.kind == .check || run.kind == .forget || run.kind == .prune, let result = run.detailText {
                DetailRow("Result") {
                    Text(result).textSelection(.enabled)
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
        (run.failureMessage != nil && run.failureMessage != run.outcomeName)
            || !run.itemErrors.isEmpty
    }

    /// What the run left in words: the failure, what to do about the
    /// unreadable items, restic's item lines.
    @ViewBuilder
    private var messages: some View {
        let (unreadable, unlisted) = run.unreadableItemListing()
        if hasMessages {
            VStack(alignment: .leading, spacing: 6) {
                if let failure = run.failureMessage, failure != run.outcomeName {
                    Text(failure)
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
            }
        }
    }

    /// The fix, where there is one, is the one prominent button.
    private var buttons: some View {
        HStack(spacing: 10) {
            if let fix = model.fix(for: run) {
                RunFixButton(fix: fix)
                    .buttonStyle(.borderedProminent)
            } else if let id = RunRecordPresentation.repairRoute(for: run, repositoryExists: repositoryName != nil) {
                RepairButton(repositoryID: id)
                    .buttonStyle(.borderedProminent)
            }
            // A check's verdict stands a week with nothing on its page to
            // act on it; its re-run sits here, beside the fix. Greyed while
            // the repository is busy.
            if let retry = RunRecordPresentation.maintenanceRetry(for: run, repositoryExists: repositoryName != nil) {
                Button(retry.title) {
                    switch retry {
                    case let .check(id): router.request(.verifyBackups(id))
                    case let .prune(id): router.request(.freeUpSpace(id))
                    }
                }
                .disabled(!model.repositoryCommands(for: .repository(retry.repositoryID)).canMaintain)
            }
            if let planID = run.planID, let plan = model.plan(id: planID) {
                // A retry only where there is something to retry: a clean
                // record's next step is not a pointless re-run.
                if run.kind == .backup, run.outcome != .succeeded, plan.isConfigurationComplete {
                    // The Backup menu's predicate: without it the button is
                    // clickable while running and quietly does nothing.
                    Button("Back Up Now") { model.runBackup(planID: planID) }
                        .disabled(!model.planCommands(for: .plan(planID)).canBackUp)
                        .modifier(TileHelp(help: model.isRunning(planID: planID)
                            ? "This plan’s backup is already running"
                            : model.planCommands(for: .plan(planID)).backUpDisabledReason))
                }
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }
}

/// A failure's one known fix: its intent, asked as the menus ask
/// (`RunFix.intent`); Locate's and Locate Folder's panels open here.
struct RunFixButton: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppModel.self) private var model
    let fix: RunFix

    var body: some View {
        Button(fix.title) {
            if let intent = fix.intent {
                router.request(intent)
            } else if case let .locate(id) = fix {
                locate(id)
            } else if case let .locateFolder(planID) = fix {
                locateFolder(planID)
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
                model.post(Banner(title: "Couldn’t use that folder", message: error.localizedDescription, level: .error))
            }
        }
    }

    private func locateFolder(_ planID: UUID) {
        guard let plan = model.plan(id: planID),
              let url = FilePicker.chooseDirectory(message: "Choose where “\(model.label(of: plan))” is now")
        else { return }
        do {
            router.selection = .plan(try model.movePlan(id: planID, toPath: url.path))
        } catch {
            model.post(Banner(title: "Couldn’t use that folder", message: error.localizedDescription, level: .error))
        }
    }
}

/// Opens the restic console on a repository whose check found damage. It
/// types nothing: repair stays a command the user writes, and the console
/// asks before running it.
struct RepairButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let repositoryID: UUID

    var body: some View {
        Button("Repair…") {
            model.pointConsole(at: repositoryID)
            openWindow(id: SwiftResticApp.consoleWindowID)
        }
        .disabled(!model.isResticAvailable)
    }
}

/// The drawer's Backup row, in its own view so the listing lookup behind
/// it reruns only when the run or the repository's listing changes, not on
/// every write the drawer's other rows observe. restic's snapshot ID stays in
/// the copied details (Edit ▸ Copy); the backup's time names it on screen.
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
                Text("Removed since")
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
