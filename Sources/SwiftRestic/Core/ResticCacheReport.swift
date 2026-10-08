import Foundation

/// What `restic cache` reports about restic's local cache: one directory per
/// repository restic has opened on this Mac, kept after the repository is
/// removed here and never cleaned by restic on its own — once a directory
/// has gone unused for 30 days restic only prints, at the start of a
/// command, that `restic cache --cleanup` would remove it. The command has
/// no JSON form (restic 0.19.1): it prints a table — "Repo ID / Last Used /
/// Old / Size", a row per directory, "N days ago" always in days, "yes" in
/// Old past `--max-age` days, the size in restic's binary units — and a
/// last line "N cache dirs in <directory>".
struct ResticCacheReport: Equatable, Sendable {
    /// The directory restic names: ~/Library/Caches/restic unless
    /// RESTIC_CACHE_DIR or XDG_CACHE_HOME moved it.
    var directory: String
    var count: Int
    /// Directories restic marks old: unused for `oldAfterDays` days, the
    /// ones `--cleanup` removes.
    var oldCount: Int
    /// The rows' sizes summed as restic prints them (three decimals of a
    /// binary unit): file sizes, where Finder and `du` count allocated
    /// blocks — thousands of small cache files read a third larger there.
    var totalBytes: Int64

    /// `--max-age`'s default: the age past which `--cleanup` removes a
    /// directory.
    static let oldAfterDays = 30

    static func parse(_ output: String) -> ResticCacheReport? {
        var directory: String?
        var count = 0
        var oldCount = 0
        var totalBytes: Int64 = 0
        for line in output.split(separator: "\n") {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // "10982 cache dirs in /Users/me/Library/Caches/restic" — the
            // directory may hold spaces, so it is the rest of the line.
            if tokens.count >= 5, let n = Int(tokens[0]), tokens[1] == "cache",
               tokens[2] == "dirs" || tokens[2] == "dir", tokens[3] == "in"
            {
                count = n
                directory = tokens.dropFirst(4).joined(separator: " ")
                continue
            }
            // A row: "<id>  <n> days ago  [yes]  [<size> <unit>]". The header
            // and the dashed rules carry no "ago".
            guard let ago = tokens.firstIndex(of: "ago"), ago == 3 else { continue }
            var rest = tokens[(ago + 1)...]
            if rest.first == "yes" {
                oldCount += 1
                rest = rest.dropFirst()
            }
            if rest.count == 2, let bytes = bytes(value: rest[rest.startIndex], unit: rest[rest.startIndex + 1]) {
                totalBytes += bytes
            }
        }
        guard let directory else { return nil }
        return ResticCacheReport(directory: directory, count: count, oldCount: oldCount, totalBytes: totalBytes)
    }

    /// restic's own units (ui.FormatBytes): "2.737 MiB" → bytes.
    static func bytes(value: String, unit: String) -> Int64? {
        guard let number = Double(value) else { return nil }
        let scale: Double
        switch unit {
        case "B": scale = 1
        case "KiB": scale = 1024
        case "MiB": scale = 1024 * 1024
        case "GiB": scale = 1024 * 1024 * 1024
        case "TiB": scale = 1024 * 1024 * 1024 * 1024
        default: return nil
        }
        return Int64((number * scale).rounded())
    }
}
