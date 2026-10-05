import Foundation

/// What a file's version row in a Files pane says of how it follows the
/// version below it: how its size moved — the magnitude of the change, the
/// one thing a list of versions cannot show by itself — or, where nothing
/// proves the two differ, that they may be the same content.
///
/// Every version above the oldest begins where the index cut the file's
/// history, so "it changed" is what the list already is; the row says it
/// only where it is in doubt. A cut no diff made (`ContentVersion.Since
/// .uncertain`) stays visible, never merged: different sizes settle it,
/// equal or unknown ones leave it "may be identical".
enum FileVersionChange: Equatable {
    /// The oldest version, or sizes still being read: nothing to say yet.
    case none
    /// The size change from the version below, "+17 bytes" or "Same size".
    case size(String)
    /// No diff compared the two, and nothing read since tells them apart.
    case mayBeIdentical

    /// The row's change, from the index's mark and the two versions' sizes
    /// as the find read them — nil while unknown — and whether that find
    /// is still running.
    static func between(
        since: ContentVersion.Since?,
        newerSize: Int64?,
        olderSize: Int64?,
        isReading: Bool
    ) -> FileVersionChange {
        guard let since else { return .none }
        guard let newerSize, let olderSize else {
            // Not read yet, or the read failed: a diff's cut needs no size
            // to stand; a doubtful one shows its doubt once no answer is
            // coming, never flashing up while the find runs.
            return since == .uncertain && !isReading ? .mayBeIdentical : .none
        }
        if since == .uncertain, newerSize == olderSize { return .mayBeIdentical }
        return .size(Format.sizeChange(from: olderSize, to: newerSize))
    }
}
