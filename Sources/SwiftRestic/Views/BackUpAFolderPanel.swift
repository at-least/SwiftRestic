import AppKit

/// Back Up a Folder…'s folder panel. With locations set up it also asks
/// where, in a pop-up below the browser: a location set up here is often
/// the last answer (`AppModel.backUpWithoutSheet`), and New Location… goes
/// on to the first-run sheet.
///
/// The pop-up only: a live requirement line or Full Disk Access notice
/// would follow the panel's selection through a delegate, in a panel macOS
/// draws in another process for a sandboxed app. A choice that still needs
/// either opens the sheet, which shows both.
@MainActor
enum BackUpAFolderPanel {
    struct Answer {
        let source: String
        /// Nil for New Location…, and with no location set up.
        let destination: FirstBackupDestination?
    }

    struct Location {
        let id: UUID
        let label: String
    }

    static func run(locations: [Location], initial: FirstBackupDestination?) -> Answer? {
        let panel = FilePicker.directoryPanel(message: "Choose the folder to back up", prompt: "Choose")
        var popUp: NSPopUpButton?
        if !locations.isEmpty {
            let button = destinationPopUp(locations: locations, initial: initial)
            panel.accessoryView = accessory(holding: button)
            panel.isAccessoryViewDisclosed = true
            panel.prompt = "Back Up"
            popUp = button
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let chosen = popUp?.selectedItem?.representedObject as? UUID
        return Answer(source: url.path, destination: chosen.map(FirstBackupDestination.location))
    }

    /// Menu items added one by one: `addItem(withTitle:)` drops a title the
    /// menu already holds, and two locations can share a label.
    private static func destinationPopUp(locations: [Location], initial: FirstBackupDestination?) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        let menu = NSMenu()
        for location in locations {
            let item = NSMenuItem(title: location.label, action: nil, keyEquivalent: "")
            item.representedObject = location.id
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "New Location…", action: nil, keyEquivalent: ""))
        button.menu = menu
        if case let .location(id) = initial, let index = locations.firstIndex(where: { $0.id == id }) {
            button.selectItem(at: index)
        }
        button.setAccessibilityIdentifier(AccessibilityID.BackUpAFolderPanel.destination)
        return button
    }

    private static func accessory(holding popUp: NSPopUpButton) -> NSView {
        let stack = NSStackView(views: [NSTextField(labelWithString: "Back up to:"), popUp])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        stack.frame.size = stack.fittingSize
        return stack
    }
}
