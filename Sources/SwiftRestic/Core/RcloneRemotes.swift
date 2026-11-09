import Foundation

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
    /// The bundled rclone is gone or not runnable — a damaged install; no
    /// rclone on the Mac stands in (`RcloneBinary`).
    case damaged
    case unreadable(String)
    case remotes([RcloneRemote])

    static let passwordProtected = "rclone’s configuration is password-protected, and SwiftRestic can’t unlock it. "
        + "To use rclone here, remove the password in Terminal with rclone config."
    /// Setting a remote up stays Terminal's job, whoever's rclone does it —
    /// the user's own, or the copy inside the app (revealed beside this
    /// sentence when there is nothing to list).
    static let noRemotes = "No rclone remotes yet. Set one up in Terminal with rclone config, then come back here. "
        + "SwiftRestic’s own rclone works for this even if none is installed on your Mac."
}

/// Lists the remotes configured in the user's rclone installation.
///
/// Asks `rclone listremotes --long` instead of reading the config file: the file's
/// location is rclone's business (XDG directories, `--config`, `RCLONE_CONFIG`
/// all move it), and parsing it would drag rclone's obscured secrets past the
/// app. The binary answers with authoritative names and types and never prints
/// secrets. A password-protected configuration cannot be listed: rclone
/// gets no terminal to ask for the password on.
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
            return .unreadable("rclone couldn’t list its remotes: \(error.localizedDescription)")
        }
        guard result.exitCode == 0 else {
            // An encrypted config asks for its password on the terminal, and
            // the runner gives rclone none: 1.75.2 prompts on stderr, then says only "Failed to
            // read line: EOF".
            if result.stderr.contains("Enter configuration password") {
                return .unreadable(RcloneSetup.passwordProtected)
            }
            guard let lastLine = result.stderr.split(whereSeparator: \.isNewline).last else {
                return .unreadable("rclone couldn’t list its remotes.")
            }
            let words = ResticRunResult.rcloneErrorWords(lastLine) ?? lastLine
            return .unreadable("rclone couldn’t list its remotes: \(words)")
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

/// The one rclone the app runs; `Tools/fetch-rclone.sh` pins it and
/// `Tools/embed-helpers.sh` puts it here. Not looked for on the Mac: an
/// rclone the tests never ran could reach different remotes.
struct RcloneBinary: Sendable {
    var url: URL

    static var bundled: RcloneBinary {
        RcloneBinary(url: Bundle.main.helpersURL.appendingPathComponent("rclone"))
    }

    /// `bundled` when it is there and runnable; nil says a damaged install —
    /// nothing on the Mac stands in.
    static var runnable: RcloneBinary? {
        let rclone = bundled
        return ResticBinary.isExecutableFile(atPath: rclone.url.path) ? rclone : nil
    }
}
