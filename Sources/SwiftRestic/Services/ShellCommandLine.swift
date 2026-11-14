import Foundation

enum ShellCommandLine {
    /// A shell-like command line for the run log. Joining with spaces alone
    /// loses quoting: `--exclude ~/My Backups` would read as two arguments.
    static func render(_ arguments: [String]) -> String {
        arguments.map { argument in
            let needsQuoting = argument.isEmpty || argument.contains { character in
                character.isWhitespace || character == "'" || character == "\"" || character == "\\"
            }
            guard needsQuoting else { return argument }
            // Single quotes protect everything but themselves; the shell's
            // `'\''` dance closes the quote, carries a literal quote, reopens.
            return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        .joined(separator: " ")
    }
}
