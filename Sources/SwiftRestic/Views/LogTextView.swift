import SwiftUI

/// Read-only, selectable, monospaced text with the system find bar (⌘F) —
/// an `NSTextView`, because it lays out lazily and holds a quarter-megabyte
/// log without the stall a SwiftUI `Text` of that size would cost.
struct LogTextView: NSViewRepresentable {
    let text: String
    let finder: LogFinder

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        finder.textView = view
        view.isEditable = false
        view.isSelectable = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isRichText = false
        view.drawsBackground = true
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 6, height: 6)
        show(text, in: view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        guard view.string != text else { return }
        show(text, in: view)
    }

    /// Font and colour after the string: assigning `string` takes the typing
    /// attributes, and the semantic text colour is what follows dark mode.
    private func show(_ text: String, in view: NSTextView) {
        view.string = text
        view.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        view.textColor = .textColor
    }
}

/// The way to the text view's find bar. `usesFindBar` alone never shows it
/// here: AppKit opens the bar only for a find action whose sender's tag
/// names it, which a standard Edit ▸ Find menu item sends on ⌘F — and this
/// app's Edit menu has no Find items, while the standard key bindings bind
/// nothing to ⌘F.
@MainActor
final class LogFinder {
    fileprivate weak var textView: NSTextView?

    func showFindBar() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        let sender = NSMenuItem()
        sender.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(sender)
    }
}
