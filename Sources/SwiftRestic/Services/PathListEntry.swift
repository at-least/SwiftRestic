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

    /// The list after a keystroke in row `index`'s in-place edit: written
    /// at once, so Save mid-edit saves what the field shows (Save takes no
    /// focus, so it never ends the edit). Taken as a pattern and never
    /// escaped: a picked item's escapes are already in the text. While the
    /// text is blank or another row's value, the row holds `original`, its
    /// value before the edit.
    static func typing(_ raw: String, at index: Int, original: String, in paths: [String]) -> [String] {
        var edited = paths
        if let value = value(for: raw, expandsTildeInPath: false, escapesGlobs: false),
           !holdsElsewhere(value, index, paths) {
            edited[index] = value
        } else {
            edited[index] = original
        }
        return edited
    }

    /// The list when the in-place edit ends on `raw`: a value another row
    /// already holds drops the edited row rather than listing it twice.
    /// Anything else `typing` already wrote.
    static func finishing(_ raw: String, at index: Int, in paths: [String]) -> [String] {
        guard let value = value(for: raw, expandsTildeInPath: false, escapesGlobs: false),
              holdsElsewhere(value, index, paths)
        else { return paths }
        var edited = paths
        edited.remove(at: index)
        return edited
    }

    private static func holdsElsewhere(_ value: String, _ index: Int, _ paths: [String]) -> Bool {
        paths.enumerated().contains { $0.offset != index && $0.element == value }
    }
}
