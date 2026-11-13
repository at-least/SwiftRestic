import Foundation

/// An item of a chain's backups and its standing, on this Mac or gone
/// from it, as a search's hits show it.
struct FileEntry: Hashable, Identifiable {
    let node: FileNode
    let standing: Standing

    var id: FileNode { node }

    enum Standing: Hashable {
        /// On this Mac.
        case onDisk
        /// Not on this Mac: only the backups hold it, the newest of them
        /// `lastBackedUp`.
        case deleted(lastBackedUp: IndexVersion)
    }
}

extension FileEntry {
    var help: String {
        switch standing {
        case .onDisk: node.path
        case let .deleted(lastBackedUp): Self.deleted(lastBackedUp: lastBackedUp.time)
        }
    }

    var spokenStanding: String? {
        switch standing {
        case .onDisk: nil
        case let .deleted(lastBackedUp): "not on this Mac, last backed up \(Format.timestamp(lastBackedUp.time))"
        }
    }

    var tag: String? {
        switch standing {
        case .onDisk: nil
        case let .deleted(lastBackedUp): Format.until(lastBackedUp.time)
        }
    }

    /// Why an item on this Mac is not backed up: the newest backup's own
    /// run could not read it (`UnreadItems.reason`), or no backup of the
    /// plan holds it — the pane's words under its "Not backed up", which
    /// add the sentence's period.
    static func notBackedUpReason(notRead: String?) -> String {
        notRead.map { "The newest backup couldn’t read it (\($0))" } ?? "No backup of this plan holds it"
    }

    static func deleted(lastBackedUp: Date) -> String {
        "Not on this Mac — last backed up \(Format.timestamp(lastBackedUp))"
    }

    /// For an item on this Mac the chain's newest backup lacks, though an
    /// older one holds it: when it was last backed up, and why the newest
    /// lacks it when its own run could not read it (`UnreadItems.reason`) —
    /// the file pane's line.
    static func standing(notRead: String?, lastBackedUp: Date) -> String {
        let when = "last backed up \(Format.timestamp(lastBackedUp))"
        return notRead.map { "Not read by the newest backup (\($0)) — \(when)" } ?? "Not in the newest backup — \(when)"
    }
}

struct FilesSearchAnswer: Equatable {
    enum Outcome: Equatable {
        case hits([FileEntry])
        case failed(String)
    }

    let roots: FileNode
    let query: String
    let outcome: Outcome
    /// Whether the index had read every backup of the repository when it
    /// answered: until then older backups' items may be missing.
    let isComplete: Bool
    let isTruncated: Bool

    /// The index's words while it has backups still to read — the Backups
    /// tab's browsing banner says them.
    static let indexStillReading = "Still reading backups. Older ones may be missing."

    /// The index's words while it can still be missing matches — every
    /// search answer that may be short says them: a plan search's empty state
    /// and its footer.
    static let searchStillReading = "Still reading backups. Some matches may be missing."
    /// A capped search, in every search's footer: no count, since a pane
    /// may list only a subset of what the cap counted, and not "the first",
    /// since each list re-sorts what the index cut in its own order.
    static let searchTruncated = "Not every match is shown — narrow the search to see the rest."

    /// The index's hits as the column lists them — each on this Mac or
    /// deleted by `present`, the paths found on the disk: by name as Finder
    /// sorts names, one name's hits by path — the tree's rows, with no
    /// folders first, since a hit's folder is its caption.
    static func entries(_ hits: [IndexChild], under roots: FileNode, present: Set<PathKey>) -> [FileEntry] {
        hits.map { hit in
            FileEntry(
                node: FileNode(
                    repositoryID: roots.repositoryID, chainKey: roots.chainKey,
                    path: hit.path, isDirectory: hit.isDirectory
                ),
                standing: present.contains(PathKey(hit.path)) ? .onDisk : .deleted(lastBackedUp: hit.newest)
            )
        }
        .sorted { lhs, rhs in
                switch lhs.node.name.localizedStandardCompare(rhs.node.name) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: SnapshotIndex.bytesLess(lhs.node.path, rhs.node.path)
                }
            }
    }

    @MainActor static func note(isTruncated: Bool, isComplete: Bool) -> String? {
        if isTruncated { return searchTruncated }
        return isComplete ? nil : searchStillReading
    }

    /// A hit's second line: the folder holding it, read from the folder
    /// that holds the plan's root down — /Users/me/Documents/reports under
    /// a plan of /Users/me/Documents reads "Documents/reports" — so the
    /// prefix every hit shares cannot eat the part that tells them apart.
    /// A hit outside every root keeps the tilde-abbreviated path.
    static func folderLine(for path: String, under roots: [FileNode]) -> String {
        let parent = ResticPath.parent(of: path)
        let base = Format.containingRoot(of: parent, in: roots.map(\.path)).map { ResticPath.parent(of: $0) }
        guard let base, parent != base else {
            return (parent as NSString).abbreviatingWithTildeInPath
        }
        // `holds` passed and `parent` is not `base`: it is inside it.
        return ResticPath.relative(parent, below: base)!
    }
}
