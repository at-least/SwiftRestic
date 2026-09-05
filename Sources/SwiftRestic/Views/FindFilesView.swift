import SwiftUI

/// Searches every snapshot for a file, and restores what it finds.
///
/// This is the "I deleted something months ago and don't know which backup has
/// it" case, which browsing snapshot by snapshot does not solve.
struct FindFilesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var repositoryID: UUID?
    @State private var pattern = ""
    @State private var latestOnly = false
    @State private var results: [FindResult] = []
    @State private var selection: String?
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var hasSearched = false
    @State private var searchTask: Task<Void, Never>?

    private struct Row: Identifiable {
        var id: String { "\(snapshotID)/\(match.path)" }
        var match: FindMatch
        var snapshotID: String
        var snapshotTime: Date?
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
        }
        .onDisappear { searchTask?.cancel() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    prompt: Text(verbatim: "File name or pattern, e.g. *.key or invoice*")
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit(search)
                Toggle("Latest snapshot only", isOn: $latestOnly)
                    .toggleStyle(.checkbox)
                Button("Search", action: search)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSearch)
                if isSearching {
                    Button("Stop") { cancelSearch() }
                    ProgressView().controlSize(.small)
                }
            }

            Text("Matching is case-insensitive and supports shell globs. Searching every snapshot walks each one, so it takes longer the more history a repository holds.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

                TableColumn("Size") { row in
                    Text(row.match.isDirectory ? "—" : Format.bytes(row.match.size))
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 84)
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
            HStack {
                if !rows.isEmpty {
                    Text("\(rows.count) match(es) across \(results.count) snapshot(s)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                Button("Restore Selected…") { restoreSelection() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedRow == nil || model.isRestoring)
            }
        }
        .padding(12)
    }

    // MARK: - Data

    private var rows: [Row] {
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
            do {
                let found = try await model.findFiles(
                    repositoryID: searchedRepository,
                    pattern: searchedPattern,
                    latestOnly: searchedLatestOnly
                )
                guard !Task.isCancelled else { return }
                results = found
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                errorMessage = error.localizedDescription
            }
            hasSearched = true
            isSearching = false
            searchTask = nil
        }
    }

    /// Abandons the running search, if any. The view state is reset here rather
    /// than in the task: the cancelled task must not touch what a newer search
    /// or a different repository now owns.
    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        results = []
        hasSearched = false
        errorMessage = nil
        selection = nil
    }

    private func restoreSelection() {
        guard let row = selectedRow, let repositoryID else { return }
        guard let destination = FilePicker.chooseDirectory(
            message: "Choose where to restore “\(row.match.name)”",
            prompt: "Restore"
        ) else { return }
        model.restore(
            repositoryID: repositoryID,
            snapshotID: row.snapshotID,
            node: row.match.node,
            to: destination
        )
    }
}
