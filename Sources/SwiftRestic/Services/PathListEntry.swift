import Foundation

/// What a path list in the plan editor stores for one entry. Typed text is
/// taken as typed — an exclude is a restic pattern — but an item browsed or
/// dropped from Finder is that item and nothing else, so as an exclude its
/// glob characters are escaped (`ResticService.globEscaped`): "a[1].txt"
/// would otherwise match "a1.txt" and not itself.
enum PathListEntry {
    /// Nil for blank input. Trimmed first: a pasted " ~/Documents" does
    /// not start with `~`, so expanding before trimming would leave the
    /// tilde literal — and restic, seeing no shell, would stat a path that
    /// cannot exist.
    static func value(for raw: String, expandsTildeInPath: Bool, escapesGlobs: Bool) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let path = expandsTildeInPath ? (trimmed as NSString).expandingTildeInPath : trimmed
        return escapesGlobs ? ResticService.globEscaped(path) : path
    }
}
