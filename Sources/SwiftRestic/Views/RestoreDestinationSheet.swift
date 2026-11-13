import AppKit
import SwiftUI

/// One restore waiting for its destination. Every Restore in the app builds
/// one and hands it to `restoreFlow`, so the destination and what to do with
/// what is already there are asked in one place.
struct RestoreDestinationRequest: Identifiable {
    let id = UUID()
    let subject: RestoreSubject
    let route: RestoreDestinationRoute
    /// `restoreFlow`'s look at the original location, carried into the
    /// sheet so it does not look again; nil until something looked.
    var original: OriginalLocation?
    /// A line under the headline about how the selection became the
    /// subject: selected items inside a selected folder, which come with it
    /// (`RestoreBatch.coveredNote`).
    fileprivate var selectionNote: String?
    let backupTime: Date?
    /// How many backups the items come from: Search All Backups restores each row
    /// from the backup it was found in.
    var backupCount = 1
    /// The version's own modified time, when the request came from a row
    /// named by it (a file's versions): the sheet then repeats
    /// the words the user chose by beside the backup the bytes come from.
    var versionModified: Date?
    /// Starts the restore with this policy, into these directories: one per
    /// item, in order (`RestoreSubject.directoryCount`) — the same folder for
    /// all, or for Original location each item's own parent.
    let perform: @MainActor ([URL], RestoreOverwritePolicy) -> Void

    /// Every selection's restore, by one rule and one wording
    /// (`RestoreSelection`): items inside a selected folder of the same
    /// backup are left to it, and the sheet says so, or three selected rows
    /// would read as two. Nil when the picked rows restore nothing.
    @MainActor
    static func picked(
        _ picked: [RestoreSource],
        repositoryID: UUID,
        model: AppModel,
        choosingDestination: Bool = false
    ) -> RestoreDestinationRequest? {
        guard let selection = RestoreSelection(picked) else { return nil }
        let listing = model.snapshots(for: repositoryID)
        let madeOnThisMac = selection.isMadeOnThisMac(
            hostname: { id in listing.first { $0.id == id }?.hostname },
            localHostname: model.localHostname
        )
        return RestoreDestinationRequest(
            subject: selection.subject,
            route: RestoreDestinationRules.route(choosingDestination: choosingDestination, madeOnThisMac: madeOnThisMac),
            selectionNote: selection.note,
            backupTime: selection.backupTime,
            backupCount: selection.backupCount
        ) { directories, overwrite in
            Task { await model.restore(selection, repositoryID: repositoryID, into: directories, overwrite: overwrite) }
        }
    }

    /// The folder panel's message: the item and the backup it comes from.
    fileprivate var panelMessage: String {
        let what = switch subject {
        case let .item(name, _, _): "Restore “\(name)”"
        case let .items(items): "Restore \(Format.plural(items.count, "item"))"
        }
        let backupLine = RestoreSelection.backupLine(
            backupCount: backupCount, backupTime: backupTime, versionModified: versionModified
        )
        return "\(what)\(versionModified == nil ? " " : ", ")\(backupLine)."
    }
}

extension RestoreDestinationRequest {
    /// Names that would land on each other in the one folder chosen, said;
    /// true when there are none and the restore may go on.
    @MainActor
    fileprivate func namesFit(into directories: [URL]) -> Bool {
        let colliding = RestoreDestinationRules.collidingNames(subject, into: directories)
        guard !colliding.isEmpty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "More than one item is named \(colliding.map { "“\($0)”" }.joined(separator: ", "))."
        alert.informativeText = "In one folder they would land on each other. Restore them one at a time, or with Restore, each back where it was."
        alert.addButton(withTitle: "Cancel")
        alert.runModal()
        return false
    }

    /// The policy for a restore into `directories`: what already holds its
    /// landings, looked at off the main actor, then `overwritePolicy`. Nil
    /// is Cancel, the asker's included.
    @MainActor
    fileprivate func overwritePolicy(into directories: [URL]) async -> RestoreOverwritePolicy? {
        let landings = RestoreDestinationRules.landings(for: subject, into: directories)
        let existing = await Task.detached(priority: .userInitiated) {
            RestoreDestinationRules.replaceConfirmationTargets(landings: landings, exists: RestoreDestinationRules.itemExists(at:))
        }.value
        guard !Task.isCancelled, let policy = overwritePolicy(existing: existing), !Task.isCancelled else { return nil }
        return policy
    }

    /// The policy for a restore whose landings `existing` already holds:
    /// keep with nothing in the way — the mode that cannot clobber what
    /// appears between the look and restic's run — else the question's
    /// answer; nil is Cancel.
    @MainActor
    fileprivate func overwritePolicy(existing: [URL]) -> RestoreOverwritePolicy? {
        existing.isEmpty ? .keepExisting : askAboutExisting(existing)
    }

