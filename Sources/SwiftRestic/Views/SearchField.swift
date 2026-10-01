import AppKit
import SwiftUI

/// A native search field inside a pane: the magnifier, the clear button,
/// Esc, and VoiceOver's "search text field" come with it. Not `.searchable`,
/// which would put the search field up in the window toolbar, away from the
/// pane whose contents it searches.
///
/// The binding moves when the field sends its action — typing, Esc and the
/// clear button all reach it (probed on macOS 26), with AppKit's brief
/// search delay rather than on every keystroke.
struct SearchField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        // Without a label VoiceOver has only the placeholder, which it reads
        // as a value hint, not as the field's name.
        field.cell?.setAccessibilityLabel(placeholder)
        field.sendsSearchStringImmediately = false
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchStringChanged(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
            field.cell?.setAccessibilityLabel(placeholder)
        }
        // How the pane's reset on a record switch reaches the field.
        if field.stringValue != text { field.stringValue = text }
    }

    @MainActor
    final class Coordinator: NSObject {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func searchStringChanged(_ sender: NSSearchField) {
            if text.wrappedValue != sender.stringValue {
                text.wrappedValue = sender.stringValue
            }
        }
    }
}
