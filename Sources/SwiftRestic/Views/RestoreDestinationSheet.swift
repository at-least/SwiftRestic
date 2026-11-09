import AppKit
import SwiftUI

/// One restore waiting for its destination: what, from which backup, and
/// what to run once the sheet has an answer. Every Restore in the app
/// builds one — the Restore pane's, Search All Backups' and the Files view's — so
/// the destination and what to do with what is already there are asked in
/// one place.
struct RestoreDestinationRequest: Identifiable {
    let id = UUID()
    let subject: RestoreSubject
    /// A line under the headline about how the selection became the
    /// subject: selected items inside a selected folder, which come with it
    /// (`RestoreBatch.coveredNote`).
    var selectionNote: String?
    let backupTime: Date?
    /// How many backups the items come from: Search All Backups restores each row
    /// from the backup it was found in.
    var backupCount = 1
    /// The version's own modified time, when the request came from a row
    /// named by it (the Files tab's version list): the sheet then repeats
    /// the words the user chose by beside the backup the bytes come from.
    var versionModified: Date?
    /// Starts the restore with this policy, into these directories: one per
    /// item, in order (`RestoreSubject.directoryCount`) — the same folder for
    /// all, or for Original location each item's own parent.
    let perform: @MainActor ([URL], RestoreOverwritePolicy) -> Void

    /// The picked rows' restore — every surface's that restores a selection:
    /// the Restore pane's and the folder-versions pane's, of one backup, and
    /// Search All Backups', of several. One rule and one
    /// wording for all (`RestoreSelection`): items inside a selected folder
    /// of the same backup are left to it, and the sheet says so, or three
    /// selected rows would read as two. Nil when the picked rows restore
    /// nothing.
    static func picked(
        _ picked: [RestoreSource],
        repositoryID: UUID,
        model: AppModel
    ) -> RestoreDestinationRequest? {
        guard let selection = RestoreSelection(picked) else { return nil }
        return RestoreDestinationRequest(
            subject: selection.subject,
            selectionNote: selection.note,
            backupTime: selection.backupTime,
            backupCount: selection.backupCount
        ) { directories, overwrite in
            Task { await model.restore(selection, repositoryID: repositoryID, into: directories, overwrite: overwrite) }
        }
    }
}

