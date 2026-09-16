import Foundation

/// Splits a typed command line into arguments the way a shell would.
///
/// The console runs restic directly rather than through a shell, so quoting has
/// to be handled here — otherwise a path with a space arrives as two arguments.
enum CommandLineTokenizer {
    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasCurrent = false
        var quote: Character?
        var escaped = false
        // Lookahead index: inside double quotes the backslash is only special
        // before the characters POSIX reserves, which the next character decides.
        let characters = Array(input)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            index += 1
            if escaped {
                current.append(character)
                hasCurrent = true
                escaped = false
                continue
            }
            // A backslash is literal inside single quotes, as in a shell.
            if character == "\\", quote != "'" {
                // Inside double quotes the shell keeps the backslash only
                // before $, `, ", \ and newline; before anything else — a
                // Windows-style "C:\Users", say — it is the literal character
                // the user typed. Outside quotes it escapes whatever follows.
                if quote == "\"",
                   index < characters.count,
                   !["$", "`", "\"", "\\", "\n"].contains(characters[index])
                {
                    current.append(character)
                    hasCurrent = true
                } else {
                    escaped = true
                    hasCurrent = true
                }
                continue
            }
            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
                hasCurrent = true
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                hasCurrent = true
                continue
            }
            if character.isWhitespace {
                if hasCurrent { tokens.append(current) }
                current = ""
                hasCurrent = false
                continue
            }
            current.append(character)
            hasCurrent = true
        }
        // A trailing backslash has nothing to escape. Keeping it literal — as
        // the character the user typed — beats emitting an empty argument no
        // one asked for.
        if escaped {
            current.append("\\")
            hasCurrent = true
        }
        if hasCurrent { tokens.append(current) }
        return tokens
    }

    /// Whether the input ends inside an open quote. A shell refuses such a
    /// line; the console must too — silently closing the quote would run a
    /// mangled argument the user never typed.
    static func hasUnterminatedQuote(_ input: String) -> Bool {
        var quote: Character?
        var escaped = false
        for character in input {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                continue
            }
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            }
        }
        return quote != nil
    }

    /// Renders arguments back to a shell-like command line — the display
    /// inverse of `tokenize`. Joining with spaces alone loses quoting, so a
    /// destructive confirmation would show a different command than the one
    /// about to run: `--path ~/My Backups` displayed for two arguments.
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

    /// restic subcommands that change or delete data, or take an exclusive lock.
    ///
    /// Typing one of these into the console gets a confirmation first; everything
    /// else runs straight away. `restore` belongs here even though the repository
    /// is untouched: it overwrites whatever sits at the destination. `tag` also
    /// mutates, but only snapshot metadata, reversibly with another `tag` —
    /// confirming it would be noise.
    static let destructiveSubcommands: Set<String> = [
        "forget", "prune", "rewrite", "repair", "unlock", "init", "migrate", "key",
        "restore",
    ]

    static func isDestructive(_ arguments: [String]) -> Bool {
        // Every token is checked, not just the first non-flag one: restic
        // accepts its global flags before the subcommand (`-r /repo prune`),
        // and the flag's value would otherwise step in as the "subcommand"
        // and arm no confirmation. The cost of the wider net is a needless
        // Enter press when a flag's *value* spells a subcommand name —
        // `--tag prune` confirms — which is the safe side to err on.
        arguments.contains { destructiveSubcommands.contains($0) }
    }
}
