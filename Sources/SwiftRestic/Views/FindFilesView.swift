import SwiftUI
import UniformTypeIdentifiers

/// Search All Backups: every repository's index, as the query is typed in the
/// toolbar field — the "I deleted something months ago and don't know which
/// backup has it" case. The app's one search: ⌘F and every page's search
/// field land here. A page, not a sheet: its restores would stack a second
/// sheet on it.
///
/// The index is the one engine: instant, no network, works with the disk
/// away. What it has not read yet it cannot find, so this is the route to
/// getting a file back only while the page says, by repository, what it could
/// not search: an index still reading, an unreachable repository, a failed
/// index. Its rows stay beside those lines.
struct FindFilesView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router

    @State private var previewer = PreviewSession()
    /// The latest answer, with the query it answers: nil before one lands.
    @State private var answer: (query: String, search: AllBackupsSearch)?
    /// Several at a time, as in a backup's tree: Restore (Return)
    /// restores them together, each from its row's backup.
    @State private var selection = Set<String>()
    /// The toolbar field, focused on arrival — the page exists to answer one
    /// question — and by ⌘F.
    @FocusState private var searchIsFocused: Bool
    /// Taken by a click in the results (`focusOnClick`): left in the field,
    /// Return would go nowhere instead of reaching Restore.
    @FocusState private var resultsAreFocused: Bool
    @State private var destinationRequest: RestoreDestinationRequest?
    /// The Plan column (`planNames(of:)`), worked out as an answer lands or
    /// the shelves change, not on every render; nil with one plan.
    @State private var rowPlanNames: [AllBackupsSearch.Row.ID: String]?

    private var query: String {
        router.findQuery.trimmingCharacters(in: .whitespaces)
    }

    private var search: AllBackupsSearch? {
        answer.flatMap { $0.query == query ? $0.search : nil }
    }

    private var rows: [AllBackupsSearch.Row] { search?.rows ?? [] }

    /// A search's key: the query, and what can change its answer — a
    /// repository added or removed, a listing the index took.
    private struct SearchKey: Equatable {
        let query: String
        let repositories: [UUID]
        let taken: [UUID: UInt64]
    }

    var body: some View {
        @Bindable var router = router
        VStack(spacing: 0) {
            if let search, !search.failures.isEmpty || !search.stillReading.isEmpty {
                standing(search)
                Divider()
            }
            // The page's height, whatever stands in for the table: an empty
            // state alone would hug its text and float the page mid-window.
            results
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .restoreCommand(restore)
        .navigationTitle("Search All Backups")
        .searchable(
            text: $router.findQuery,
            placement: .toolbar,
            prompt: Text(verbatim: "File name, such as invoice or keynote")
        )
        .searchFocused($searchIsFocused)
        .previewSession(previewer)
        .restoreFlow($destinationRequest)
        .onChange(of: router.focusesFindField, initial: true) { _, asked in
            guard asked else { return }
            router.focusesFindField = false
            searchIsFocused = true
        }
        // As it is typed, a keystroke's pause first so a word typed is one
        // search; and again every `recheckInterval` while an index reads, so
        // hits from the backups it reaches meanwhile fill in.
        .task(id: SearchKey(
            query: query,
            repositories: model.configuration.repositories.map(\.id),
            taken: model.indexTakenGeneration
        )) {
            guard !query.isEmpty else {
                answer = nil
                selection = []
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            await searchUntilSettled()
        }
        .onChange(of: model.backupShelves) { refreshPlanNames() }
        .onChange(of: model.configuration.plans.count) { refreshPlanNames() }
    }

    private func refreshPlanNames() {
        rowPlanNames = model.configuration.plans.count > 1 ? planNames(of: rows) : nil
    }

    private func searchUntilSettled() async {
        let asked = query
        while !Task.isCancelled {
            let found = await model.searchAllBackups(pattern: asked)
            guard !Task.isCancelled else { return }
            answer = (asked, found)
            refreshPlanNames()
            selection.formIntersection(found.rows.map(\.id))
            guard !found.stillReading.isEmpty else { return }
            do {
                try await Task.sleep(for: DiskWatch.recheckInterval)
            } catch {
                return
            }
        }
    }

    /// What this answer could not cover, by repository. A broken index is its
    /// own line with its way out, and a repository still being read says so:
    /// a file missing from the rows may be in a backup not reached yet.
    private func standing(_ search: AllBackupsSearch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(search.failures, id: \.repositoryID) { failure in
                HStack(spacing: 8) {
                    WarningLine(text: "Couldn’t search “\(name(of: failure.repositoryID))”.")
                        .help(failure.message)
                    Spacer(minLength: 8)
                    Button("Try Again") {
                        model.rebuildIndex(repositoryID: failure.repositoryID)
                    }
                    .controlSize(.small)
                }
            }
            ForEach(search.stillReading, id: \.self) { repositoryID in
                HStack(spacing: 6) {
                    if isReachable(repositoryID) {
                        ProgressView().controlSize(.mini)
                    }
                    Text(readingLine(repositoryID))
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func name(of repositoryID: UUID) -> String {
        model.repositoryLabel(id: repositoryID) ?? "Location"
    }

    /// A repository out of reach is no longer being read: "still reading"
    /// would promise an end that needs the disk back.
    private func isReachable(_ repositoryID: UUID) -> Bool {
        switch model.snapshotListingOutcome(for: repositoryID) {
        case .failed, .passwordRefused, .notConnected: false
        case .idle, .loaded: true
        }
    }

    private func readingLine(_ repositoryID: UUID) -> String {
        if !isReachable(repositoryID) {
            return "“\(name(of: repositoryID))” can’t be reached, so files in backups not read yet won’t appear."
        }
        return "Still reading “\(name(of: repositoryID))”. Files in backups not read yet won’t appear."
    }

    @ViewBuilder
    private var results: some View {
        if query.isEmpty {
            ContentUnavailableView(
                "Find a file without knowing which backup holds it",
                systemImage: "magnifyingglass"
            )
        } else if let search {
            if search.rows.isEmpty {
                ContentUnavailableView(
                    "No matches",
                    systemImage: "magnifyingglass",
                    description: Text(search.isWhole
                        ? "Nothing in your backups matches. Each word you type matches the start of a word in a name."
                        : "Nothing matches so far. Some backups couldn’t be searched yet.")
                )
            } else {
                table(search.rows)
            }
        } else {
            ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func table(_ rows: [AllBackupsSearch.Row]) -> some View {
        let plans = rowPlanNames
        return Table(rows, selection: $selection) {
            TableColumn("File") { row in
                HStack(spacing: 6) {
                    FileKindIcon(type: .backedUp(name: row.name, isDirectory: row.isDirectory))
                        .accessibilityLabel(row.isDirectory ? "Folder" : "File")
                    Text(row.name).lineLimit(1)
                }
            }
            .width(min: 140, ideal: 180)

            TableColumn("Path") { row in
                Text(ResticPath.parent(of: row.path))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            // With one plan, every row is that plan's.
            if let plans {
                TableColumn("Plan") { row in
                    Text(plans[row.id] ?? "—")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 80, ideal: 120)
            }

            if model.configuration.repositories.count > 1 {
                TableColumn("Location") { row in
                    Text(name(of: row.repositoryID))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 80, ideal: 120)
            }

            TableColumn("Backup") { row in
                Text(Format.timestamp(row.snapshotTime))
                    .monospacedDigit()
            }
            .width(min: 130, ideal: 160)

            // How many backups hold the path; double-click is the way to them.
            TableColumn("Versions") { row in
                Text("\(row.versionsCount)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Format.plural(row.versionsCount, "version"))
            }
            .width(min: 60, ideal: 70)
        }
        .accessibilityIdentifier(AccessibilityID.FindFiles.results)
        .focusOnClick($resultsAreFocused)
        // An explicit right-click route to the restore the footer button
        // offers. Double-click shows the item in its backup, which moves no data:
        // an accidental double-tap must not start moving bytes.
        .contextMenu(forSelectionType: AllBackupsSearch.Row.ID.self) { ids in
            // The rows clicked are passed directly: a right-click on an
            // unselected row must not depend on selection state.
            let picked = rows.filter { ids.contains($0.id) }
            if picked.count == 1, let row = picked.first {
                Button("Restore") { restoreSelection(picked) }
                    .disabled(model.isRestoring)
                Button("Restore To…") { restoreSelection(picked, choosingDestination: true) }
                    .disabled(model.isRestoring)
                if let open = showInBackups(row) {
                    Button("Show in Backups", action: open)
                }
                if !row.isDirectory {
                    Button("Preview") { preview(row) }
                        .disabled(!model.isResticAvailable || previewer.isCopying)
                }
            } else if picked.count > 1, Self.oneRepository(picked) {
                Button("Restore") { restoreSelection(picked) }
                    .disabled(model.isRestoring)
                Button("Restore To…") { restoreSelection(picked, choosingDestination: true) }
                    .disabled(model.isRestoring)
            }
        } primaryAction: { ids in
            guard ids.count == 1, let row = rows.first(where: { ids.contains($0.id) }),
                  let open = showInBackups(row)
            else { return }
            open()
        }
        .onKeyPress(.space, phases: .down) { press in
            let picked = selectedRows
            let file = picked.count == 1 && !picked[0].isDirectory && model.isResticAvailable ? picked.first : nil
            return previewer.space(press, start: file.map { row in { preview(row) } })
        }
        // The table hands Return to its double-click action too: spent here
        // first, Return stays the footer's Restore.
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.isDisjoint(with: [.command, .option, .control, .shift]), canRestoreSelection
            else { return .ignored }
            restoreSelection(selectedRows)
            return .handled
        }
    }

    /// Each row's plan, or the group under Other backups its backup is
    /// shelved in, by the row's ID: one pass over each repository's
    /// listing, not one per cell.
    private func planNames(of rows: [AllBackupsSearch.Row]) -> [AllBackupsSearch.Row.ID: String] {
        var names: [AllBackupsSearch.Row.ID: String] = [:]
        for (repositoryID, repositoryRows) in Dictionary(grouping: rows, by: \.repositoryID) {
            let wanted = Set(repositoryRows.map(\.snapshotID))
            var labels: [String: String] = [:]
            for snapshot in model.snapshots(for: repositoryID) where wanted.contains(snapshot.id) {
                labels[snapshot.id] = model.recordLabel(of: snapshot, repositoryID: repositoryID)?.title
            }
            for row in repositoryRows { names[row.id] = labels[row.snapshotID] }
        }
        return names
    }

    private var footer: some View {
        HStack {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    // How many, not "across N snapshots": each row is its
                    // path at the newest backup holding it.
                    Text(Format.plural(rows.count, "match", "matches"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if search?.isTruncated == true {
                        Text(IndexWords.searchTruncated)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // Beside the results, never in place of them: the search did not
            // fail, and its rows are what the user is choosing from.
            if let failure = previewer.failure {
                WarningLine(text: failure.title)
                    .font(.caption)
                    .help(failure.message)
            }
            Spacer()
            Button("Restore") { restoreSelection(selectedRows) }
                .buttonStyle(.borderedProminent)
                // Same grammar as the Restore pane: Return restores, asking
                // first when something is in the way.
                .keyboardShortcut(.defaultAction)
                .disabled(!canRestoreSelection)
                .help(Self.oneRepository(selectedRows)
                    ? "Restore the selected items, each from the backup it was found in (Return)"
                    : "Select items from one location at a time")
        }
        .padding(12)
    }

    private var selectedRows: [AllBackupsSearch.Row] {
        rows.filter { selection.contains($0.id) }
    }

    private var canRestoreSelection: Bool {
        !selectedRows.isEmpty && Self.oneRepository(selectedRows) && !model.isRestoring
    }

    /// One restore runs against one repository, and its password.
    private static func oneRepository(_ rows: [AllBackupsSearch.Row]) -> Bool {
        Set(rows.map(\.repositoryID)).count <= 1
    }

    /// The row's backup on its page's Backups view, the item selected — a
    /// file's versions beside it; nil for a backup no longer listed.
    private func showInBackups(_ row: AllBackupsSearch.Row) -> (() -> Void)? {
        guard let page = model.page(ofBackup: row.snapshotID, in: row.repositoryID) else { return nil }
        return {
            router.showBackup(row.snapshotID, on: page, repositoryID: row.repositoryID, focusPath: row.path)
        }
    }

    /// The index carries no size, which the preview's size gate reads:
    /// restic lists the file first.
    private func preview(_ row: AllBackupsSearch.Row) {
        previewer.start(model, repositoryID: row.repositoryID, snapshotID: row.snapshotID) { [model] in
            try await model.listedNode(repositoryID: row.repositoryID, snapshotID: row.snapshotID, path: row.path)
        }
    }

    /// What the page restores, for File ▸ Restore and Restore To…: the
    /// selected rows.
    private var restore: RestoreCommand {
        RestoreCommand(
            isEnabled: canRestoreSelection,
            run: { restoreSelection(selectedRows, choosingDestination: $0) }
        )
    }

    /// Back where they were or, choosing, through the destination sheet
    /// (`restoreFlow`) — each from its row's backup, a folder leaving to
    /// itself only the rows of its own backup
    /// (`RestoreDestinationRequest.picked`). A row's kind is its search hit's,
    /// read again for its backup before it restores (`RestoreSource.node`).
    private func restoreSelection(_ picked: [AllBackupsSearch.Row], choosingDestination: Bool = false) {
        guard let repositoryID = picked.first?.repositoryID else { return }
        destinationRequest = RestoreDestinationRequest.picked(
            picked.map { row in
                RestoreSource(
                    name: row.name,
                    path: row.path,
                    isDirectory: row.isDirectory,
                    snapshotID: row.snapshotID,
                    backupTime: row.snapshotTime,
                    node: nil
                )
            },
            repositoryID: repositoryID,
            model: model,
            choosingDestination: choosingDestination
        )
    }
}


