import SwiftUI

/// Search All Backups: every repository's index, as the query is typed in the
/// toolbar field — the "I deleted something months ago and don't know which
/// backup has it" case. A page, not a sheet: its restores would stack a second
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
    /// Several at a time, as in a backup's tree: Restore Selected (Return)
    /// restores them together, each from its row's backup.
    @State private var selection = Set<String>()
    /// The toolbar field, focused on arrival — the page exists to answer one
    /// question — and by ⌘F.
    @FocusState private var searchIsFocused: Bool
    /// Taken by a click in the results (`focusOnClick`): left in the field,
    /// Return would go nowhere instead of reaching Restore Selected.
    @FocusState private var resultsAreFocused: Bool
    @State private var destinationRequest: RestoreDestinationRequest?

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
            controls
            Divider()
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
        .sheet(item: $destinationRequest) { request in
            RestoreDestinationSheet(request: request)
                .environment(model)
        }
        .onChange(of: router.searchFocus, initial: true) { _, page in
            guard page == .findFiles else { return }
            router.searchFocus = nil
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
    }

    private func searchUntilSettled() async {
        let asked = query
        while !Task.isCancelled {
            let found = await model.searchAllBackups(pattern: asked)
            guard !Task.isCancelled else { return }
            answer = (asked, found)
            selection.formIntersection(found.rows.map(\.id))
            guard !found.stillReading.isEmpty else { return }
            do {
                try await Task.sleep(for: FilesTree.recheckInterval)
            } catch {
                return
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            // Back to the plan the search came from, its query kept.
            if let origin = router.findOrigin, model.filesSearchRoots(for: origin.page) == origin.roots {
                SearchScopePicker(scope: .allBackups) { router.returnToPlanSearch() }
            }
            ExpandableCaption(
                summary: "Searches every backup as you type.",
                detail: FilesSearchAnswer.matchRule + " The search runs on this Mac, however deep the history."
            )
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    /// What this answer could not cover, by repository. A broken index is its
    /// own line with its way out, and a repository still being read says so:
    /// a file missing from the rows may be in a backup not reached yet.
    private func standing(_ search: AllBackupsSearch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(search.failures, id: \.repositoryID) { failure in
                HStack(spacing: 8) {
                    Label("Couldn’t search “\(name(of: failure.repositoryID))”.", systemImage: "exclamationmark.triangle.fill")
                        .help(failure.message)
                    Spacer(minLength: 8)
                    Button("Rebuild Search Index…") {
                        router.request(.confirm(.rebuildIndex(failure.repositoryID)))
                    }
                    .controlSize(.small)
                }
            }
            ForEach(search.stillReading, id: \.self) { repositoryID in
                Label(readingLine(repositoryID), systemImage: "clock.arrow.circlepath")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func name(of repositoryID: UUID) -> String {
        model.repository(id: repositoryID).map { model.label(of: $0) } ?? "Repository"
    }

    /// A repository out of reach is no longer being read: "still reading"
    /// would promise an end that needs the disk back.
    private func readingLine(_ repositoryID: UUID) -> String {
        if case .failed = model.snapshotListingOutcome(for: repositoryID) {
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
                        ? "Nothing in your backups matches."
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
        Table(rows, selection: $selection) {
            TableColumn("File") { row in
                HStack(spacing: 6) {
                    Image(systemName: row.isDirectory ? "folder.fill" : "doc")
                        .foregroundStyle(row.isDirectory ? Color.accentColor : .secondary)
                        // The kind, not the symbol's "Move" / "Document".
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

            if model.configuration.repositories.count > 1 {
                TableColumn("Repository") { row in
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

            TableColumn("Versions") { row in
                // How many backups hold the path, and the way to them.
                if let open = showVersions(of: row) {
                    Button(action: open) {
                        HStack(spacing: 4) {
                            Text("\(row.versionsCount)")
                                .monospacedDigit()
                            RowChevron()
                        }
                    }
                    .buttonStyle(HoverableButtonStyle())
                    .help("Show every backup that holds this file, on the Files tab")
                    .accessibilityLabel("Show \(Format.plural(row.versionsCount, "version"))")
                } else {
                    Text("\(row.versionsCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 60, ideal: 70)
        }
        .focusOnClick($resultsAreFocused)
        // An explicit right-click route to the restore the footer button
        // offers. Double-click does nothing: an accidental double-tap must
        // not start moving bytes.
        .contextMenu(forSelectionType: AllBackupsSearch.Row.ID.self) { ids in
            // The rows clicked are passed directly: a right-click on an
            // unselected row must not depend on selection state.
            let picked = rows.filter { ids.contains($0.id) }
            if picked.count == 1, let row = picked.first {
                Button("Restore…") { restoreSelection(picked) }
                    .disabled(model.isRestoring)
                if let open = showVersions(of: row) {
                    Button("Show Versions", action: open)
                }
                if let open = showInBackups(row) {
                    Button("Show in Backups", action: open)
                }
                if !row.isDirectory {
                    // The index carries no size, which the preview's size
                    // gate reads: restic lists the file first.
                    Button("Preview") {
                        previewer.start(model, repositoryID: row.repositoryID, snapshotID: row.snapshotID) { [model] in
                            try await model.listedNode(repositoryID: row.repositoryID, snapshotID: row.snapshotID, path: row.path)
                        }
                    }
                    .disabled(!model.isResticAvailable || previewer.isCopying)
                }
            } else if picked.count > 1, Self.oneRepository(picked) {
                Button("Restore \(Format.plural(picked.count, "Item"))…") { restoreSelection(picked) }
                    .disabled(model.isRestoring)
            }
        }
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
                        Text(FilesSearchAnswer.searchTruncated)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // Beside the results, never in place of them: the search did not
            // fail, and its rows are what the user is choosing from.
            if let failure = previewer.failure {
                Label(failure.title, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(failure.message)
            }
            Spacer()
            Button("Restore Selected…") { restoreSelection(selectedRows) }
                .buttonStyle(.borderedProminent)
                // Same grammar as the Restore pane: Return offers the
                // restore, always through the destination sheet, where the
                // keep/replace choice lives.
                .keyboardShortcut(.defaultAction)
                .disabled(!canRestoreSelection)
                .help(Self.oneRepository(selectedRows)
                    ? "Restore the selected items, each from the backup it was found in (Return)"
                    : "Select items from one repository at a time")
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

    /// Show Versions for a file's row — onto the Files tab of the plan that
    /// holds its history — or nil for a folder, for a backup no longer listed,
    /// or one no plan made (a group under Other backups has no Files tab).
    private func showVersions(of row: AllBackupsSearch.Row) -> (() -> Void)? {
        guard !row.isDirectory,
              let record = model.snapshots(for: row.repositoryID).first(where: { $0.id == row.snapshotID }),
              let page = model.shelves(for: row.repositoryID).versionsPage(of: record)
        else { return nil }
        return {
            router.showVersions(
                path: row.path, isDirectory: false, in: record, repositoryID: row.repositoryID, page: page
            )
        }
    }

    private func showInBackups(_ row: AllBackupsSearch.Row) -> (() -> Void)? {
        guard row.isDirectory, let page = model.page(ofBackup: row.snapshotID, in: row.repositoryID) else { return nil }
        return {
            router.showBackup(row.snapshotID, on: page, repositoryID: row.repositoryID, focusPath: row.path)
        }
    }

    /// What the page restores, for File ▸ Restore: the selected rows.
    private var restore: RestoreCommand {
        RestoreCommand(
            title: "Restore Selected…",
            isEnabled: canRestoreSelection,
            run: { restoreSelection(selectedRows) }
        )
    }

    /// Through the destination sheet — each from its row's backup, a folder
    /// leaving to itself only the rows of its own backup
    /// (`RestoreDestinationRequest.picked`). A row's kind is its search hit's,
    /// read again for its backup before it restores (`RestoreSource.node`).
    private func restoreSelection(_ picked: [AllBackupsSearch.Row]) {
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
            model: model
        )
    }
}

/// Where a search looks: this plan, or everything. Finder's search scope, in
/// the two places a search shows its results. Picking the other one hands the
/// query over.
struct SearchScopePicker: View {
    enum Scope: Hashable {
        case thisPlan
        case allBackups
    }

    let scope: Scope
    let onChange: () -> Void

    var body: some View {
        Picker("Search", selection: Binding(
            get: { scope },
            set: { if $0 != scope { onChange() } }
        )) {
            Text("This Plan").tag(Scope.thisPlan)
            Text("All Backups").tag(Scope.allBackups)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// A broken search index's failure, with its way out. Nothing the index
/// answered can be trusted as "nothing matches" while this stands.
struct IndexFailureView: View {
    @Environment(AppRouter.self) private var router
    let title: String
    let message: String
    let repositoryID: UUID

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Rebuild Search Index…") {
                router.request(.confirm(.rebuildIndex(repositoryID)))
            }
        }
    }
}
