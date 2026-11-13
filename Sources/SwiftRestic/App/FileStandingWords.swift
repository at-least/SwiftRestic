import Foundation

/// The versions pane's words for a picked file's standing.
enum FileStandingWords {
    /// Why an item on this Mac is not backed up: the newest backup's own
    /// run could not read it (`UnreadItems.reason`), or no backup of the
    /// plan holds it — the pane's words under its "Not backed up", which
    /// add the sentence's period.
    static func notBackedUpReason(notRead: String?) -> String {
        notRead.map { "The newest backup couldn’t read it (\($0))" } ?? "No backup of this plan holds it"
    }

    /// For an item on this Mac the chain's newest backup lacks, though an
    /// older one holds it: when it was last backed up, and why the newest
    /// lacks it when its own run could not read it (`UnreadItems.reason`).
    static func standing(notRead: String?, lastBackedUp: Date) -> String {
        let when = "last backed up \(Format.timestamp(lastBackedUp))"
        return notRead.map { "Not read by the newest backup (\($0)) — \(when)" } ?? "Not in the newest backup — \(when)"
    }
}

/// The index's words while it can still be missing matches or versions,
/// and a capped search's.
enum IndexWords {
    /// While it has backups still to read — the versions pane's banner.
    static let stillReading = "Still reading backups. Older ones may be missing."
    /// A capped search, in Search All Backups' footer: no count, since the
    /// page may list only a subset of what the cap counted, and not "the
    /// first", since the page re-sorts what the index cut in its own order.
    static let searchTruncated = "Not every match is shown — narrow the search to see the rest."
}
