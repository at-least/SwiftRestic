import AppKit
import SwiftUI

/// A native search field inside a pane: the magnifier, the clear button,
/// Esc, and VoiceOver's "search text field" come with it. Not `.searchable`,
/// which would put the search field up in the window toolbar, away from the
/// pane whose contents it searches.
///
/// The binding moves when the field sends its action — typing, Esc and the
/// clear button all reach it — with AppKit's brief search delay rather
/// than on every keystroke.
struct SearchField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    /// Asks the field to take the keyboard focus — ⇧⌘F on a Files tab.
    /// `onFocus` runs once it has, so the asker can spend the ask; a field
    /// the ask created takes it as soon as it is in the window.
    var takesFocus = false
    var onFocus: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> FocusableSearchField {
        let field = FocusableSearchField()
        field.placeholderString = placeholder
        // Without a label VoiceOver has only the placeholder, which it reads
        // as a value hint, not as the field's name.
        field.cell?.setAccessibilityLabel(placeholder)
        field.sendsSearchStringImmediately = false
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchStringChanged(_:))
        return field
    }

    func updateNSView(_ field: FocusableSearchField, context: Context) {
        context.coordinator.text = $text
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
            field.cell?.setAccessibilityLabel(placeholder)
        }
        // How the pane's reset on a record switch reaches the field — never
        // while it is being typed in: the binding moves only after AppKit's
        // search delay, and a redraw inside it would write the older text
        // back, eating the keys typed since.
        if field.stringValue != text, field.currentEditor() == nil { field.stringValue = text }
        if takesFocus { field.focus(then: onFocus) }
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

/// The field behind `SearchField`, which can be asked for the keyboard
/// focus before it is in a window: a Files tab that ⇧⌘F opened builds its
/// field in the same update that asks, so the ask waits for the window.
final class FocusableSearchField: NSSearchField {
    private var pendingFocus: (() -> Void)?

    /// Takes the focus — a turn later, out of the update that asked, since
    /// `done` writes the state that asked — or once the field is in a window.
    func focus(then done: @escaping () -> Void) {
        pendingFocus = done
        Task { @MainActor [weak self] in self?.takePendingFocus() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Task { @MainActor [weak self] in self?.takePendingFocus() }
    }

    private func takePendingFocus() {
        guard let done = pendingFocus, let window, window.makeFirstResponder(self) else { return }
        pendingFocus = nil
        done()
    }
}
