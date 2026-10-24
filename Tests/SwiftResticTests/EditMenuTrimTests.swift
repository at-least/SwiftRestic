import AppKit
import Testing

@MainActor
@Suite("Edit menu trim")
struct EditMenuTrimTests {
    private func item(_ title: String, identifier: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
        return item
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "---" : $0.title }
    }

    // The layout AppKit gave a SwiftUI Edit menu on macOS 27.0.1, with the
    // two defaults keys set.
    @Test("Writing Tools and AutoFill go, with the separators they leave")
    func trimsWhatAppKitAdds() {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Paste"))
        menu.addItem(item("Select All"))
        menu.addItem(.separator())
        menu.addItem(item("Writing Tools", identifier: "__NSTextViewContextSubmenuIdentifierWritingTools"))
        menu.addItem(.separator())
        menu.addItem(item("AutoFill", identifier: "_NSMenuItemAutoFillIdentifier"))

        EditMenuTrim.trim(menu)

        #expect(titles(menu) == ["Paste", "Select All"])
    }

    @Test("a menu without them keeps its separators")
    func leavesOtherMenusAlone() {
        let menu = NSMenu(title: "View")
        menu.addItem(.separator())
        menu.addItem(item("Show Sidebar"))
        menu.addItem(.separator())

        EditMenuTrim.trim(menu)

        #expect(titles(menu) == ["---", "Show Sidebar", "---"])
    }
}
