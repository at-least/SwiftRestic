import AppKit
import SwiftUI

/// `PathListEditor`'s in-place field: AppKit's, because a SwiftUI
/// `TextField` in a `List` row never scrolls to its caret (seen in a tester
/// VM, with `.lineLimit(1)` and a width cap tried too), so a long pattern's
/// end could not be reached. Takes focus with its text selected, as Finder's
/// rename does. Return and Escape hand focus back to the list, so ↑ ↓ and
/// Return keep working on its rows; a click away ends it as `onEnd`.
struct RowEditField: NSViewRepresentable {
    let text: String
    let accessibilityLabel: String
    let onChange: (String) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byClipping
        field.setAccessibilityLabel(accessibilityLabel)
        field.delegate = context.coordinator
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Only a change from outside: rewriting the field while the user
        // types would reset its caret.
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RowEditField

        init(parent: RowEditField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.onChange(field.stringValue)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onEnd()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            default:
                return false
            }
            focusList(from: control)
            return true
        }

        private func focusList(from view: NSView) {
            var ancestor = view.superview
            while let current = ancestor, !(current is NSTableView) {
                ancestor = current.superview
            }
            if let table = ancestor {
                view.window?.makeFirstResponder(table)
            }
        }
    }
}
