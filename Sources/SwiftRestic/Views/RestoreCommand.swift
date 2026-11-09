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

/// No "Restore a File…" beside it: Edit ▸ Find… (⌘F) is the way in to a
/// file not on screen (the user's call).
struct RestoreCommands: Commands {
    @FocusedValue(\.restoreCommand) private var command

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("Restore…") { command?.run() }
                .disabled(command?.isEnabled != true)
        }
    }
}
