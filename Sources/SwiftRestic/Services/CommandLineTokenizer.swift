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

        for character in input {
            if escaped {
                current.append(character)
                hasCurrent = true
                escaped = false
                continue
            }
            // A backslash is literal inside single quotes, as in a shell.
            if character == "\\", quote != "'" {
                escaped = true
                hasCurrent = true
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
        if hasCurrent { tokens.append(current) }
        return tokens
    }

    /// restic subcommands that change or delete data, or take an exclusive lock.
    ///
    /// Typing one of these into the console gets a confirmation first; everything
    /// else runs straight away.
    static let destructiveSubcommands: Set<String> = [
        "forget", "prune", "rewrite", "repair", "unlock", "init", "migrate", "key",
    ]

    static func isDestructive(_ arguments: [String]) -> Bool {
        guard let first = arguments.first(where: { !$0.hasPrefix("-") }) else { return false }
        return destructiveSubcommands.contains(first)
    }
}
