import SwiftUI

/// One pane, no tabs: what macOS leaves to the user. Granted, it is one
/// calm row.
struct SettingsView: View {
    private static let width: CGFloat = 560
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            // First: it is the app's permission, and restic inherits it.
            Section {
                LabeledContent("Full Disk Access") {
                    if needsFullDiskAccess {
                        FullDiskAccessStatusLabel(status: model.fullDiskAccess)
                    } else {
                        Text("On")
                    }
                }
                if needsFullDiskAccess {
                    Text("Without it, Mail, Messages, Safari and other apps’ data can’t be read, and backups that include them end with some files skipped.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    FullDiskAccessButton()
                    ExpandableCaption(
                        summary: "Turn on SwiftRestic in the list. macOS asks for an administrator password.",
                        detail: "If SwiftRestic is not in the list, click + and choose it from your Applications folder. If it is already on and this still says Not granted, turn it off and on again: a rebuilt or updated copy of SwiftRestic may not inherit the permission. If that doesn’t help, quit and reopen SwiftRestic."
                    )
                }
            }

            // No switch: the app starts at login while a plan has a
            // schedule (`LoginItem.change`). Only the step macOS leaves to
            // the user shows here.
            if model.loginItemNeedsApproval {
                Section("Scheduling") {
                    WarningLine(text: LoginItem.approvalNeeded)
                        .font(.caption)
                    Button("Open Login Items") { LoginItem.openLoginItemsSettings() }
                }
            }
        }
        .formStyle(.grouped)
        // The window follows the pane's height (the Settings scene's
        // `.contentSize`).
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            await model.refreshFullDiskAccess()
            await model.refreshLoginItemStatus()
        }
    }

    /// Unknown is treated as missing, as the run hints do: nothing
    /// observable says the grant is there.
    private var needsFullDiskAccess: Bool { model.fullDiskAccess != .granted }
}

/// Colour on the glyph only: coloured caption text falls short of the
/// contrast small text needs.
private struct FullDiskAccessStatusLabel: View {
    let status: FullDiskAccessStatus

    var body: some View {
        HStack(spacing: 4) {
            if status == .notGranted {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(status.displayName)
        }
    }
}
