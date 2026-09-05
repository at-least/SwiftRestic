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
struct SnapshotDiffView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let target: SnapshotDiffTarget

    @State private var olderID: String?
    @State private var includeMetadata = false
    @State private var diff: SnapshotDiff?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var filter: ResticDiffChange.Category?
    @State private var searchText = ""

    private var newer: Snapshot { target.snapshot }

    /// Every snapshot older than the one being examined, newest first.
    private var candidates: [Snapshot] {
        model.snapshots(for: target.repositoryID)
            .filter { $0.time < newer.time }
            .sorted { $0.time > $1.time }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 500)
        .onAppear {
            if olderID == nil {
                olderID = newer.previousComparable(in: model.snapshots(for: target.repositoryID))?.id
                    ?? candidates.first?.id
            }
        }
        .task(id: "\(olderID ?? "")|\(includeMetadata)") { await load() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Changes in snapshot \(newer.shortID)")
                        .font(.headline)
                    Text(newer.time.formatted(date: .abbreviated, time: .shortened))
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
                    ForEach(candidates) { snapshot in
                        Text(comparisonLabel(snapshot)).tag(String?.some(snapshot.id))
                    }
                }
                .frame(maxWidth: 420)
                .disabled(candidates.isEmpty)

                if let older = candidates.first(where: { $0.id == olderID }),
                   older.paths != newer.paths || older.hostname != newer.hostname {
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
    private var content: some View {
        if candidates.isEmpty {
            ContentUnavailableView(
                "Nothing to compare against",
                systemImage: "clock.arrow.circlepath",
                description: Text("This is the oldest snapshot in the repository.")
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
                changeList(diff)
            }
        } else {
            Color.clear
        }
    }

    private func statistics(_ diff: SnapshotDiff) -> some View {
        let stats = diff.statistics
        return HStack(spacing: 10) {
            StatTile(
                title: "Added",
                value: countText(stats?.added),
                systemImage: "plus.circle"
            )
            StatTile(
                title: "Removed",
                value: countText(stats?.removed),
                systemImage: "minus.circle"
            )
            // restic's `changed_files` counts content changes only; the Modified
            // filter also includes type changes and bitrot, so the tooltip names
            // it precisely while the tile stays short enough not to truncate.
            StatTile(
                title: "Changed",
                value: Format.count(stats?.changedFiles),
                systemImage: "pencil.circle",
                help: "Files whose content changed — metadata-only edits are listed under Show › Metadata"
            )
            StatTile(
                title: "Data added",
                value: Format.bytes(stats?.added.bytes),
                systemImage: "arrow.down.to.line"
            )
            StatTile(
                title: "Data removed",
                value: Format.bytes(stats?.removed.bytes),
                systemImage: "arrow.up.to.line"
            )
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
    private func changeList(_ diff: SnapshotDiff) -> some View {
        let rows = filteredChanges(diff)
        if diff.changes.isEmpty {
            ContentUnavailableView(
                "No differences",
                systemImage: "equal.circle",
                description: Text("The two snapshots contain the same files.")
            )
        } else if rows.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List(rows) { change in
                HStack(spacing: 8) {
                    Text(glyph(for: change))
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(color(for: change.category))
                        .frame(width: 22, alignment: .center)
                        .help(change.explanation)
                    Image(systemName: change.isDirectory ? "folder" : "doc")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
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
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack {
            if let diff {
                Text(footerText(diff))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    // MARK: - Helpers

    private var visibleCategories: [ResticDiffChange.Category] {
        includeMetadata
            ? ResticDiffChange.Category.allCases
            : ResticDiffChange.Category.allCases.filter { $0 != .metadataOnly }
    }

    private func filteredChanges(_ diff: SnapshotDiff) -> [ResticDiffChange] {
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        return diff.changes.filter { change in
            if let filter, change.category != filter { return false }
            if !needle.isEmpty, change.path.range(of: needle, options: .caseInsensitive) == nil {
                return false
            }
            return true
        }
    }

    /// Files and folders separately, so the tile agrees with the list: restic
    /// counts a new folder as a change but not as a file.
    private func countText(_ counts: ResticDiffStatistics.Counts?) -> String {
        guard let counts else { return "—" }
        let files = "\(Format.count(counts.files)) file\(counts.files == 1 ? "" : "s")"
        guard counts.dirs > 0 else { return files }
        return "\(files), \(Format.count(counts.dirs)) folder\(counts.dirs == 1 ? "" : "s")"
    }

    private func comparisonLabel(_ snapshot: Snapshot) -> String {
        let when = snapshot.time.formatted(date: .abbreviated, time: .shortened)
        return "\(when) · \(snapshot.shortID)"
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
        case .added: ChartPalette.status(.succeeded)
        case .removed: ChartPalette.status(.failed)
        case .modified: ChartPalette.status(.completedWithErrors)
        case .metadataOnly: .secondary
        }
    }

    private func footerText(_ diff: SnapshotDiff) -> String {
        let shown = filteredChanges(diff).count
        var text = shown == diff.changes.count
            ? "\(Format.count(diff.changes.count)) change(s)"
            : "\(Format.count(shown)) of \(Format.count(diff.changes.count)) change(s)"
        if diff.isTruncated {
            text += " — list cut off at \(Format.count(SnapshotDiff.changeLimit)); the totals above are complete"
        }
        return text
    }

    private func load() async {
        guard let olderID, olderID != newer.id else {
            diff = nil
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
            diff = result
            loadError = nil
            if filter == .metadataOnly, !includeMetadata { filter = nil }
        } catch is CancellationError {
            return
        } catch ResticError.cancelled {
            return
        } catch {
            guard !Task.isCancelled else { return }
            diff = nil
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
