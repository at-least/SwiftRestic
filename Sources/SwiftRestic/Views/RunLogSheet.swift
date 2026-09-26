import SwiftUI

/// A run's log, read from `Logs/<run-id>.log`: what restic printed, line by
/// line, with the versions and the verdict around it. A sheet rather than
/// an inline pane, so Activity's table keeps its height; a log can run to
/// hundreds of kilobytes, which is what the text view below is for.
struct RunLogSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let run: RunRecord

    @State private var text: String?
    @State private var isLoaded = false
    @State private var finder = LogFinder()

    private var logURL: URL { model.runLogs.url(for: run.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(run.kind.rawValue.capitalized) log — \(run.planName)")
                    .font(.headline)
                Text(Format.timestamp(run.startedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            Group {
                if let text {
                    LogTextView(text: text, finder: finder)
                } else if isLoaded {
                    ContentUnavailableView(
                        "Log file not found",
                        systemImage: "doc.questionmark",
                        description: Text("It may have been deleted. The run's summary stays in Activity.")
                    )
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 10) {
                Text(logURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(logURL.path)
                Spacer(minLength: 0)
                Button("Find…") { finder.showFindBar() }
                    .keyboardShortcut("f")
                    .disabled(text == nil)
                    .help("Search the log (⌘F)")
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([logURL])
                }
                .disabled(text == nil)
                Button("Copy Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text ?? "", forType: .string)
                }
                .disabled(text == nil)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 720, minHeight: 460)
        .task {
            text = await model.loadRunLog(run)
            isLoaded = true
        }
    }
}

/// Read-only, selectable, monospaced text with the system find bar (⌘F) —
/// an `NSTextView`, because it lays out lazily and holds a quarter-megabyte
/// log without the stall a SwiftUI `Text` of that size would cost.
private struct LogTextView: NSViewRepresentable {
    let text: String
    let finder: LogFinder

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
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
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
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

/// The sheet's way to the text view's find bar. `usesFindBar` alone never
/// shows it here: AppKit opens the bar only for a find action whose sender's
/// tag names it, which a standard Edit ▸ Find menu item sends on ⌘F — and
/// this app's Edit menu has no Find items, while the standard key bindings
/// bind nothing to ⌘F. Measured: ⌘F with the log focused left the sheet's
/// AX tree unchanged.
@MainActor
private final class LogFinder {
    weak var textView: NSTextView?

    func showFindBar() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        let sender = NSMenuItem()
        sender.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(sender)
    }
}