    /// What to do with what is already there; nil is Cancel. "Replace" is
    /// not marked destructive (the user asked for this restore — the HIG's
    /// Empty Trash case), yet no button is the default, the HIG's way to
    /// make people read first. Escape keeps NSAlert's route to "Cancel".
    /// A single file gets no Restore Missing Files Only: keeping it would
    /// restore nothing.
    @MainActor
    private func askAboutExisting(_ existing: [URL]) -> RestoreOverwritePolicy? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let backupOf = backupTime.map { " of \(Format.timestamp($0))" } ?? ""
        let neverRemoved = "Files that aren’t in the backup are never removed."
        let offersMissingOnly: Bool
        switch subject {
        case let .item(name, _, isDirectory):
            let landing = (existing[0].path as NSString).abbreviatingWithTildeInPath
            if isDirectory {
                alert.messageText = "“\(name)” already exists."
                alert.informativeText = "“\(landing)” is already there. Replace puts back the backed-up versions\(backupOf) of files that differ; Restore Missing Files Only leaves the files there as they are. \(neverRemoved)"
                offersMissingOnly = true
            } else {
                alert.messageText = "Replace “\(name)”?"
                let version = backupTime.map { "the version from \(Format.timestamp($0))" } ?? "the backed-up version"
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
}

extension View {
    /// Runs each request set in `request`: Restore puts the items back
    /// where they were, Time Machine's way, asking only when something is in
    /// the way; Restore To… opens the folder panel; the sheet opens only for
    /// another Mac's backup and when the items' own place is not on this
    /// Mac or not writable (`RestoreDestinationRules.route`).
    func restoreFlow(_ request: Binding<RestoreDestinationRequest?>) -> some View {
        modifier(RestoreFlow(request: request))
    }
}

private struct RestoreFlow: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var request: RestoreDestinationRequest?
    @State private var sheetRequest: RestoreDestinationRequest?

    func body(content: Content) -> some View {
        content
            // A request set while one is still being looked at replaces it:
            // the task's id moves on and cancels the look.
            .task(id: request?.id) {
                guard let pending = request else { return }
                await run(pending)
                if request?.id == pending.id { request = nil }
            }
            .sheet(item: $sheetRequest) { request in
                RestoreDestinationSheet(request: request)
                    .environment(model)
            }
    }

    /// Each look at the disk runs off the main actor: the parent may sit on
    /// a stalled network mount, which must not stall the window.
    private func run(_ pending: RestoreDestinationRequest) async {
        switch pending.route {
        case .sheet:
            sheetRequest = pending
        case .folderPanel:
            await restoreIntoChosenFolder(pending)
        case .originalLocation:
            await restoreInPlace(pending)
        }
    }

    /// Restore To… of this Mac's backup: the panel, then the names that
    /// would meet in it, then what is in the way.
    private func restoreIntoChosenFolder(_ pending: RestoreDestinationRequest) async {
        // Run from the main run loop's default mode, not from inside this
        // task: run inside it, the panel's modal session started (the window
        // went disabled) with no panel on screen.
        let message = pending.panelMessage
        let chosen: URL? = await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated {
                    continuation.resume(returning: FilePicker.chooseDirectory(message: message, prompt: "Restore"))
                }
            }
        }
        guard let folder = chosen, !Task.isCancelled else { return }
        let directories = Array(repeating: folder, count: pending.subject.directoryCount)
        guard pending.namesFit(into: directories), let policy = await pending.overwritePolicy(into: directories)
        else { return }
        pending.perform(directories, policy)
    }

    private func restoreInPlace(_ pending: RestoreDestinationRequest) async {
        let subject = pending.subject
        let (original, existing) = await Task.detached(priority: .userInitiated) {
            let original = RestoreDestinationRules.originalLocation(
                for: subject,
                directoryExists: RestoreDestinationRules.directoryExists,
                isWritable: RestoreDestinationRules.isWritable
            )
            guard case let .available(_, landings) = original else { return (original, [URL]()) }
            return (original, RestoreDestinationRules.replaceConfirmationTargets(
                landings: landings,
                exists: RestoreDestinationRules.itemExists(at:)
            ))
        }.value
        guard !Task.isCancelled else { return }
        guard case let .available(directories, _) = original else {
            var withOriginal = pending
            withOriginal.original = original
            sheetRequest = withOriginal
            return
        }
        guard let policy = pending.overwritePolicy(existing: existing), !Task.isCancelled
        else { return }
        pending.perform(directories, policy)
    }
}

/// Another Mac's backup, and Restore when the items' own place is not
/// available: Arq's "Restore to:" window. It opens on the folder (the
/// Desktop until another is chosen). Return, Return (the pane's default
/// action, then this sheet's) never replaces anything: the question's
/// Replace has no Return.
private struct RestoreDestinationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let request: RestoreDestinationRequest
    @State private var kind: RestoreDestinationKind = .folder
    @State private var folder: URL = .desktopDirectory
    /// Nil until the detached check answers: the parent may sit on a
    /// stalled network mount, which must not stall the main actor.
    @State private var original: OriginalLocation?

    init(request: RestoreDestinationRequest) {
        self.request = request
        _original = State(initialValue: request.original)
    }
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
                                .tag(RestoreDestinationKind.folder)
                            Text("Original location")
                                .tag(RestoreDestinationKind.originalLocation)
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
        .task { if original == nil { await checkOriginalLocation() } }
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
        RestoreDestinationRules.collidingNames(request.subject, into: [folder])
    }

    private var directories: [URL]? {
        switch kind {
        case .folder:
            guard collidingNames.isEmpty else { return nil }
            return Array(repeating: folder, count: request.subject.directoryCount)
        case .originalLocation:
            if case let .available(directories, _) = original { return directories } else { return nil }
        }
    }

    @ViewBuilder
    private var detailLine: some View {
        switch kind {
        case .folder:
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
        case .originalLocation:
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
    /// a one-line measure and otherwise cuts a long sentence to one line.
    /// Safe in this sheet, unlike in the window's detail column: the sheet's
    /// fixed width is the only width it is ever asked at.
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

    /// Off the main actor, as `restoreFlow`'s look is.
    private func checkOriginalLocation() async {
        let subject = request.subject
        original = await Task.detached(priority: .userInitiated) {
            RestoreDestinationRules.originalLocation(
                for: subject,
                directoryExists: RestoreDestinationRules.directoryExists,
                isWritable: RestoreDestinationRules.isWritable
            )
        }.value
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
        isConfirming = true
        confirmation = Task {
            defer { isConfirming = false }
            // Cancel pressed while the look ran: nothing starts.
            guard let policy = await request.overwritePolicy(into: directories) else { return }
            commit(directories, policy)
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
