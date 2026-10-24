import SwiftUI

/// What Restore does on the page in view — a backup's tree on a Backups
/// tab, a folder or a file on a Files tab, Find Files' results — published
/// by the pane that holds it for File ▸ Restore: the menu bar's way to the
/// pane's own restore, its bottom bar's prominent button. Not in the window
/// toolbar's trailing side, the HIG's place for a page's primary action:
/// the user chose the bottom bar.
struct RestoreCommand {
    /// What it restores, in the pane's words: "Restore" for a selection,
    /// "Restore Folder" or "Restore Entire Backup" for the whole of what
    /// is open, "Restore Selected" for Find Files' rows.
    let title: String
    let isEnabled: Bool
    let run: () -> Void
}

extension FocusedValues {
    @Entry var restoreCommand: RestoreCommand?
}

extension View {
    /// Publishes the pane's restore to File ▸ Restore while the pane is
    /// on screen.
    func restoreCommand(_ command: RestoreCommand) -> some View {
        focusedSceneValue(\.restoreCommand, command)
    }
}

/// File ▸ Restore: whatever the pane on screen restores — its bottom bar's
/// button's restore — greyed when it has nothing to.
struct RestoreCommands: Commands {
    @FocusedValue(\.restoreCommand) private var command

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button(command?.title ?? "Restore") { command?.run() }
                .disabled(command?.isEnabled != true)
        }
    }
}
