import SwiftUI

/// A plan's search on its Backups tab, in the backup's tree's place while
/// the toolbar's field holds a query: the plan's items named like it, from
/// the index — items no longer on this Mac included, dimmed — and a hit
/// selects as a file in the tree does, so its versions open under it.
/// Return or Esc ends the search on the selected hit, in the backup that
/// holds it.
struct FilesSearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(DiskWatch.self) private var diskWatch
    let roots: FileNode
    /// The plan's page, which Search All Backups comes back to.
    let page: SidebarItem
    /// The backup the tab has open, which a hit still on this Mac ends the
    /// search in.
    let openBackup: Snapshot

    @FocusState private var hitsAreFocused: Bool
    /// The latest answer to a search of this view, with the search it
    /// answers: one typed on another page, or before the last change to the
    /// query, is never shown for this one.
    @State private var searchAnswer: FilesSearchAnswer?

    private var selection: Binding<FileNode?> {
        Binding(get: { router.filesSelection[roots] }, set: { router.filesSelection[roots] = $0 })
    }

    private var query: String {
        router.filesSearchQuery(for: roots)
    }

    /// The folders a hit's caption is read from: the open backup's top
    /// folders (`FilesSearchAnswer.folderLine`).
    private var tops: [FileNode] {
        openBackup.paths.map { FileNode(repositoryID: roots.repositoryID, chainKey: roots.chainKey, path: $0, isDirectory: true) }
    }

    var body: some View {
        hits
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The search, asked again under each listing, each one the index
            // takes and each turn of the disk.
            .task(id: FilesSearchKey(
                roots: roots,
                query: query,
                listedAt: model.snapshotsLoadedAt(for: roots.repositoryID),
                indexTaken: model.indexTakenGeneration[roots.repositoryID],
                diskGeneration: diskWatch.diskGeneration
            )) {
                await search()
            }
    }

    @ViewBuilder
    private var hits: some View {
        if let answer = searchAnswer, answer.roots == roots, answer.query == query {
            switch answer.outcome {
            case let .failed(message):
                // A broken index is its own answer: never a "no matches".
                IndexFailureView(title: "Search failed", message: message, repositoryID: roots.repositoryID)
            case let .hits(entries) where entries.isEmpty:
                VStack(spacing: 0) {
                    scopeBar
                    Divider()
                    // No Search All Backups here: the scope bar above is it.
                    ContentUnavailableView {
                        Label("No matches", systemImage: "magnifyingglass")
                    } description: {
                        Text(answer.isComplete
                            ? "Nothing in this plan’s backups matches. Each word you type matches the start of a word in a name."
                            : FilesSearchAnswer.searchStillReading)
                    }
                    .frame(maxHeight: .infinity)
                }
            case let .hits(entries):
                VStack(spacing: 0) {
                    scopeBar
                    Divider()
                    List(selection: selection) {
                        ForEach(entries) { entry in
                            FilesSearchRow(entry: entry, folder: FilesSearchAnswer.folderLine(for: entry.node.path, under: tops))
                                .tag(entry.node)
                                .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.inset)
                    .accessibilityIdentifier(AccessibilityID.FilesSearch.results)
                    .focusOnClick($hitsAreFocused)
                    .onKeyPress(.return, phases: .down) { endSearch($0, entries: entries) }
                    .onKeyPress(.escape, phases: .down) { endSearch($0, entries: entries) }
                    .help("Return or Esc ends the search and shows the selected item in its backup")
                    if let note = FilesSearchAnswer.note(isTruncated: answer.isTruncated, isComplete: answer.isComplete) {
                        Divider()
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Return or Esc in the hits: the search ends on the selected hit, in
    /// the open backup while this Mac still has it, else in the last backup
    /// that held it — the tree opens its folders to it.
    private func endSearch(_ press: KeyPress, entries: [FileEntry]) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .option, .control, .shift]) else { return .ignored }
        router.filesSearchText[roots] = nil
        if let hit = entries.first(where: { $0.node == router.filesSelection[roots] }) {
            let backupID = switch hit.standing {
            case .onDisk: openBackup.id
            case let .deleted(lastBackedUp): lastBackedUp.id
            }
            router.showBackup(backupID, on: page, repositoryID: roots.repositoryID, focusPath: hit.node.path)
        }
        return .handled
    }

    /// This Plan | All Backups, over a search's hits.
    private var scopeBar: some View {
        SearchScopePicker(scope: .thisPlan, onChange: searchAllBackups)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }

    private func searchAllBackups() {
        router.openFind(query: query, from: AppRouter.FindOrigin(page: page, roots: roots))
    }

    /// Answers the query, and again every `recheckInterval` while the index
    /// is still reading the repository, so hits from backups it reads
    /// meanwhile fill in. One read of the index, no restic, then one listing
    /// per hit's folder (`DiskFolder.present`): a hit no longer on this
    /// Mac is dimmed.
    private func search() async {
        let roots = roots
        let query = query
        guard !query.isEmpty else { return }
        while !Task.isCancelled {
            // Asked before the search: a backup once read stays read, so an
            // index complete beforehand has read every backup the hits come
            // from.
            var complete = false
            let outcome: FilesSearchAnswer.Outcome
            var isTruncated = false
            do {
                complete = try await model.indexIsComplete(repositoryID: roots.repositoryID)
                let found = try await model.searchIndex(
                    pattern: query, inChain: roots.chainKey, repositoryID: roots.repositoryID
                )
                let paths = found.hits.map(\.path)
                let present = await Task.detached(priority: .userInitiated) { DiskFolder.present(paths) }.value
                outcome = .hits(FilesSearchAnswer.entries(found.hits, under: roots, present: present))
                isTruncated = found.isTruncated
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
            searchAnswer = FilesSearchAnswer(
                roots: roots, query: query, outcome: outcome, isComplete: complete, isTruncated: isTruncated
            )
            guard !complete, case .hits = outcome else { return }
            do {
                try await Task.sleep(for: DiskWatch.recheckInterval)
            } catch {
                return
            }
        }
    }
}

/// What a plan's search is keyed by: the chain, the query, the listing it
/// is read under and the one the index has taken, and the disk's turn — so
/// a refresh asks again, and a hit deleted meanwhile dims.
private struct FilesSearchKey: Equatable {
    let roots: FileNode
    let query: String
    let listedAt: Date?
    let indexTaken: UInt64?
    let diskGeneration: UInt64
}

/// One hit of a plan's search: the kind's icon and the name, over the
/// folder that holds it. An item no longer on this Mac is dimmed, with the
/// day it was last backed up.
private struct FilesSearchRow: View {
    let entry: FileEntry
    let folder: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            FileKindIcon(type: .backedUp(name: entry.node.name, isDirectory: entry.node.isDirectory))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(folder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let tag = entry.tag {
                Text(tag)
                    .font(.caption)
                    .accessibilityLabel(entry.spokenStanding ?? tag)
            }
        }
        .foregroundStyle(entry.standing == .onDisk ? .primary : .secondary)
        .help(entry.help)
        .accessibilityElement(children: .combine)
    }
}
