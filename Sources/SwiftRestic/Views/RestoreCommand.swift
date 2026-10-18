import SwiftUI

/// What Restore… does on the page in view — a backup's tree on a Backups
/// tab, a folder or a file on a Files tab, Find Files' results — published
/// by the pane that holds it, for the window toolbar's button and for
/// File ▸ Restore…. The toolbar's trailing side is where the HIG puts a
/// page's primary action, which sat in the pane's bottom bar until
/// 2026-10-18 (Windows: "Avoid putting critical information or actions in a
/// bottom bar, because people often relocate a window in a way that hides
/// its bottom edge"), and the menu bar is where every toolbar item is also
/// found (Toolbars: "Make every toolbar item available as a command in the
/// menu bar").
struct RestoreCommand {
    /// What it restores, in the button's words: "Restore…" for a
    /// selection, "Restore Folder…" or "Restore Backup…" for the whole of
    /// what is open.
    let title: String
    let help: String
    let isEnabled: Bool
    /// Return restores — a selection's restore, never a whole backup's: a
    /// Return meant for something else must not open that.
    let isDefault: Bool
    let run: () -> Void
}

extension FocusedValues {
    @Entry var restoreCommand: RestoreCommand?
}

extension View {
    /// The pane's Restore…: a prominent button at the toolbar's trailing
    /// side, ahead of the search field, and File ▸ Restore… while the pane
    /// is on screen.
    func restoreCommand(_ command: RestoreCommand) -> some View {
        toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(command.title, action: command.run)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(command.isDefault ? .defaultAction : nil)
                    .disabled(!command.isEnabled)
                    .help(command.help)
            }
        }
        .focusedSceneValue(\.restoreCommand, command)
    }
}

/// File ▸ Restore…, the toolbar's button in the menu bar: whatever the pane
/// on screen restores, greyed when it has nothing to.
struct RestoreCommands: Commands {
    @FocusedValue(\.restoreCommand) private var command

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button(command?.title ?? "Restore…") { command?.run() }
                .disabled(command?.isEnabled != true)
        }
    }
}
