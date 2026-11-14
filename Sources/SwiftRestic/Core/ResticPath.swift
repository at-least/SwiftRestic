/// How restic spells a path in its JSON. `restic diff` ends a directory's
/// path with `/` (`/src/sub/`); `restic ls` never does, and neither lists
/// the root. Every path key is without the marker.
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
    private static let separator = UInt8(ascii: "/")

    /// Every trailing `/` stripped; the root stays "/" and "" stays "".
    static func normalized(_ path: String) -> String {
        guard path.utf8.count > 1, path.utf8.last == separator else { return path }
        return String(decoding: normalizedBytes(path), as: UTF8.self)
    }

    /// For the index's ingest, which keys by bytes.
    static func normalizedBytes(_ path: String) -> [UInt8] {
        var bytes = Array(path.utf8)
        while bytes.count > 1, bytes.last == separator { bytes.removeLast() }
        return bytes
    }

    static func isDirectorySpelling(_ path: String) -> Bool {
        path.utf8.last == separator
    }

    /// "" for the root; the whole path when it has no separator. A String
    /// subscript would round the cut to a grapheme boundary, so it is cut in
    /// the scalar view.
    static func basename(of path: String) -> String {
        guard let last = path.unicodeScalars.lastIndex(of: "/") else { return path }
        return String(path.unicodeScalars[last...].dropFirst())
    }

    /// "/" for a child of the root; the path itself when it has no
    /// separator.
    static func parent(of path: String) -> String {
        guard let last = path.unicodeScalars.lastIndex(of: "/") else { return path }
        return last == path.unicodeScalars.startIndex ? "/" : String(path.unicodeScalars[..<last])
    }

    /// "/a/b/c" → ["/a/b", "/a", "/"]; none for the root or a bare name.
    static func ancestors(of path: String) -> [String] {
        var ancestors: [String] = []
        var current = path
        while current != "/", current.unicodeScalars.contains("/") {
            current = parent(of: current)
            ancestors.append(current)
        }
        return ancestors
    }

    /// `path` is `folder` or inside it, byte for byte, as the index compares
    /// paths: "/Data2" is not inside "/Data".
    static func holds(_ folder: String, _ path: String) -> Bool {
        if path.utf8.elementsEqual(folder.utf8) { return true }
        return path.utf8.starts(with: insidePrefix(of: folder).utf8)
    }

    static func insidePrefix(of folder: String) -> String {
        folder == "/" ? "/" : folder + "/"
    }
}

/// For a restic line that carries a path: the Character forms join a
/// Prepend character ending the path to the
/// ": " or " " after it (`ResticPath`'s header), so "x\u{0600}: open …"
/// has the Character prefix "x\u{0600}: " but one Character fewer than
/// `count` says, and "x\u{0600} does not exist, skipping" has no Character
/// suffix " does not exist, skipping" at all.
extension String {
    func hasByteSuffix(_ suffix: String) -> Bool {
        utf8.count >= suffix.utf8.count && utf8.suffix(suffix.utf8.count).elementsEqual(suffix.utf8)
    }

    /// One call, so the test and the cut cannot disagree.
    func removingBytePrefix(_ prefix: String) -> String? {
        guard utf8.starts(with: prefix.utf8) else { return nil }
        return String(decoding: utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
    }

    func removingByteSuffix(_ suffix: String) -> String? {
        guard hasByteSuffix(suffix) else { return nil }
        return String(decoding: utf8.dropLast(suffix.utf8.count), as: UTF8.self)
    }
}
