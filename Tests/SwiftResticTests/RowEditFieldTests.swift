import AppKit
import SwiftUI
import Testing

/// The Also skip list's in-place field, hosted in a real `List` in a window:
/// the context in which a SwiftUI `TextField` never scrolled to its caret.
@MainActor
@Suite("Row edit field")
struct RowEditFieldTests {
    private let long = String(repeating: "LongFolderName/", count: 20) + "*.cache"

    /// The harness's row, a named view so a test can re-set the hosting
    /// view's rootView with a new `text` and drive `updateNSView`.
    private struct EditRow: View {
        let text: String
        var onChange: (String) -> Void = { _ in }

        var body: some View {
            List {
                Text("short")
                RowEditField(
                    text: text,
                    accessibilityLabel: "Also skip",
                    onChange: onChange,
                    onSubmit: {},
                    onCancel: {},
                    onEnd: {}
                )
            }
        }
    }

    private func hostedField(
        onChange: @escaping (String) -> Void = { _ in }
    ) async throws -> (NSWindow, NSTextField, NSHostingView<EditRow>) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: EditRow(text: long, onChange: onChange))
        window.contentView = host
        // Not: makeKeyAndOrderFront — a test must not show a window and take
        // the desktop's focus; first responders work in an unshown window.
        window.isReleasedWhenClosed = false
        // The field takes focus on the next turn of the main queue.
        var field: NSTextField?
        _ = await eventually(within: 5) {
            field = Self.textField(in: window.contentView!)
            return field?.currentEditor() != nil
        }
        return (window, try #require(field, "the field never took focus"), host)
    }

    private static func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = textField(in: subview) { return field }
        }
        return nil
    }

    @Test("a long pattern scrolls to its end when the caret moves there")
    func scrollsToCaret() async throws {
        let (window, field, _) = try await hostedField()
        defer { window.close() }
        let editor = try #require(field.currentEditor() as? NSTextView, "the field takes focus on arrival")
        #expect(editor.string == long)

        editor.moveToEndOfDocument(nil)
        _ = await eventually(within: 2) { (editor.superview as? NSClipView)?.bounds.origin.x ?? 0 > 0 }

        let clip = try #require(editor.superview as? NSClipView)
        #expect(clip.bounds.origin.x > 0, "the field shows the pattern's end, not its start")
    }

    @Test("Return and Escape hand focus back to the list")
    func returnFocusesList() async throws {
        for command in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:))] {
            let (window, field, _) = try await hostedField()
            defer { window.close() }
            let editor = try #require(field.currentEditor() as? NSTextView)

            editor.doCommand(by: command)

            #expect(window.firstResponder is NSTableView, "after \(command)")
        }
    }

    @Test("typing hands the field's text to onChange")
    func typingCallsOnChange() async throws {
        var received: [String] = []
        let (window, field, _) = try await hostedField(onChange: { received.append($0) })
        defer { window.close() }

        field.stringValue = "typed **/*.iso"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))

        #expect(received == ["typed **/*.iso"])
    }

    @Test("a change from outside waits for the editing to end")
    func outsideChangeWaitsForEditing() async throws {
        let (window, field, host) = try await hostedField()
        defer { window.close() }
        let editor = try #require(field.currentEditor() as? NSTextView, "the field takes focus on arrival")

        // Mid-edit the change waits: rewriting the field would reset the
        // caret. The poll gives the update pass its turn either way.
        host.rootView = EditRow(text: "replaced")
        _ = await eventually(within: 2) { field.stringValue != long }
        #expect(field.stringValue == long)

        window.endEditing(for: field)
        host.rootView = EditRow(text: "final")
        _ = await eventually(within: 2) { field.stringValue == "final" }
        #expect(field.currentEditor() == nil)
        #expect(field.stringValue == "final")
    }
}