/// Arq's "Restore to:" window, with our item-and-backup wording kept: a
/// folder (the Desktop until another is chosen) or the item's original
/// location, and a live line saying exactly where it lands. What is already
/// there is asked about only when Restore finds something in the way, so
/// Return, Return (the pane's default action, then this sheet's) never
/// replaces anything: the question's Replace has no Return.
struct RestoreDestinationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let request: RestoreDestinationRequest
    /// Nil until the original-location check answers, unless the user picks
    /// first: then Original location when it is available, else the folder.
    /// No guess shown before the answer, which could flip under a Return.
    @State private var kind: RestoreDestinationKind?
    @State private var folder: URL = .desktopDirectory
    /// Nil until the detached check answers: the parent may sit on a
    /// stalled network mount, which must not stall the main actor.
    @State private var original: OriginalLocation?
    @State private var isConfirming = false
    /// The Replace pre-check, which Cancel and the sheet's closing stop: a
    /// look at a stalled mount can outlast the user's patience, and a
    /// cancelled sheet must not start a restore when the look returns.
    @State private var confirmation: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(backupLine)
                    .foregroundStyle(.secondary)
                if let note = request.selectionNote {
                    caption(note)
                        .padding(.top, 4)
                }
            }

            Form {
                LabeledContent("Restore to") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Picker("Restore to", selection: $kind) {
                            Text(FileManager.default.displayName(atPath: folder.path))
                                .tag(RestoreDestinationKind?.some(.folder))
                            Text("Original location")
                                .tag(RestoreDestinationKind?.some(.originalLocation))
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        // Beside the folder's radio, the first baseline.
                        Button("Choose…") { chooseFolder() }
                            .accessibilityIdentifier(AccessibilityID.RestoreSheet.chooseFolder)
                            .controlSize(.small)
                            .help("Pick the folder to restore into")
                    }
                }

                LabeledContent {
                    detailLine
                } label: {
                    // The row belongs to the picker above; no label of its own.
                    Text(verbatim: "")
                        .accessibilityHidden(true)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    confirmation?.cancel()
                    close()
                }
                .keyboardShortcut(.cancelAction)
                Button("Restore") { restore() }
                    .accessibilityIdentifier(AccessibilityID.RestoreSheet.restore)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(directories == nil || model.isRestoring || isConfirming)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await checkOriginalLocation() }
        .onDisappear { confirmation?.cancel() }
    }

    private var itemName: String? {
        if case let .item(name, _, _) = request.subject { return name }
        return nil
    }

    private var items: [RestoreItem]? {
        if case let .items(items) = request.subject { return items }
        return nil
    }

    private var headline: String {
        switch request.subject {
        case let .item(name, _, _): "Restore “\(name)”"
        case let .items(items): "Restore \(Format.plural(items.count, "item"))"
        }
    }

    private var backupLine: String {
        RestoreSelection.backupLine(
            backupCount: request.backupCount,
            backupTime: request.backupTime,
            versionModified: request.versionModified
        )
    }

    private var subjectName: String {
        switch request.subject {
        case let .item(name, _, _): "“\(name)”"
        case let .items(items): "the \(Format.plural(items.count, "item"))"
        }
    }

    /// Selected items that would land on each other in one folder — the
    /// same name from two folders of the backup (`RestoreBatch`). Original
    /// location puts each back in its own folder, where no two can meet.
    private var collidingNames: [String] {
        items.map { RestoreBatch.collidingNames($0.map(\.name)) } ?? []
    }

    private var directories: [URL]? {
        switch kind {
        case nil:
            return nil
        case .folder?:
            guard collidingNames.isEmpty else { return nil }
            return Array(repeating: folder, count: request.subject.directoryCount)
        case .originalLocation?:
            if case let .available(directories, _) = original { return directories } else { return nil }
        }
    }

    @ViewBuilder
    private var detailLine: some View {
        switch kind {
        case nil:
            caption("Checking…")
        case .folder?:
            if !collidingNames.isEmpty {
                // A sentence, not a path: what is in the way, and the two
                // ways around it.
                caption("More than one selected item is named \(collidingNames.map { "“\($0)”" }.joined(separator: ", ")) — in one folder they would land on each other. Restore them one at a time, or to their original locations.")
            } else if let items {
                pathCaption("Will restore the \(Format.plural(items.count, "item")) into \(Self.abbreviated(folder))", fullPath: folder.path)
            } else {
                let landing = RestoreDestinationRules.landings(for: request.subject, into: [folder])[0]
                pathCaption("Will restore to \(Self.abbreviated(landing))", fullPath: landing.path)
            }
        case .originalLocation?:
            switch original {
            case nil:
                caption("Checking…")
            case let .available(directories, landings)?:
                if let items {
                    // One folder for all when they share it; otherwise each
                    // goes back to its own, which no single path can say.
                    if Set(directories).count == 1 {
                        pathCaption("Will put the \(Format.plural(items.count, "item")) back in \(Self.abbreviated(directories[0]))", fullPath: directories[0].path)
                    } else {
                        caption("Will put each of the \(Format.plural(items.count, "item")) back in the folder it was backed up from.")
                    }
                } else {
                    pathCaption("Will put “\(itemName ?? "")” back at \(Self.abbreviated(landings[0]))", fullPath: landings[0].path)
                }
            case let .unavailable(reason)?:
                // A sentence, not a path: it wraps rather than truncating.
                caption(reason)
            }
        }
    }

    /// A sentence, which wraps. Height-pinned: the Form sizes its rows from
    /// a one-line measure and otherwise cuts a long sentence to one line. Safe in this sheet, unlike in the window's detail column:
    /// the sheet's fixed 460-pt width is the only width it is ever asked at.
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func pathCaption(_ text: String, fullPath: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(fullPath)
    }

    private static func abbreviated(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// Off the main actor, like the remembered folder's look below.
    private func checkOriginalLocation() async {
        let subject = request.subject
        let answer = await Task.detached(priority: .userInitiated) {
            RestoreDestinationRules.originalLocation(
                for: subject,
                directoryExists: RestoreDestinationRules.directoryExists,
                isWritable: RestoreDestinationRules.isWritable
            )
        }.value
        original = answer
        guard kind == nil else { return }
        if case .available = answer { kind = .originalLocation } else { kind = .folder }
    }

    private func chooseFolder() {
        guard let url = FilePicker.chooseDirectory(
            message: "Choose where to restore \(subjectName)",
            directoryURL: folder
        ) else { return }
        folder = url
        kind = .folder
    }

    private func restore() {
        guard let directories else { return }
        let landings = RestoreDestinationRules.landings(for: request.subject, into: directories)
        isConfirming = true
        confirmation = Task {
            let existing = await Task.detached(priority: .userInitiated) {
                RestoreDestinationRules.replaceConfirmationTargets(
                    landings: landings,
                    exists: RestoreDestinationRules.itemExists(at:)
                )
            }.value
            defer { isConfirming = false }
            // Cancel pressed while the look ran: nothing starts.
            guard !Task.isCancelled else { return }
            // Nothing in the way: keep is the mode that cannot clobber what
            // appears between the look and restic's run.
            let policy: RestoreOverwritePolicy? = existing.isEmpty ? .keepExisting : askAboutExisting(existing)
            guard let policy, !Task.isCancelled else { return }
            commit(directories, policy)
        }
    }

    /// What to do with what is already there; nil is Cancel. "Replace" is
    /// not marked destructive (the user asked for this restore — the HIG's
    /// Empty Trash case), yet no button is the default, the HIG's way to
    /// make people read first. Escape keeps NSAlert's route to "Cancel".
    /// A single file gets no Restore Missing Files Only: keeping it would
    /// restore nothing.
    private func askAboutExisting(_ existing: [URL]) -> RestoreOverwritePolicy? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let backupOf = request.backupTime.map { " of \(Format.timestamp($0))" } ?? ""
        let neverRemoved = "Files that aren’t in the backup are never removed."
        let offersMissingOnly: Bool
        switch request.subject {
        case let .item(name, _, isDirectory):
            let landing = Self.abbreviated(existing[0])
            if isDirectory {
                alert.messageText = "“\(name)” already exists."
                alert.informativeText = "“\(landing)” is already there. Replace puts back the backed-up versions\(backupOf) of files that differ; Restore Missing Files Only leaves the files there as they are. \(neverRemoved)"
                offersMissingOnly = true
            } else {
                alert.messageText = "Replace “\(name)”?"
                let version = request.backupTime.map { "the version from \(Format.timestamp($0))" } ?? "the backed-up version"
                alert.informativeText = "“\(landing)” already exists and will be replaced with \(version)."
                offersMissingOnly = false
            }
        case .items:
            // What is already there, by name — a count alone would not say
            // which of the selected items Replace is about to touch.
            let names = existing.map { "“\($0.lastPathComponent)”" }
            alert.messageText = existing.count == 1 ? "\(names[0]) already exists." : "\(Format.count(existing.count)) of the items already exist."
            alert.informativeText = "\(names.joined(separator: ", ")) \(existing.count == 1 ? "is" : "are") already where \(existing.count == 1 ? "it" : "they") would be restored. Replace puts back the backed-up versions\(backupOf) of files that differ; Restore Missing Files Only leaves the files there as they are. \(neverRemoved)"
            offersMissingOnly = true
        }
        alert.addButton(withTitle: "Replace")
        if offersMissingOnly { alert.addButton(withTitle: "Restore Missing Files Only") }
        alert.addButton(withTitle: "Cancel")
        // No Return: a folder's or several items' restore writes straight
        // into its landing, so one cut short leaves files that are neither
        // the user's nor the backup's. Keyboard focus starts on Cancel.
        alert.buttons[0].keyEquivalent = ""
        alert.window.initialFirstResponder = alert.buttons[alert.buttons.count - 1]
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .replaceExisting
        case .alertSecondButtonReturn where offersMissingOnly: return .keepExisting
        default: return nil
        }
    }

    private func commit(_ directories: [URL], _ policy: RestoreOverwritePolicy) {
        close()
        request.perform(directories, policy)
    }

    private func close() {
        dismiss()
    }
}
