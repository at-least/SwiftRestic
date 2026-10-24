import AppKit

/// Keeps AppKit's Writing Tools, AutoFill, Start Dictation and Emoji &
/// Symbols out of the menu bar's Edit menu (the user's call).
@MainActor
enum EditMenuTrim {
    /// Writing Tools and AutoFill have no defaults key that turns them off
    /// (macOS 27.0.1): AppKit adds them again on every update of the Edit
    /// menu, so they are taken out each time they arrive.
    static let removedIdentifiers: Set<String> = [
        "__NSTextViewContextSubmenuIdentifierWritingTools",
        "_NSMenuItemAutoFillIdentifier",
    ]

    /// Before launch finishes: AppKit reads the two defaults when it first
    /// builds the Edit menu.
    static func install() {
        UserDefaults.standard.register(defaults: [
            "NSDisabledDictationMenuItem": true,
            "NSDisabledCharacterPaletteMenuItem": true,
        ])
        // Every menu bar menu, not the notification's own menu: a
        // Notification may not cross into the main actor (Swift 6), and
        // `trim` leaves a menu without the two items untouched.
        NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                for case let menu? in NSApp.mainMenu?.items.map(\.submenu) ?? [] {
                    trim(menu)
                }
            }
        }
    }

    /// Removes the items, then any separator left first, last or beside
    /// another.
    static func trim(_ menu: NSMenu) {
        let unwanted = menu.items.filter { removedIdentifiers.contains($0.identifier?.rawValue ?? "") }
        guard !unwanted.isEmpty else { return }
        for item in unwanted { menu.removeItem(item) }
        var previousIsSeparator = true
        for item in menu.items {
            if item.isSeparatorItem, previousIsSeparator {
                menu.removeItem(item)
                continue
            }
            previousIsSeparator = item.isSeparatorItem
        }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }
}
