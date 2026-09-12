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
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var repositoryID: UUID?
    @State private var pattern = ""
    @State private var latestOnly = false
    @State private var results: [FindResult] = []
    /// Rows straight from the index engine; nil means the restic engine owns
    /// the table and `results` is the source.
    @State private var indexRows: [Row]?
    /// Whether the repository's index has finished its backfill. nil = not
    /// known yet for the selected repository.
    @State private var indexComplete: Bool?
    @State private var selection: String?
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var hasSearched = false
    @State private var searchTask: Task<Void, Never>?
    /// True when the index search stopped early — the hit cap, or paths
    /// whose every version has since been pruned. The footer says so; a
    /// truncated list must not pass for the whole answer.
    @State private var resultsTruncated = false
    /// The sheet exists to answer one question, so the field that receives it
    /// takes focus on arrival — typing starts immediately.
    @FocusState private var patternFieldIsFocused: Bool

    private struct Row: Identifiable {
        var id: String { "\(snapshotID)/\(match.path)" }
        var match: FindMatch
        var snapshotID: String
        var snapshotTime: Date?
        /// Index rows know how many versions the path has; restic rows do not.
        var versionsCount: Int?
        /// Index rows carry the search hit, whose kind may be unknown and in
        /// need of resolution before a restore.
        var hit: SearchHit?
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            resultsPane
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            if repositoryID == nil { repositoryID = model.configuration.repositories.first?.id }
            refreshIndexState()
            patternFieldIsFocused = true
        }
        .onChange(of: repositoryID) { _, _ in refreshIndexState() }
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
    private var resultsPane: some View {
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
                    // (older ones reachable through Browse Folders); the restic
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

    private var footer: some View {
        VStack(spacing: 10) {
            if let progress = model.restoreActivity {
                OperationProgressView(
                    title: model.restoreDescription,
                    progress: progress,
                    startedAt: nil,
                    onCancel: { model.cancelRestore() }
                )
            }
            Text("Restoring overwrites existing files at the destination.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        let snapshotCount = Set(rows.map(\.snapshotID)).count
                        Text("\(Format.plural(rows.count, "match")) across \(Format.plural(snapshotCount, "snapshot"))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        // When the listing was read: results carry snapshot
                        // stamps from that moment, so a list that predates a
                        // refresh in flight says so instead of passing as
                        // current.
                        if let loadedAt = repositoryID.flatMap({ model.snapshotsLoadedAt(for: $0) }) {
                            Text("Snapshot list read \(Format.relative(loadedAt))")
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
                Button("Restore Selected…") { restoreSelection(selectedRow) }
                    .buttonStyle(.borderedProminent)
                    // Same grammar as the snapshot browser: Return offers the
                    // restore, always through the destination picker where
                    // the overwrite warning lives.
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedRow == nil || model.isRestoring)
            }
        }
        .padding(12)
    }

    // MARK: - Data

    private var rows: [Row] {
        if let indexRows { return indexRows }
        let snapshots = repositoryID.map { model.snapshots(for: $0) } ?? []
        let times = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0.time) })
        return results
            .flatMap { result in
                result.matches.map {
                    Row(match: $0, snapshotID: result.snapshot, snapshotTime: times[result.snapshot])
                }
            }
            // Newest snapshot first: that is usually the copy the user wants back.
            .sorted { ($0.snapshotTime ?? .distantPast) > ($1.snapshotTime ?? .distantPast) }
    }

    private var selectedRow: Row? {
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
        selection = nil
        searchTask = Task {
            // The engine is chosen per search, not per sheet: a backfill that
            // finished while the sheet sat open upgrades the next search.
            let ready = await model.indexIsComplete(repositoryID: searchedRepository)
            guard !Task.isCancelled else { return }
            indexComplete = ready
            do {
                if ready {
                    let rows = try await searchViaIndex(
                        pattern: searchedPattern, repositoryID: searchedRepository
                    )
                    guard !Task.isCancelled else { return }
                    indexRows = rows
                    results = []
                } else {
                    let found = try await model.findFiles(
                        repositoryID: searchedRepository,
                        pattern: searchedPattern,
                        latestOnly: searchedLatestOnly
                    )
                    guard !Task.isCancelled else { return }
                    results = found
                    indexRows = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                indexRows = nil
                errorMessage = error.localizedDescription
            }
            hasSearched = true
            isSearching = false
            searchTask = nil
        }
    }

    /// The index engine: FTS over basenames, then a versions lookup per hit
    /// so every row names a restorable snapshot. Sorted newest-first by that
    /// snapshot, matching the restic engine's row order.
    private func searchViaIndex(pattern: String, repositoryID: UUID) async throws -> [Row] {
        let hits = try await model.searchIndex(pattern: pattern, repositoryID: repositoryID)
        var rows: [Row] = []
        var dropped = 0
        for hit in hits {
            let versions = await model.indexedVersions(ofPath: hit.path, repositoryID: repositoryID)
            guard let newest = versions.first else {
                // Every version of this path has since been pruned; there is
                // nothing restorable to list. Counted, so the footer can own
                // the gap instead of letting the row vanish silently.
                dropped += 1
                continue
            }
            let name = (hit.path as NSString).lastPathComponent
            let match = FindMatch(
                path: hit.path,
                type: hit.isDirectory == true ? "dir" : "file",
                size: nil,
                permissions: nil,
                mtime: nil
            )
            rows.append(Row(
                match: match,
                snapshotID: newest.id,
                snapshotTime: newest.time,
                versionsCount: versions.count,
                hit: hit
            ))
        }
        resultsTruncated = dropped > 0 || hits.count >= 200
        return rows
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
        resultsTruncated = false
        hasSearched = false
        errorMessage = nil
        selection = nil
    }

    /// Re-reads whether the selected repository's index is ready — the switch
    /// behind the engine choice and the toggle's visibility. The answer is
    /// discarded if the user has switched repository meanwhile.
    private func refreshIndexState() {
        guard let repositoryID else { indexComplete = nil; return }
        Task {
            let ready = await model.indexIsComplete(repositoryID: repositoryID)
            guard self.repositoryID == repositoryID else { return }
            indexComplete = ready
        }
    }

    /// Restores the given row through the destination picker, where the
    /// overwrite warning lives.
    ///
    /// Index rows resolve their node from the snapshot itself, no matter what
    /// kind the index recorded: the search table's kind is first-writer-wins,
    /// and a path that changed from file to directory would otherwise take
    /// `dump` — which happily writes a folder's tar into one file, no error.
    /// A listing that cannot answer fails the restore loudly instead.
    private func restoreSelection(_ row: Row?) {
        guard let row, let repositoryID else { return }
        guard let destination = FilePicker.chooseDirectory(
            message: "Choose where to restore “\(row.match.name)”. Restoring overwrites existing files at the destination.",
            prompt: "Restore"
        ) else { return }

        if row.hit == nil {
            // A restic-engine row: the node came from restic itself.
            model.restore(
                repositoryID: repositoryID,
                snapshotID: row.snapshotID,
                node: row.match.node,
                to: destination
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
                guard let node = children.first(where: { $0.path == row.match.path }) else {
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
                    to: destination
                )
            } catch {
                errorMessage = (error as? ResticError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
