import Foundation
import Testing

@Suite("Command line rendering")
struct CommandLineRenderTests {
    @Test("an argument with a space, a quote or nothing in it is quoted")
    func renderQuoting() {
        #expect(ShellCommandLine.render([]) == "")
        #expect(ShellCommandLine.render(["restore", "--path", "~/My Backups"]) == "restore --path '~/My Backups'")
        // The shell's `'\''` dance for an embedded single quote.
        #expect(ShellCommandLine.render(["tag", "it's"]) == "tag 'it'\\''s'")
        // An empty argument is a real argument and must stay visible as one.
        #expect(ShellCommandLine.render(["", "x"]) == "'' x")
    }
}
