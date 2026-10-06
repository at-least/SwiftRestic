import AppKit
import SwiftUI

extension View {
    /// A click anywhere in this list gives it the keyboard, as a click in an
    /// AppKit table does. A SwiftUI List on macOS 26 takes a click's
    /// selection but not keyboard focus: keys keep going to whatever held
    /// focus before the click — here the sidebar, which holds it from the
    /// window's opening.
    ///
    /// The click itself, not a selection change: the List's selection
    /// binding is not set by a click on a row already selected, and a row
    /// stays selected across a backup switch — back from the sidebar, the
    /// click on it would leave the keyboard there.
    func focusOnClick(_ isFocused: FocusState<Bool>.Binding) -> some View {
        focused(isFocused)
            .background(ClickMonitor { isFocused.wrappedValue = true })
    }
}

/// Calls `action` on each left mouse-down inside its frame in its window,
/// before the window handles the click, and passes the click on untouched:
/// the row under it still selects, extends a selection and drags.
private struct ClickMonitor: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        MonitorView()
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.action = action
    }

    final class MonitorView: NSView {
        var action: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            // Local monitors run on the main thread, inside sendEvent.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, event.window === self.window,
                          self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                    else { return }
                    self.action()
                }
                return event
            }
        }
    }
}
