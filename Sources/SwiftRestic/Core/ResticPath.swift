/// How restic spells a path in its JSON — the one owner of the directory
/// marker, of the key form without it, and of the last component the
/// snapshot index and its browse cache re-derive from a path.
///
/// `restic diff` ends a directory's path with `/` (`/src/sub/`); `restic
/// ls` never does, and neither lists the root itself (restic 0.19.1, with
/// and without `diff --metadata`). The browser's tree, the Change column's
/// marks, the browse cache and the snapshot index all key a path without
/// the marker, and strip it here rather than each carrying a copy that can
/// drift. Other readers still cut at the last separator their own way —
/// `FindMatch.name`, `SnapshotNode.directory(path:)` and the restore pane's
/// search rows through NSString, `ResticService.parent(of:)` by scalar.
///
/// The rules read UTF-8 bytes — unicode scalars for a cut — never
/// Characters. `/` is one byte that no other scalar's encoding contains, so
/// a byte test sees every separator; a Character test does not, because a
/// grapheme cluster can swallow one. A Prepend character (U+0600 and the
/// rest of its Unicode class) joins the scalar after it, so the directory
/// restic spells `/src/new\u{0600}/` ends in the one Character
/// "\u{0600}/": `hasSuffix("/")` is false, and `dropLast()` would take the
/// U+0600 along with the slash. A combining mark does the same from the
/// other side ("/a/\u{301}x"). Bytes are also what restic means by a path:
/// two names that differ only in Unicode normalization are two paths
/// (`PathKey`).
enum ResticPath {
    /// The separator's one byte.
    static let separator = UInt8(ascii: "/")

    /// The spelling a path is keyed by: every trailing `/` stripped, except
    /// that the root stays "/" (and "" stays ""). A path with no trailing
    /// `/` — every `ls` path, every file in a diff — comes back as it is.
    static func normalized(_ path: String) -> String {
        guard path.utf8.count > 1, path.utf8.last == separator else { return path }
        return String(decoding: normalizedBytes(path), as: UTF8.self)
    }

    /// `normalized` as bytes, for a caller that keys by bytes — the index's
    /// full-listing ingest — so the key is not decoded into a String only to
    /// be encoded again.
    static func normalizedBytes(_ path: String) -> [UInt8] {
        var bytes = Array(path.utf8)
        while bytes.count > 1, bytes.last == separator { bytes.removeLast() }
        return bytes
    }

    /// Whether restic's spelling marks a directory: its last byte is `/`.
    /// The root "/" is one too, though restic never lists it.
    static func isDirectorySpelling(_ path: String) -> Bool {
        path.utf8.last == separator
    }

    /// The last component: what follows the last separator ("" for the
    /// root), or the whole path when there is none. Cut in the scalar view,
    /// for the reason above, and because a String subscript would re-align
    /// the cut to a grapheme boundary and round it into the cluster.
    static func basename(of path: String) -> String {
        guard let last = path.unicodeScalars.lastIndex(of: "/") else { return path }
        return String(path.unicodeScalars[last...].dropFirst())
    }

    /// What precedes the last separator: "/" for a child of the root, the
    /// path itself when it has no separator. Cut in the scalar view, as
    /// `basename` is.
    static func parent(of path: String) -> String {
        guard let last = path.unicodeScalars.lastIndex(of: "/") else { return path }
        return last == path.unicodeScalars.startIndex ? "/" : String(path.unicodeScalars[..<last])
    }
}
