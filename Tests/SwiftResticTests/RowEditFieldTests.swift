import AppKit
import SwiftUI
import Testing

/// The Also skip list's in-place field, hosted in a real `List` in a window:
/// the context in which a SwiftUI `TextField` never scrolled to its caret.
@MainActor
@Suite("Row edit field")
struct RowEditFieldTests {
    private let long = String(repeating: "LongFolderName/", count: 20) + "*.cache"

    private func hostedField() async throws -> (NSWindow, NSTextField) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: List {
            Text("short")
            RowEditField(
                text: long,
                accessibilityLabel: "Also skip",
                onChange: { _ in },
                onSubmit: {},
                onCancel: {},
                onEnd: {}
            )
        })
        // Not: makeKeyAndOrderFront — a test must not show a window and take
        // the desktop's focus; first responders work in an unshown window.
        window.isReleasedWhenClosed = false
        // The field takes focus on the next turn of the main queue.
        try await Task.sleep(for: .milliseconds(300))
        let field = try #require(Self.textField(in: window.contentView!))
        return (window, field)
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
        let (window, field) = try await hostedField()
        defer { window.close() }
        let editor = try #require(field.currentEditor() as? NSTextView, "the field takes focus on arrival")
        #expect(editor.string == long)

        editor.moveToEndOfDocument(nil)
        try await Task.sleep(for: .milliseconds(100))

        let clip = try #require(editor.superview as? NSClipView)
        #expect(clip.bounds.origin.x > 0, "the field shows the pattern's end, not its start")
    }

    @Test("Return and Escape hand focus back to the list")
    func returnFocusesList() async throws {
        for command in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:))] {
            let (window, field) = try await hostedField()
            defer { window.close() }
            let editor = try #require(field.currentEditor() as? NSTextView)

            editor.doCommand(by: command)

            #expect(window.firstResponder is NSTableView, "after \(command)")
        }
    }
}
