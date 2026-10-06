import Foundation

/// When a file version's Preview is offered. A preview copies the whole
/// file out of the repository into a temporary folder before Quick Look can
/// show it, so it waits for the version's size — read by the pane's `restic
/// find` — and refuses a file too big to copy only to look at: that one is
/// a restore.
enum VersionPreview {
    static let sizeLimit: Int64 = 1_000_000_000

    /// Why Preview cannot run for a version of this size, as its help; nil
    /// when it can.
    static func unavailableReason(size: Int64?, isReading: Bool) -> String? {
        guard let size else {
            return isReading
                ? "Preview waits for the version's size, still being read"
                : "Preview needs the version's size, which could not be read"
        }
        return size > sizeLimit ? "Too large to preview (\(Format.bytes(size))) — restore it to open it" : nil
    }
}
