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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.now) private var now

    private let prefill: Prefill?

    @State private var repositoryID: UUID?
    @State private var pattern = ""
    @State private var latestOnly = false
    @State private var results: [FindResult] = []
    /// Rows straight from the index engine; nil means the restic engine owns
    /// the table and `results` is the source.
    @State private var indexRows: [Row]?
    /// The table's rows, built once when a search's results land. A computed
    /// property would rebuild the snapshot-time dictionary and re-sort on
    /// every re-render — every keystroke in the pattern field — though a
    /// row's snapshot id (and therefore its time) is fixed by the search
    /// that produced it.
    @State private var rows: [Row] = []
    /// Whether the repository's index has finished its backfill. nil = not
    /// known yet for the selected repository.
    @State private var indexComplete: Bool?
    @State private var selection: String?
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
    /// pattern field, Return searched again — clearing the selection —
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
        /// Index rows know how many versions the path has; restic rows do not.
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
        .sheet(item: $destinationRequest) { request in
            RestoreDestinationSheet(request: request)
                .environment(model)
        }
        .onAppear {
            patternFieldIsFocused = true
            // A handed-over search runs at once; `search` picks the engine.
            if prefill != nil, canSearch { search() }
        }
        // The index-state check re-runs when the repository changes and
        // cancels itself when the sheet leaves — a plain `Task` here used to
        // answer after dismissal and write into detached state storage.
        .task(id: repositoryID) {
            guard let repositoryID else { indexComplete = nil; return }
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
                    prompt: Text(verbatim: indexComplete == true ? "File name, e.g. invoice or keynote" : "File name or pattern, e.g. *.key or invoice*")
                )
                .textFieldStyle(.roundedBorder)
                .focused($patternFieldIsFocused)
                .onSubmit(search)
                // Meaningless against the index engine, which always searches
                // every version.
                if indexComplete != true {
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
                    ? "Matching is case-insensitive; whole words match from anywhere in the name."
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
                    // The index engine knows how many snapshots hold the path
                    // (older ones reachable through the Files view); the restic
                    // engine walked exactly what it lists.
                    Text(row.versionsCount.map { "of \($0)" } ?? "this one")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
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
            // offers. Double-click deliberately does nothing: an accidental
            // double-tap must not start moving bytes.
            .contextMenu(forSelectionType: Row.ID.self) { ids in
                if let id = ids.first, ids.count == 1,
                   let row = rows.first(where: { $0.id == id }) {
                    // The row is passed directly: a right-click on an
                    // unselected row must not depend on selection state.
                    Button("Restore “\(row.match.name)”…") {
                        restoreSelection(row)
                    }
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
                Spacer()
                Button(model.isRestoring ? "Hide" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help(model.isRestoring ? "The restore keeps running" : "Close")
                let selected = selectedRow(in: rows)
                Button("Restore Selected…") { restoreSelection(selected) }
                    .buttonStyle(.borderedProminent)
                    // Same grammar as the Restore pane: Return offers the
                    // restore, always through the destination sheet, where
                    // the keep/replace choice lives.
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil || model.isRestoring)
            }
        }
        .padding(12)
    }

    // MARK: - Data

    private func selectedRow(in rows: [Row]) -> Row? {
        guard let selection else { return nil }
        return rows.first { $0.id == selection }
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
        selection = nil
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
                    indexRows = built
                    results = []
                    rows = built
                } else {
                    let found = try await model.findFiles(
                        repositoryID: searchedRepository,
                        pattern: searchedPattern,
                        latestOnly: searchedLatestOnly
                    )
                    guard !Task.isCancelled else { return }
                    results = found
                    indexRows = nil
                    // Snapshot times resolve against the repository as of
                    // this search — the row's snapshot id is already fixed,
                    // so a later render must not re-derive or re-sort it.
                    let snapshots = model.snapshots(for: searchedRepository)
                    let times = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0.time) })
                    rows = found
                        .flatMap { result in
                            result.matches.map {
                                Row(match: $0, snapshotID: result.snapshot, snapshotTime: times[result.snapshot])
                            }
                        }
                        // Newest snapshot first: that is usually the copy the user wants back.
                        .sorted { ($0.snapshotTime ?? .distantPast) > ($1.snapshotTime ?? .distantPast) }
                }
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                indexRows = nil
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
                permissions: nil,
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
        results = []
        indexRows = nil
        rows = []
        resultsTruncated = false
        hasSearched = false
        errorMessage = nil
        selection = nil
    }

    /// Restores the given row through the destination sheet, where the
    /// keep/replace choice lives.
    private func restoreSelection(_ row: Row?) {
        guard let row, let repositoryID else { return }
        destinationRequest = RestoreDestinationRequest(
            subject: .item(name: row.match.name, path: row.match.path, isDirectory: row.match.isDirectory),
            backupTime: row.snapshotTime,
            snapshotShortID: String(row.snapshotID.prefix(8))
        ) { directories, overwrite in
            restore(row, repositoryID: repositoryID, to: directories[0], overwrite: overwrite)
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
                let parent = (row.match.path as NSString).deletingLastPathComponent
                let children = try await model.children(
                    repositoryID: repositoryID,
                    snapshotID: row.snapshotID,
                    path: parent
                )
                // By bytes: a sibling whose name only canonically equals
                // this one is another file, and restoring it would restore
                // the wrong item under this row's name and kind.
                guard let node = children.first(where: { PathKey($0.path) == PathKey(row.match.path) }) else {
                    throw ResticError.commandFailed(
                        exitCode: 0,
                        message: "“\(row.match.name)” is no longer listed in the chosen snapshot — refresh and try again.",
                        command: "ls"
                    )
                }
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
