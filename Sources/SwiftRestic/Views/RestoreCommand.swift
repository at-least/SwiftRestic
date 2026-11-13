import SwiftUI

/// File ▸ Restore and Restore To…: the restore of the pane in view — Restore
/// the same as its bottom bar's prominent button, Restore To… the same as its
/// rows' menu item. Not in the window toolbar's trailing side, the HIG's
/// place for a page's primary action: the user chose the bottom bar.
struct RestoreCommand {
    let isEnabled: Bool
    let run: (_ choosingDestination: Bool) -> Void
}

extension FocusedValues {
    @Entry var restoreCommand: RestoreCommand?
}

extension View {
    func restoreCommand(_ command: RestoreCommand) -> some View {
        focusedSceneValue(\.restoreCommand, command)
    }
}

/// No "Restore a File…" beside them: Edit ▸ Find… (⌘F) is the way in to a
/// file not on screen (the user's call).
struct RestoreCommands: Commands {
    @FocusedValue(\.restoreCommand) private var command

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("Restore") { command?.run(false) }
                .disabled(command?.isEnabled != true)
            Button("Restore To…") { command?.run(true) }
                .disabled(command?.isEnabled != true)
        }
    }
}
