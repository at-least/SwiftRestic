import SwiftUI

/// Searches every snapshot for a file, and restores what it finds.
///
/// This is the "I deleted something months ago and don't know which backup has
/// it" case, which browsing snapshot by snapshot does not solve.
///
/// Two engines sit behind one table. When the repository's index has finished
/// its backfill, the search runs against the local FTS index — instant, every
/// snapshot, no network. Otherwise the search falls back to `restic find`,
/// which walks the trees and takes as long as the history is deep.
struct FindFilesView: View {
    /// A search to start on arrival: the Restore pane's "Search All
    /// Backups…" carries its repository and query here.
    struct Prefill: Equatable, Sendable {
        let repositoryID: UUID
        let pattern: String
    }

    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.now) private var now

    private let prefill: Prefill?

    /// A file's Preview: its copy and its Quick Look panel.
    @State private var previewer = PreviewSession()
    @State private var repositoryID: UUID?
    @State private var pattern = ""
    @State private var latestOnly = false
    /// The table's rows, built once when a search's results land. A computed
    /// property would rebuild the snapshot-time dictionary and re-sort on
    /// every re-render — every keystroke in the pattern field — though a
    /// row's snapshot id (and therefore its time) is fixed by the search
    /// that produced it.
    @State private var rows: [Row] = []
    /// Whether the repository's index has finished its backfill. nil = not
    /// known yet for the selected repository.
    @State private var indexComplete: Bool?
    /// Several at a time, as in the Restore pane: Restore Selected…
    /// (Return) restores them together, each from its row's backup.
    @State private var selection = Set<String>()
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var hasSearched = false
    @State private var searchTask: Task<Void, Never>?
    /// True when the index search stopped early — at the hit cap, or (not
    /// expected, see `searchViaIndex`) a hit that came without its summary.
    /// The footer says so; a truncated list must not pass for the whole
    /// answer.
    @State private var resultsTruncated = false
    /// The sheet exists to answer one question, so the field that receives it
    /// takes focus on arrival — typing starts immediately.
    @FocusState private var patternFieldIsFocused: Bool
    /// Taken by a click in the results (`focusOnClick`): left in the
    /// pattern field, Return would search again — clearing the selection —
    /// instead of reaching Restore Selected….
    @FocusState private var resultsAreFocused: Bool
    /// The restore waiting in the destination sheet, over this one.
    @State private var destinationRequest: RestoreDestinationRequest?

    /// `initialRepositoryID` starts the picker when no prefill names a
    /// repository — the window selection's repository
    /// (`AppModel.findFilesRepositoryID`), read by the root, which can see
    /// the selection from where the sheet hangs.
    init(prefill: Prefill? = nil, initialRepositoryID: UUID? = nil) {
        self.prefill = prefill
        _repositoryID = State(initialValue: prefill?.repositoryID ?? initialRepositoryID)
        _pattern = State(initialValue: prefill?.pattern ?? "")
    }

    private struct Row: Identifiable {
        /// Byte-exact in the path (`PathKey.hex`): two paths whose names
        /// differ only in Unicode normalization are two rows, never one.
        /// Stored: SwiftUI reads it on every diff of the table.
        let id: String
        let match: FindMatch
        let snapshotID: String
        let snapshotTime: Date?
        /// How many backups hold the path: every indexed one for an index
        /// row, every searched one for a restic row — none for a search of
        /// the latest snapshot only, which looked at one.
        let versionsCount: Int?
        /// Index rows carry the search hit; a restore resolves the node from
        /// the row's snapshot first, whatever kind the hit says (`restore`).
        let hit: SearchHit?

        init(match: FindMatch, snapshotID: String, snapshotTime: Date?, versionsCount: Int? = nil, hit: SearchHit? = nil) {
            id = "\(snapshotID)/\(PathKey(match.path).hex)"
            self.match = match
            self.snapshotID = snapshotID
            self.snapshotTime = snapshotTime
            self.versionsCount = versionsCount
            self.hit = hit
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            resultsPane(rows)
            Divider()
            footer(rows)
        }
        .frame(minWidth: 760, minHeight: 480)
        .previewSession(previewer)
        .sheet(item: $destinationRequest) { request in
            RestoreDestinationSheet(request: request)
                .environment(model)
        }
        .onAppear {
            patternFieldIsFocused = true
            // A handed-over search runs at once; `search` picks the engine.
            if prefill != nil, canSearch { search() }
        }
        // The index-state check re-runs when the repository changes and is
        // cancelled when the sheet leaves, so a late answer cannot write
        // into state the sheet no longer owns. The previous repository's
        // answer goes first: it is not this one's.
        .task(id: repositoryID) {
            indexComplete = nil
            guard let repositoryID else { return }
            let ready = await model.indexIsComplete(repositoryID: repositoryID)
            guard !Task.isCancelled else { return }
            indexComplete = ready
        }
        .onDisappear { searchTask?.cancel() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            SheetHeader(
                title: "Find Files",
                subtitle: "Search every snapshot for a file, then restore what you find"
            )

            Picker("Repository", selection: $repositoryID) {
                Text("Choose…").tag(UUID?.none)
                ForEach(model.configuration.repositories) { repository in
                    Text(repository.name).tag(UUID?.some(repository.id))
                }
            }
            .onChange(of: repositoryID) { _, _ in
                // Results belong to the repository they were found in; keeping
                // them under a different picker would offer a restore against
                // the wrong one.
                cancelSearch()
            }

            HStack(spacing: 8) {
                // The prompt has to be verbatim: a literal string title is a
                // LocalizedStringKey, and SwiftUI parses those as Markdown — the
                // asterisks in a glob would be eaten as emphasis markers.
                TextField(
                    "Pattern",
                    text: $pattern,
                    prompt: Text(verbatim: indexComplete == true ? "File name, e.g. invoice or keynote" : "File name or pattern, e.g. invoice or *.key")
                )
                .textFieldStyle(.roundedBorder)
                .focused($patternFieldIsFocused)
                .onSubmit(search)
                // Meaningless against the index engine, which always searches
                // every version — so not offered until the engine is known:
                // ticked while the answer is pending, it would silently stop
                // applying when the answer is the index.
                if indexComplete == false {
                    Toggle("Latest snapshot only", isOn: $latestOnly)
                        .toggleStyle(.checkbox)
                }
                Button("Search", action: search)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSearch)
                // Occupying their space whether or not a search runs: appearing
                // here would shift the row at the exact moment of a click.
                Button("Stop") { cancelSearch() }
                    .disabled(!isSearching)
                    .opacity(isSearching ? 1 : 0)
                    .accessibilityHidden(!isSearching)
                ProgressView()
                    .controlSize(.small)
                    .opacity(isSearching ? 1 : 0)
                    .accessibilityHidden(!isSearching)
            }

            ExpandableCaption(
                summary: indexComplete == true
                    ? FilesSearchAnswer.matchRule
                    : "Matching is case-insensitive and supports shell globs.",
                detail: indexComplete == true
                    ? "This repository's index has finished reading, so the search runs locally against every snapshot at once — instant, however deep the history."
                    : "Searching every snapshot walks each one, so it takes longer the more history a repository holds. “Latest snapshot only” searches the repository's single newest snapshot — that snapshot may span other plans' folders, so it is not the newest per plan."
            )
        }
        .padding(12)
    }

    @ViewBuilder
    private func resultsPane(_ rows: [Row]) -> some View {
        if let errorMessage {
            ContentUnavailableView {
                Label("Search failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage).textSelection(.enabled)
            }
        } else if isSearching {
            ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            ContentUnavailableView(
                hasSearched ? "No matches" : "Search a repository",
                systemImage: "magnifyingglass",
                description: Text(
                    hasSearched
                        ? "Nothing in this repository's snapshots matches that pattern."
                        : "Find a file across every snapshot without knowing which one holds it."
                )
            )
        } else {
            Table(rows, selection: $selection) {
                TableColumn("File") { row in
                    HStack(spacing: 6) {
                        Image(systemName: row.match.isDirectory ? "folder.fill" : "doc")
                            .foregroundStyle(row.match.isDirectory ? Color.accentColor : .secondary)
                            // The kind, not the symbol's "Move" / "Document".
                            .accessibilityLabel(row.match.isDirectory ? "Folder" : "File")
                        Text(row.match.name).lineLimit(1)
                    }
                }
                .width(min: 140, ideal: 180)

                TableColumn("Path") { row in
                    Text((row.match.path as NSString).deletingLastPathComponent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                TableColumn("Snapshot") { row in
                    Text(row.snapshotTime.map { Format.timestamp($0) } ?? String(row.snapshotID.prefix(8)))
                        .monospacedDigit()
                }
                .width(min: 130, ideal: 160)

                TableColumn("Versions") { row in
                    // How many backups hold the path, and the way to them:
                    // Show Versions, as in the row's context menu. A search
                    // of the latest snapshot only looked at that one.
                    if let count = row.versionsCount, let open = showVersions(of: row) {
                        Button(action: open) {
                            HStack(spacing: 4) {
                                Text("of \(count)")
                                    .monospacedDigit()
                                Image(systemName: "chevron.forward")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .buttonStyle(HoverableButtonStyle())
                        .help("Show every backup that holds this path, on the Files tab")
                        .accessibilityLabel("Show versions: of \(count)")
                    } else {
                        Text(row.versionsCount.map { "of \($0)" } ?? "this one")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 60, ideal: 70)

                TableColumn("Size") { row in
                    Text(row.match.isDirectory ? "—" : Format.bytes(row.match.size))
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 84)
            }
            .focusOnClick($resultsAreFocused)
            // An explicit right-click route to the restore the footer button
            // offers. Double-click does nothing: an accidental double-tap
            // must not start moving bytes.
            .contextMenu(forSelectionType: Row.ID.self) { ids in
                // The rows clicked are passed directly: a right-click on an
                // unselected row must not depend on selection state.
                let picked = rows.filter { ids.contains($0.id) }
                if picked.count == 1, let row = picked.first {
                    Button("Restore “\(row.match.name)”…") {
                        restoreSelection(picked)
                    }
                    .disabled(model.isRestoring)
                    if let open = showVersions(of: row) {
                        Button("Show Versions", action: open)
                    }
                    if !row.match.isDirectory, let repositoryID {
                        // An index row carries no size: restic lists the
                        // file first, as its restore does, and the size
                        // gate reads that.
                        Button("Preview") {
                            previewer.start(model, repositoryID: repositoryID, snapshotID: row.snapshotID) { [model] in
                                row.hit == nil
                                    ? row.match.node
                                    : try await model.listedNode(repositoryID: repositoryID, snapshotID: row.snapshotID, path: row.match.path)
                            }
                        }
                        .disabled(!model.isResticAvailable || previewer.isCopying)
                    }
                } else if picked.count > 1 {
                    Button("Restore \(Format.plural(picked.count, "Item"))…") {
                        restoreSelection(picked)
                    }
                    .disabled(model.isRestoring)
                }
            }
        }
    }

    private func footer(_ rows: [Row]) -> some View {
        VStack(spacing: 10) {
            RestoreProgressStrip()

            HStack {
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        let snapshotCount = Set(rows.map(\.snapshotID)).count
                        Text("\(Format.plural(rows.count, "match", "matches")) across \(Format.plural(snapshotCount, "snapshot"))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        // When the listing was read: results carry snapshot
                        // stamps from that moment, so a list that predates a
                        // refresh in flight says so instead of passing as
                        // current.
                        if let loadedAt = repositoryID.flatMap({ model.snapshotsLoadedAt(for: $0) }) {
                            Text("Snapshot list read \(Format.ago(loadedAt, now: now))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                        if resultsTruncated {
                            Text("Showing the first matches — narrow the search to see more.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                // Beside the results, never in place of them: the search
                // did not fail, and its rows are what the user is choosing
                // from.
                if let failure = previewer.failure {
                    Label("Preview failed", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(failure)
                }
                Spacer()
                Button(model.isRestoring ? "Hide" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help(model.isRestoring ? "The restore keeps running" : "Close")
                let selected = rows.filter { selection.contains($0.id) }
                Button("Restore Selected…") { restoreSelection(selected) }
                    .buttonStyle(.borderedProminent)
                    // Same grammar as the Restore pane: Return offers the
                    // restore, always through the destination sheet, where
                    // the keep/replace choice lives.
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || model.isRestoring)
            }
        }
        .padding(12)
    }

    // MARK: - Data

    /// Show Versions for a row — out of the sheet, onto the Files tab that
    /// holds the match's history, at this match's backup — or nil when the
    /// row's backup is no longer listed. The row is passed directly: a click
    /// on an unselected row must not depend on selection state.
    private func showVersions(of row: Row) -> (() -> Void)? {
        guard let repositoryID,
              let record = model.snapshots(for: repositoryID).first(where: { $0.id == row.snapshotID })
        else { return nil }
        return {
            router.showVersions(
                path: row.match.path,
                isDirectory: row.match.isDirectory,
                in: record,
                repositoryID: repositoryID,
                page: model.shelves(for: repositoryID).page(of: record, repositoryID: repositoryID)
            )
            dismiss()
        }
    }

    private var canSearch: Bool {
        repositoryID != nil
            && !isSearching
            && !pattern.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func search() {
        guard let repositoryID, canSearch else { return }
        // Snapshot what was asked for: the fields can change while the search
        // walks the repository, and the results must answer to what was typed.
        let searchedRepository = repositoryID
        let searchedPattern = pattern.trimmingCharacters(in: .whitespaces)
        let searchedLatestOnly = latestOnly
        isSearching = true
        errorMessage = nil
        // Each search owns the footer's truncation line: an index search that
        // stopped early must not speak for a later restic-engine search that
        // ran to completion.
        resultsTruncated = false
        selection = []
        searchTask = Task {
            // The engine is chosen per search, not per sheet: a backfill that
            // finished while the sheet sat open upgrades the next search.
            let ready = await model.indexIsComplete(repositoryID: searchedRepository)
            guard !Task.isCancelled else { return }
            indexComplete = ready
            do {
                if ready {
                    let built = try await searchViaIndex(
                        pattern: searchedPattern, repositoryID: searchedRepository
                    )
                    guard !Task.isCancelled else { return }
                    rows = built
                } else {
                    let found = try await model.findFiles(
                        repositoryID: searchedRepository,
                        pattern: searchedPattern,
                        latestOnly: searchedLatestOnly
                    )
                    guard !Task.isCancelled else { return }
                    // Snapshot times resolve against the repository as of
                    // this search — the row's snapshot id is already fixed,
                    // so a later render must not re-derive or re-sort it.
                    let snapshots = model.snapshots(for: searchedRepository)
                    let times = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0.time) })
                    // Each backup's page, whose Files tab a row's "of N"
                    // must agree with: its count is that chain's.
                    let shelves = model.shelves(for: searchedRepository)
                    let pages = Dictionary(uniqueKeysWithValues: snapshots.map {
                        ($0.id, shelves.page(of: $0, repositoryID: searchedRepository))
                    })
                    // One row per path at its newest backup, newest first —
                    // usually the copy the user wants back — as the index
                    // engine's rows read.
                    rows = FindResultGrouping.rows(found, times: times, chain: { pages[$0] }).map {
                        Row(
                            match: $0.match, snapshotID: $0.snapshotID, snapshotTime: $0.snapshotTime,
                            versionsCount: searchedLatestOnly ? nil : $0.count
                        )
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                rows = []
                errorMessage = error.localizedDescription
            }
            hasSearched = true
            isSearching = false
            searchTask = nil
        }
    }

    /// The index engine: FTS over basenames, each hit read with its summary
    /// — the path's newest version and version count, not its whole list —
    /// in one read of the index, so every row names a restorable snapshot.
    /// Sorted newest-first by that snapshot, matching the restic engine's
    /// row order.
    private func searchViaIndex(pattern: String, repositoryID: UUID) async throws -> [Row] {
        // A thrown index failure propagates to the sheet's own error message.
        let found = try await model.searchIndexWithSummaries(pattern: pattern, repositoryID: repositoryID)
        var rows: [Row] = []
        var dropped = 0
        for hit in found.hits {
            guard let summary = found.summaries[PathKey(hit.path)] else {
                // Not expected: the search keeps only paths an indexed
                // backup holds, and the summary comes from the same read, so
                // every hit has one. Counted all the same, so a row that
                // went missing reads as a truncated list rather than
                // vanishing silently.
                dropped += 1
                continue
            }
            let newest = summary.newest
            let match = FindMatch(
                path: hit.path,
                type: hit.isDirectory ? "dir" : "file",
                size: nil,
                mtime: nil
            )
            rows.append(Row(
                match: match,
                snapshotID: newest.id,
                snapshotTime: newest.time,
                versionsCount: summary.count,
                hit: hit
            ))
        }
        resultsTruncated = dropped > 0 || found.hits.count >= AppModel.indexSearchLimit
        // Rows of one snapshot keep the search's order: name, then path,
        // bytewise — so equal times never shuffle between searches.
        return rows.enumerated()
            .sorted { a, b in
                let timeA = a.element.snapshotTime ?? .distantPast
                let timeB = b.element.snapshotTime ?? .distantPast
                return timeA != timeB ? timeA > timeB : a.offset < b.offset
            }
            .map(\.element)
    }

    /// Abandons the running search, if any. The view state is reset here rather
    /// than in the task: the cancelled task must not touch what a newer search
    /// or a different repository now owns.
    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        rows = []
        resultsTruncated = false
        hasSearched = false
        errorMessage = nil
        selection = []
    }

    /// Restores the picked rows through the destination sheet, where the
    /// keep/replace choice lives — each from its row's backup. A folder
    /// brings what its own backup holds of the rows inside it, and the
    /// sheet says so; a row found in an older backup than its folder's is
    /// one the folder's backup no longer holds, restored on its own
    /// (`RestoreBatch.covering`).
    private func restoreSelection(_ picked: [Row]) {
        guard let repositoryID else { return }
        let (restored, covered) = RestoreBatch.covering(picked, node: \.match.node, backup: \.snapshotID)
        let note = RestoreBatch.coveredNote(covered)
        guard let first = restored.first else { return }
        guard restored.count > 1 else {
            destinationRequest = RestoreDestinationRequest(
                subject: .item(name: first.match.name, path: first.match.path, isDirectory: first.match.isDirectory),
                selectionNote: note,
                backupTime: first.snapshotTime,
                snapshotShortID: String(first.snapshotID.prefix(8))
            ) { directories, overwrite in
                restore(first, repositoryID: repositoryID, to: directories[0], overwrite: overwrite)
            }
            return
        }
        let backups = Set(restored.map(\.snapshotID))
        destinationRequest = RestoreDestinationRequest(
            subject: .items(restored.map { RestoreItem(name: $0.match.name, path: $0.match.path, isDirectory: $0.match.isDirectory) }),
            selectionNote: note,
            backupTime: backups.count == 1 ? first.snapshotTime : nil,
            snapshotShortID: String(first.snapshotID.prefix(8)),
            backupCount: backups.count
        ) { directories, overwrite in
            Task {
                do {
                    // Index rows list their node first, as one row's
                    // restore does (`restore(_:repositoryID:to:overwrite:)`).
                    var items: [(snapshotID: String, node: SnapshotNode, directory: URL)] = []
                    for (row, directory) in zip(restored, directories) {
                        let node = row.hit == nil
                            ? row.match.node
                            : try await model.listedNode(repositoryID: repositoryID, snapshotID: row.snapshotID, path: row.match.path)
                        items.append((snapshotID: row.snapshotID, node: node, directory: directory))
                    }
                    model.restore(repositoryID: repositoryID, items: items, overwrite: overwrite)
                } catch {
                    errorMessage = (error as? ResticError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    /// Index rows resolve their node from the snapshot itself, no matter what
    /// kind the index gave. The hit's kind and the row's snapshot come from
    /// one read of the index, so they describe the same snapshot — but the
    /// index is a cache and restic the truth, and a kind it got wrong would
    /// send a folder to `dump`, which happily writes its tar into one file,
    /// no error. A listing that cannot answer fails the restore loudly
    /// instead.
    private func restore(_ row: Row, repositoryID: UUID, to destination: URL, overwrite: RestoreOverwritePolicy) {
        if row.hit == nil {
            // A restic-engine row: the node came from restic itself.
            model.restore(
                repositoryID: repositoryID,
                snapshotID: row.snapshotID,
                node: row.match.node,
                to: destination,
                overwrite: overwrite
            )
            return
        }
        Task {
            do {
                let node = try await model.listedNode(repositoryID: repositoryID, snapshotID: row.snapshotID, path: row.match.path)
                model.restore(
                    repositoryID: repositoryID,
                    snapshotID: row.snapshotID,
                    node: node,
                    to: destination,
                    overwrite: overwrite
                )
            } catch {
                errorMessage = (error as? ResticError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
