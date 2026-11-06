import SwiftUI

/// What Restore does on the page in view — a backup's tree on a Backups
/// tab, a folder or a file on a Files tab, Search All Backups' results — published
/// by the pane that holds it for File ▸ Restore: the menu bar's way to the
/// pane's own restore, its bottom bar's prominent button. Not in the window
/// toolbar's trailing side, the HIG's place for a page's primary action:
/// the user chose the bottom bar.
struct RestoreCommand {
    let isEnabled: Bool
    let run: () -> Void
}

extension FocusedValues {
    @Entry var restoreCommand: RestoreCommand?
}

extension View {
    func restoreCommand(_ command: RestoreCommand) -> some View {
        focusedSceneValue(\.restoreCommand, command)
    }
}

struct RestoreCommands: Commands {
    @FocusedValue(\.restoreCommand) private var command
    /// The way in from anywhere, for someone who has lost a file and is on
    /// no pane yet: Search. Off only with nothing to search.
    let canSearch: Bool
    let search: () -> Void

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("Restore a File…", action: search)
                .disabled(!canSearch)
            Button("Restore…") { command?.run() }
                .disabled(command?.isEnabled != true)
        }
    }
}
