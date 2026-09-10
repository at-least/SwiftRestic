import Foundation

/// One remote configured in the user's rclone installation.
struct RcloneRemote: Sendable, Hashable {
    /// The name as it appears in `rclone listremotes` — without the trailing colon.
    var name: String
    /// The backend type (`drive`, `sftp`, …), empty when the lister fell back to
    /// plain `listremotes` output, which names remotes only.
    var type: String

    var menuTitle: String { type.isEmpty ? name : "\(name) — \(type)" }
}

/// Lists the remotes configured in the user's rclone installation.
///
/// Asks `rclone listremotes -l` instead of reading the config file: the file's
/// location is rclone's business (XDG directories, `--config`, `RCLONE_CONFIG`
/// all move it), and parsing it would drag rclone's obscured secrets past the
/// app. The binary answers with authoritative names and types and never prints
/// secrets.
struct RcloneRemoteLister: Sendable {
    var runner: ResticRunner

    /// Empty on any failure — a missing or misbehaving rclone degrades the
    /// editor to a plain text field, never to an error the user must dismiss.
    func list(binary: URL) async -> [RcloneRemote] {
        guard let result = try? await runner.run(
            binary: binary,
            invocation: ResticInvocation(
                arguments: ["listremotes", "-l"],
                // rclone reads its config up front, but a backend that dials out
                // on startup must not pin the editor open.
                timeout: 5,
                retainMessages: false
            )
        ) else { return [] }
        return Self.parse(result.stdout)
    }

    /// `-l` prints one `name: type` per line; plain `listremotes` names only.
    /// Both split at the first colon — remote names may not contain colons,
    /// which is exactly what makes `remote:path` unambiguous. Lines split on
    /// any newline character: Swift reads `\r\n` as one grapheme, so a literal
    /// `"\n"` split would leave the `\r` glued to the previous line.
    static func parse(_ output: String) -> [RcloneRemote] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let type = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return RcloneRemote(name: name, type: type)
        }
    }
}
