import Foundation

/// One remote configured in the user's rclone installation.
struct RcloneRemote: Sendable, Hashable {
    /// The name as it appears in `rclone listremotes` — without the trailing colon.
    var name: String
    /// The backend type (`drive`, `sftp`, …), empty when a line carries a
    /// colon but nothing after it.
    var type: String

    var menuTitle: String { type.isEmpty ? name : "\(name) — \(type)" }
}

/// What the repository editor offers for a new rclone repository's Remote:
/// only remotes rclone already has, so setting one up stays rclone's job.
enum RcloneSetup: Equatable {
    case notInstalled
    case unreadable(String)
    case remotes([RcloneRemote])

    static let passwordProtected = "rclone’s configuration is password-protected, and SwiftRestic can’t unlock it. "
        + "To use rclone here, remove the password in Terminal with rclone config."
    static let noRemotes = "No rclone remotes yet. Set one up in Terminal with rclone config, then come back here."
}

/// Lists the remotes configured in the user's rclone installation.
///
/// Asks `rclone listremotes --long` instead of reading the config file: the file's
/// location is rclone's business (XDG directories, `--config`, `RCLONE_CONFIG`
/// all move it), and parsing it would drag rclone's obscured secrets past the
/// app. The binary answers with authoritative names and types and never prints
/// secrets.
struct RcloneRemoteLister: Sendable {
    var runner: ResticRunner

    /// `--long`, not `-l`: that is rclone's global `--links`, and with it
    /// listremotes printed names alone on every rclone tried, 1.50.2 to
    /// 1.75.2.
    static let arguments = ["listremotes", "--long"]

    func list(binary: URL) async -> RcloneSetup {
        let result: ResticRunResult
        do {
            result = try await runner.run(
                binary: binary,
                invocation: ResticInvocation(
                    arguments: Self.arguments,
                    allowedExitCodes: nil,
                    // rclone reads its config up front, but a backend that dials out
                    // on startup must not pin the editor open.
                    timeout: 5,
                    retainMessages: false
                )
            )
        } catch {
            return .unreadable("rclone could not list its remotes: \(error.localizedDescription)")
        }
        guard result.exitCode == 0 else {
            // An encrypted config asks for its password on the terminal, and
            // the runner gives rclone none: 1.75.2 prompts on stderr, then says only "Failed to
            // read line: EOF".
            if result.stderr.contains("Enter configuration password") {
                return .unreadable(RcloneSetup.passwordProtected)
            }
            guard let lastLine = result.stderr.split(whereSeparator: \.isNewline).last else {
                return .unreadable("rclone could not list its remotes.")
            }
            let words = ResticRunResult.rcloneErrorWords(lastLine) ?? lastLine
            return .unreadable("rclone could not list its remotes: \(words)")
        }
        return .remotes(Self.parse(result.stdout))
    }

    /// `--long` prints one `name: type` per line — rclone 1.75.2 adds the
    /// remote's description after the type, 1.50.2 does not — so the type
    /// is the first word after the colon; a line without a colon is
    /// dropped. Splitting at the first colon is safe because remote names
    /// may not contain colons — which is exactly what makes `remote:path`
    /// unambiguous. Lines split on any newline character: Swift reads
    /// `\r\n` as one grapheme, so a literal `"\n"` split would leave the
    /// `\r` glued to the previous line.
    static func parse(_ output: String) -> [RcloneRemote] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let type = line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            guard !name.isEmpty else { return nil }
            return RcloneRemote(name: name, type: type)
        }
    }
}
