import SwiftUI

struct SnapshotDiffTarget: Identifiable {
    var repositoryID: UUID
    /// The newer of the two snapshots; the older one is chosen inside the sheet.
    var snapshot: Snapshot
    var id: String { "\(repositoryID.uuidString)-\(snapshot.id)-diff" }
}

/// What changed between two snapshots, via `restic diff`.
///
/// Answers "what did last night's backup actually pick up?" without restoring
/// anything. The comparison defaults to the previous snapshot of the same
/// folders from the same Mac; anything earlier in the repository can be chosen.
/// A row leads on, as every list of items does: Show Versions (also a
/// double-click) and Restore…, from the backup of the two that holds it.
struct SnapshotDiffView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.now) private var now

    let target: SnapshotDiffTarget

    @State private var olderID: String?
    @State private var includeMetadata = false
    @State private var diff: SnapshotDiff?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var filter: ResticDiffChange.Category?
    @State private var searchText = ""
    /// The query the filter actually applies: `searchText` as it settles —
    /// every keystroke restarts the debounce task below, and the row scan
    /// runs under this settled value (see `computeRows`), so typing a word
    /// scans once at the end, not once per character over up to twenty
    /// thousand changes.
    @State private var appliedSearchText = ""
    /// The diff's pre-lowercased search index, rebuilt when a diff lands —
    /// not on every keystroke it exists to serve.
    @State private var search = DiffChangeSearch(changes: [])
    /// The change rows the category gate and settled needle admit, computed
    /// off the render path (see `computeRows`). `nil` means no pass has
    /// landed for the current inputs yet.
    @State private var filteredRows: [ResticDiffChange]?
    /// Bumped by every `installDiff`, so a new diff's rows recompute even
    /// when its filter and needle read the same as the last one's.
    @State private var diffLoad = 0
    @State private var selection = Set<ResticDiffChange.ID>()
    /// The restore waiting in the destination sheet.
    @State private var destinationRequest: RestoreDestinationRequest?

    private var newer: Snapshot { target.snapshot }

    /// Every snapshot older than the one being examined, newest first.
    private var candidates: [Snapshot] {
        model.snapshots(for: target.repositoryID)
            .filter { $0.time < newer.time }
            .sorted { $0.time > $1.time }
    }

    /// One identity for the row pass's inputs: which diff, which category
    /// gate, which settled needle. A change to any of the three is the only
    /// thing that may re-run the scan.
    private struct RowFilterKey: Equatable {
        var load: Int
        var category: ResticDiffChange.Category?
        var needle: String
    }

    var body: some View {
        // One filter+sort per render: the header and the content each need
        // the candidates, and a computed property would re-evaluate the sort
        // at every access — this sheet re-renders on every keystroke in its
        // filter field.
        let candidates = self.candidates
        return VStack(spacing: 0) {
            header(candidates)
            Divider()
            content(candidates, rows: filteredRows)
            Divider()
            footer(filteredRows)
        }
        .frame(minWidth: 760, minHeight: 500)
        .onAppear {
            // The previous backup of the same folders from the same host, or
            // nothing: a lineage's first backup has no natural baseline, and
            // any older snapshot — usually another plan's tree — diffs as
            // every file added or removed. The picker still reaches any
            // snapshot.
            if olderID == nil {
                olderID = newer.previousComparable(in: model.snapshots(for: target.repositoryID))?.id
            }
        }
        .task(id: "\(olderID ?? "")|\(includeMetadata)") { await load() }
        .task(id: searchText) {
            // Restarted by every keystroke: only the settled query filters.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            appliedSearchText = searchText
        }
        .task(id: RowFilterKey(load: diffLoad, category: filter, needle: appliedSearchText)) {
            await computeRows()
        }
        .sheet(item: $destinationRequest) { request in
            RestoreDestinationSheet(request: request)
                .environment(model)
        }
    }

    // MARK: - Sections

    private func header(_ candidates: [Snapshot]) -> some View {
        // Both groupings are one pass over the candidates, with the date
        // formatters running once per distinct bucket — `DiffCandidateGrouping`
        // holds the exact costs, and the test bundle pins them.
        let sharedMinutes = DiffCandidateGrouping.sharedDisplayedMinutes(in: candidates)
        let grouped = DiffCandidateGrouping.months(in: candidates)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    // The sheet's scope is exactly one repository, and the
                    // header says which — no suffix only in the window where
                    // the repository was just removed and the load below has
                    // nothing to compare anyway.
                    Text(
                        "Changes in snapshot \(newer.shortID)"
                            + (model.repository(id: target.repositoryID).map { " — \($0.name)" } ?? "")
                    )
                        .font(.headline)
                    Text(Format.timestamp(newer.time))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Include metadata changes", isOn: $includeMetadata)
                    .toggleStyle(.checkbox)
                    .help("Also list files whose permissions, owner or timestamps changed but whose content did not")
            }

            HStack(spacing: 8) {
                Picker("Compared with", selection: $olderID) {
                    // The no-baseline state needs a row of its own, or the
                    // picker holds a selection none of its items carry.
                    if olderID == nil {
                        Text("Choose a snapshot").tag(String?.none)
                    }
                    // Grouped by month: a year of hourly snapshots is a
                    // thousand-row flat scroll, and a header to park the eye
                    // on is the cheapest jump a menu can offer.
                    ForEach(grouped, id: \.label) { group in
                        Section(group.label) {
                            ForEach(group.items) { snapshot in
                                Text(comparisonLabel(snapshot, sharedMinutes: sharedMinutes))
                                    .tag(String?.some(snapshot.id))
                            }
                        }
                    }
                }
                .frame(maxWidth: 420)
                .disabled(candidates.isEmpty)

                if let older = candidates.first(where: { $0.id == olderID }),
                   older.lineageKey != newer.lineageKey {
                    Label("Different folders or host — most entries will show as added or removed", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func content(_ candidates: [Snapshot], rows: [ResticDiffChange]?) -> some View {
        if candidates.isEmpty {
            ContentUnavailableView(
                "Nothing to compare against",
                systemImage: "clock.arrow.circlepath",
                description: Text("This is the oldest snapshot in the repository.")
            )
        } else if olderID == nil {
            ContentUnavailableView(
                "No earlier backup of these folders",
                systemImage: "clock.arrow.circlepath",
                description: Text("This is the first snapshot of these folders from \(newer.hostname ?? "this host"). Choose another snapshot above to compare with it anyway.")
            )
        } else if isLoading {
            ProgressView("Comparing…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            ContentUnavailableView {
                Label("Could not compare these snapshots", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError).textSelection(.enabled)
            }
        } else if let diff {
            VStack(spacing: 0) {
                statistics(diff)
                Divider()
                filters(diff)
                Divider()
                changeList(diff, rows: rows)
            }
        } else {
            Color.clear
        }
    }

    private func statistics(_ diff: SnapshotDiff) -> some View {
        let stats = diff.statistics
        return HStack(alignment: .center, spacing: 10) {
            StatTile(
                title: "Added",
                value: countText(stats?.added)
            )
            StatTile(
                title: "Removed",
                value: countText(stats?.removed)
            )
            // restic's `changed_files` counts content changes only; the Modified
            // filter also includes type changes and bitrot, so the tooltip names
            // it precisely while the tile stays short enough not to truncate.
            // "N files" agrees with the Added/Removed tiles' unit spelling.
            StatTile(
                title: "Changed",
                value: stats.map { Format.plural($0.changedFiles, "file") } ?? "—",
                help: "Files whose content changed — metadata-only edits are listed under Show › Metadata"
            )
            // The byte pair is this sheet's headline answer — "what did the
            // backup actually pick up?" — so it leaves the count tiles' row
            // and reads as one unit: what went in, what came out.
            VStack(alignment: .leading, spacing: 4) {
                Text("Data changed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label {
                    Text(Format.bytes(stats?.added.bytes))
                        .monospacedDigit()
                } icon: {
                    Text("+")
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                }
                .foregroundStyle(StatusPalette.status(.succeeded))
                .accessibilityLabel("\(Format.bytes(stats?.added.bytes)) added")
                Label {
                    Text(Format.bytes(stats?.removed.bytes))
                        .monospacedDigit()
                } icon: {
                    Text("−")
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                }
                .foregroundStyle(StatusPalette.status(.failed))
                .accessibilityLabel("\(Format.bytes(stats?.removed.bytes)) removed")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.cardPadding)
            .cardSurface()
            .help("Bytes written to the repository by this snapshot, and bytes the repository no longer holds because of it")
        }
        .padding(12)
    }

    private func filters(_ diff: SnapshotDiff) -> some View {
        HStack(spacing: 10) {
            Picker("Show", selection: $filter) {
                Text("All (\(Format.count(diff.changes.count)))").tag(ResticDiffChange.Category?.none)
                ForEach(visibleCategories) { category in
                    Text("\(category.displayName) (\(Format.count(diff.count(of: category))))")
                        .tag(ResticDiffChange.Category?.some(category))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            TextField("Filter by path", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func changeList(_ diff: SnapshotDiff, rows: [ResticDiffChange]?) -> some View {
        if diff.changes.isEmpty {
            ContentUnavailableView(
                "No differences",
                systemImage: "equal.circle",
                description: Text("The two snapshots contain the same files.")
            )
        } else if let rows {
            if rows.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(rows, selection: $selection) { change in
                    HStack(spacing: 8) {
                        Text(glyph(for: change))
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .foregroundStyle(color(for: change.category))
                            .frame(width: 22, alignment: .center)
                            .help(change.explanation)
                            // VoiceOver reads "plus"; the explanation says "added".
                            .accessibilityLabel(change.explanation)
                        Image(systemName: change.isDirectory ? "folder" : "doc")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                            .accessibilityLabel(change.isDirectory ? "Folder" : "File")
                        Text(change.path)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .textSelection(.enabled)
                        Spacer()
                        if change.modifier.count > 1 {
                            Text(change.modifier)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .help(change.explanation)
                                .accessibilityLabel(change.explanation)
                        }
                    }
                }
                .listStyle(.inset)
                // The row is the one clicked, not the selection's: a
                // right-click on an unselected row must not depend on it.
                .contextMenu(forSelectionType: ResticDiffChange.ID.self) { ids in
                    if ids.count == 1, let change = rows.first(where: { $0.id == ids.first }) {
                        if let open = showVersions(of: change) {
                            Button("Show Versions", action: open)
                        }
                        Button("Restore “\(change.name)”…") { restore(change) }
                            .disabled(model.isRestoring || holder(of: change) == nil)
                    } else if ids.count > 1 {
                        let picked = rows.filter { ids.contains($0.id) }
                        Button("Restore \(Format.plural(picked.count, "Item"))…") { restoreSelection(picked) }
                            .disabled(model.isRestoring || picked.allSatisfy { holder(of: $0) == nil })
                    }
                } primaryAction: { ids in
                    // Opens, never restores: a double-tap must not move bytes.
                    guard ids.count == 1, let change = rows.first(where: { $0.id == ids.first }) else { return }
                    showVersions(of: change)?()
                }
                .help("Double-click shows an item's versions; Return or right-click restores the selection, each item from the backup that has it")
            }
        } else {
            // The filter pass for these inputs is still in flight — a blank
            // instant here would read as "no matches" for a query that has
            // not answered yet.
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func footer(_ changeRows: [ResticDiffChange]?) -> some View {
        VStack(spacing: 10) {
            RestoreProgressStrip()
            HStack {
                if let diff, let shown = changeRows?.count {
                    Text(footerText(diff, shown: shown))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // A restore keeps running with the sheet gone, as Find
                // Files' does.
                Button(model.isRestoring ? "Hide" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // Find Files' grammar: Return restores the selection, each
                // row from the backup that has it, through the destination
                // sheet.
                let selected = (changeRows ?? []).filter { selection.contains($0.id) }
                Button("Restore Selected…") { restoreSelection(selected) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isRestoring || selected.allSatisfy { holder(of: $0) == nil })
            }
        }
        .padding(12)
    }

    // MARK: - Routes

    /// The backup of the two compared that holds a row's item
    /// (`ResticDiffChange.holder`): the rows are the loaded diff's, so its
    /// older backup, which the picker may already have moved past. Nil once
    /// that backup is no longer listed.
    private func holder(of change: ResticDiffChange) -> Snapshot? {
        guard let diff, let older = model.snapshots(for: target.repositoryID).first(where: { $0.id == diff.olderID })
        else { return nil }
        return change.holder(newer: newer, older: older)
    }

    /// Show Versions for a row — out of the sheet, onto the Files tab that
    /// holds the item's history, at the backup that has it.
    private func showVersions(of change: ResticDiffChange) -> (() -> Void)? {
        guard let record = holder(of: change) else { return nil }
        let repositoryID = target.repositoryID
        return {
            router.showVersions(
                path: ResticPath.normalized(change.path),
                isDirectory: change.isDirectory,
                in: record,
                repositoryID: repositoryID,
                page: model.shelves(for: repositoryID).page(of: record, repositoryID: repositoryID)
            )
            dismiss()
        }
    }

    /// Restores the selected rows together: one destination sheet and one
    /// run, each from the backup that has it (`DiffRestoreSelection`).
    private func restoreSelection(_ picked: [ResticDiffChange]) {
        let (items, note) = DiffRestoreSelection.plan(picked) { holder(of: $0) }
        guard let first = items.first else { return }
        guard items.count > 1 else {
            restore(first.change, selectionNote: note)
            return
        }
        let repositoryID = target.repositoryID
        let backups = Set(items.map(\.backup.id))
        destinationRequest = RestoreDestinationRequest(
            subject: .items(items.map { RestoreItem(name: $0.change.name, path: $0.path, isDirectory: $0.change.isDirectory) }),
            selectionNote: note,
            backupTime: backups.count == 1 ? first.backup.time : nil,
            snapshotShortID: first.backup.shortID,
            backupCount: backups.count
        ) { directories, overwrite in
            Task {
                do {
                    var restored: [(snapshotID: String, node: SnapshotNode, directory: URL)] = []
                    for (item, directory) in zip(items, directories) {
                        let node = try await model.listedNode(repositoryID: repositoryID, snapshotID: item.backup.id, path: item.path)
                        restored.append((snapshotID: item.backup.id, node: node, directory: directory))
                    }
                    model.restore(repositoryID: repositoryID, items: restored, overwrite: overwrite)
                } catch {
                    model.post(Banner(title: "Could not restore the selected items", message: error.localizedDescription, isError: true))
                }
            }
        }
    }

    /// Restores a row's item from the backup that has it, through the
    /// destination sheet. restic lists the node first (`listedNode`): a
    /// diff names a path and a kind, never a node.
    private func restore(_ change: ResticDiffChange, selectionNote: String? = nil) {
        guard let record = holder(of: change) else { return }
        let repositoryID = target.repositoryID
        let path = ResticPath.normalized(change.path)
        destinationRequest = RestoreDestinationRequest(
            subject: .item(name: change.name, path: path, isDirectory: change.isDirectory),
            selectionNote: selectionNote,
            backupTime: record.time,
            snapshotShortID: record.shortID
        ) { directories, overwrite in
            Task {
                do {
                    let node = try await model.listedNode(repositoryID: repositoryID, snapshotID: record.id, path: path)
                    model.restore(repositoryID: repositoryID, snapshotID: record.id, node: node, to: directories[0], overwrite: overwrite)
                } catch {
                    model.post(Banner(title: "Could not restore “\(change.name)”", message: error.localizedDescription, isError: true))
                }
            }
        }
    }

    // MARK: - Helpers

    private var visibleCategories: [ResticDiffChange.Category] {
        includeMetadata
            ? ResticDiffChange.Category.allCases
            : ResticDiffChange.Category.allCases.filter { $0 != .metadataOnly }
    }

    /// The change rows the current kind filter and path search admit,
    /// computed off the render path: every keystroke re-renders the sheet,
    /// and the scan costs linearly in the change list (44 ms at the
    /// 20,000-change cap), all on the main actor. Keyed by `RowFilterKey`
    /// it runs once per settled query in a detached task; the cancellation
    /// guard drops a scan whose inputs were replaced mid-flight.
    private func computeRows() async {
        guard diff != nil else {
            filteredRows = nil
            return
        }
        let search = self.search
        let category = filter
        let needle = appliedSearchText
        let rows = await Task.detached(priority: .userInitiated) {
            search.matches(category: category, needle: needle)
        }.value
        guard !Task.isCancelled else { return }
        filteredRows = rows
    }

    /// Files and folders separately, so the tile agrees with the list: restic
    /// counts a new folder as a change but not as a file.
    private func countText(_ counts: ResticDiffStatistics.Counts?) -> String {
        guard let counts else { return "—" }
        let files = Format.plural(counts.files, "file")
        guard counts.dirs > 0 else { return files }
        return "\(files), \(Format.plural(counts.dirs, "folder"))"
    }

    /// One picker row: the displayed minute, plus a relative stamp when
    /// another candidate displays the same minute — the abbreviated time
    /// cannot tell snapshots inside the same minute apart.
    private func comparisonLabel(_ snapshot: Snapshot, sharedMinutes: Set<String>) -> String {
        let when = DiffCandidateGrouping.displayedMinute(snapshot.time)
        let sharesDisplayedMinute = sharedMinutes.contains(when)
        return sharesDisplayedMinute
            ? "\(when) · \(Format.ago(snapshot.time, now: now)) · \(snapshot.shortID)"
            : "\(when) · \(snapshot.shortID)"
    }

    private func glyph(for change: ResticDiffChange) -> String {
        switch change.category {
        case .added: "+"
        case .removed: "−"
        case .modified: change.modifier.contains("T") ? "T" : (change.modifier.contains("?") ? "?" : "M")
        case .metadataOnly: "U"
        }
    }

    /// The glyph carries the meaning; colour only reinforces it.
    private func color(for category: ResticDiffChange.Category) -> Color {
        switch category {
        case .added: StatusPalette.status(.succeeded)
        case .removed: StatusPalette.status(.failed)
        case .modified: StatusPalette.status(.completedWithErrors)
        case .metadataOnly: .secondary
        }
    }

    private func footerText(_ diff: SnapshotDiff, shown: Int) -> String {
        var text = shown == diff.changes.count
            ? Format.plural(diff.changes.count, "change")
            : "\(Format.count(shown)) of \(Format.plural(diff.changes.count, "change"))"
        if diff.isTruncated {
            text += " — list cut off at \(Format.count(SnapshotDiff.changeLimit)); the totals above are complete"
        }
        return text
    }

    /// Installs a load's answer, rebuilding the search index with it — the
    /// index and the diff must never describe different change lists. The
    /// previous diff's rows retire here too: left in place they would render
    /// against the new diff's totals until the fresh pass lands, and a
    /// spinner for those frames is the honest state.
    private func installDiff(_ value: SnapshotDiff?) {
        diff = value
        search = DiffChangeSearch(changes: value?.changes ?? [])
        filteredRows = nil
        diffLoad += 1
    }

    private func load() async {
        guard let olderID, olderID != newer.id else {
            installDiff(nil)
            return
        }
        isLoading = true
        loadError = nil
        do {
            let result = try await model.diffSnapshots(
                repositoryID: target.repositoryID,
                olderID: olderID,
                newerID: newer.id,
                includeMetadata: includeMetadata
            )
            // `.task(id:)` cancels this load when the picker moves on, but the
            // cancelled process still unwinds after the replacement has started;
            // a stale run must not write over the live one.
            guard !Task.isCancelled else { return }
            installDiff(result)
            if filter == .metadataOnly, !includeMetadata { filter = nil }
        } catch is CancellationError {
            return
        } catch ResticError.cancelled {
            return
        } catch {
            guard !Task.isCancelled else { return }
            installDiff(nil)
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
