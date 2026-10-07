import AppKit
import SwiftUI

/// One restore waiting for its destination: what, from which backup, and
/// what to run once the sheet has an answer. Every Restore… in the app
/// builds one — the Restore pane's two, Find Files and the Files view's — so
/// the destination and the keep/replace choice are asked in one place.
struct RestoreDestinationRequest: Identifiable {
    let id = UUID()
    let subject: RestoreSubject
    /// The backup's one name (`SnapshotLineage.displayName`), which a
    /// whole-backup restore's header needs; an item restore names the item.
    var backupName: String?
    /// A line under the headline about how the selection became the
    /// subject: selected items inside a selected folder, which come with it
    /// (`RestoreBatch.coveredNote`).
    var selectionNote: String?
    let backupTime: Date?
    let snapshotShortID: String
    /// How many backups the items come from: Find Files restores each row
    /// from the backup it was found in.
    var backupCount = 1
    /// Starts the restore with this policy, into these directories: one per
    /// item, in order (`RestoreSubject.directoryCount`) — the same folder for
    /// all, or for Original location each item's own parent — and one for
    /// an item or a whole backup.
    let perform: @MainActor ([URL], RestoreOverwritePolicy) -> Void

    /// The picked rows' restore — the Restore pane's and the folder-versions
    /// pane's, the same rule both: `RestoreBatch.covering` drops items inside
    /// a selected folder, which the folder brings anyway, and `coveredNote`
    /// says so, or three selected rows would read as two. One item goes the
    /// way a single item always has; nil when the picked rows cover nothing.
    static func picked(
        _ picked: [SnapshotNode],
        repositoryID: UUID,
        snapshotID: String,
        snapshotShortID: String,
        backupTime: Date,
        model: AppModel
    ) -> RestoreDestinationRequest? {
        let nodes = RestoreBatch.covering(picked)
        let note = RestoreBatch.coveredNote(RestoreBatch.covered(picked))
        guard let first = nodes.first else { return nil }
        guard nodes.count > 1 else {
            return RestoreDestinationRequest(
                subject: .item(name: first.name, path: first.path, isDirectory: first.isDirectory),
                selectionNote: note,
                backupTime: backupTime,
                snapshotShortID: snapshotShortID
            ) { directories, overwrite in
                model.restore(
                    repositoryID: repositoryID,
                    snapshotID: snapshotID,
                    node: first,
                    to: directories[0],
                    overwrite: overwrite
                )
            }
        }
        return RestoreDestinationRequest(
            subject: .items(nodes.map { RestoreItem(name: $0.name, path: $0.path, isDirectory: $0.isDirectory) }),
            selectionNote: note,
            backupTime: backupTime,
            snapshotShortID: snapshotShortID
        ) { directories, overwrite in
            model.restore(
                repositoryID: repositoryID,
                snapshotID: snapshotID,
                items: zip(nodes, directories).map { (node: $0, directory: $1) },
                overwrite: overwrite
            )
        }
    }
}

/// Arq's "Restore to:" window, with our item-and-backup wording kept:
/// Desktop, another folder or the item's original location, a live line
/// saying exactly where it lands, and what happens to files already there.
///
/// Keep is the default every time the sheet opens and is never remembered,
/// so Return, Return (the pane's default action, then this sheet's) never
/// replaces anything because of an earlier session. Desktop or Other folder
/// is remembered — only on a Restore press, and only when it changed, so
/// radio flicks and Cancel write nothing and a launch seeded through the
/// argument domain writes nothing either. Original location never is.
struct RestoreDestinationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let request: RestoreDestinationRequest

    @State private var kind: RestoreDestinationKind
    @State private var otherFolder: URL?
    @State private var policy: RestoreOverwritePolicy = .keepExisting
    /// Nil until the detached check answers: the parent may sit on a
    /// stalled network mount, which must not stall the main actor.
    @State private var original: OriginalLocation?
    /// A remembered folder is shown only once it is known to still exist:
    /// restoring into a vanished one would recreate its path (under
    /// /Volumes, for an unmounted disk).
    @State private var otherFolderChecked: Bool
    /// The Replace pre-check or its alert is up.
    @State private var isConfirming = false
    /// The Replace pre-check, which Cancel and the sheet's closing stop: a
    /// look at a stalled mount can outlast the user's patience, and a
    /// cancelled sheet must not start a restore when the look returns.
    @State private var confirmation: Task<Void, Never>?

    static let kindKey = "RestoreDestinationKind"
    static let folderKey = "RestoreOtherFolderPath"

    init(request: RestoreDestinationRequest) {
        self.request = request
        let defaults = UserDefaults.standard
        let remembered = defaults.string(forKey: Self.kindKey).flatMap(RestoreDestinationKind.init(rawValue:))
        _kind = State(initialValue: remembered == .otherFolder ? .otherFolder : .desktop)
        let folder = defaults.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        _otherFolder = State(initialValue: folder)
        _otherFolderChecked = State(initialValue: folder == nil)
    }

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
                Picker("Restore to:", selection: $kind) {
                    Text("Desktop").tag(RestoreDestinationKind.desktop)
                    Text("Other folder").tag(RestoreDestinationKind.otherFolder)
                    Text("Original location").tag(RestoreDestinationKind.originalLocation)
                }
                .pickerStyle(.radioGroup)

                LabeledContent {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        detailLine
                        Spacer(minLength: 4)
                        // Beside the Other folder line only: the other lines
                        // are paths and sentences that need the width.
                        if kind == .otherFolder {
                            Button("Choose…") { chooseFolder() }
                                .controlSize(.small)
                                .help("Pick the folder to restore into")
                        }
                    }
                } label: {
                    // The row belongs to the picker above; no label of its own.
                    Text(verbatim: "")
                        .accessibilityHidden(true)
                }

                Picker("If a file already exists:", selection: $policy) {
                    Text("Keep the existing file").tag(RestoreOverwritePolicy.keepExisting)
                    Text("Replace it with the backed-up version").tag(RestoreOverwritePolicy.replaceExisting)
                }
                .pickerStyle(.radioGroup)

                LabeledContent {
                    // True in both modes: restore never runs with --delete.
                    Text("Files that aren't in the backup are never removed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } label: {
                    Text(verbatim: "")
                        .accessibilityHidden(true)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    confirmation?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Restore") { restore() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(directories == nil || model.isRestoring || isConfirming)
            }
        }
        .padding(20)
        .frame(width: 460)
        // Two looks, each answering on its own: a stalled mount under the
        // item's original parent must not hold up the remembered folder's
        // Restore, nor the other way round.
        .task { await checkOriginalLocation() }
        .task { await checkRememberedFolder() }
        .onDisappear { confirmation?.cancel() }
    }

    // MARK: - Wording

    private var itemName: String? {
        if case let .item(name, _, _) = request.subject { return name }
        return nil
    }

    /// The several items, when there are several.
    private var items: [RestoreItem]? {
        if case let .items(items) = request.subject { return items }
        return nil
    }

    private var headline: String {
        if let itemName { return "Restore “\(itemName)”" }
        if let items { return "Restore \(Format.plural(items.count, "item"))" }
        return request.backupName.map { "Restore the whole “\($0)” backup" } ?? "Restore the whole backup"
    }

    private var backupLine: String {
        if request.backupCount > 1 { return "from \(Format.count(request.backupCount)) backups, each item from the one it was found in" }
        return request.backupTime.map { "from \(Format.timestamp($0))" } ?? "from backup \(request.snapshotShortID)"
    }

    /// The name the folder panel and the alerts use for what is restored.
    private var subjectName: String {
        if let itemName { return "“\(itemName)”" }
        if let items { return "the \(Format.plural(items.count, "item"))" }
        return request.backupName.map { "the whole “\($0)” backup" } ?? "the whole backup"
    }

    /// Selected items that would land on each other in one folder — the
    /// same name from two folders of the backup (`RestoreBatch`). Original
    /// location puts each back in its own folder, where no two can meet.
    private var collidingNames: [String] {
        items.map { RestoreBatch.collidingNames($0.map(\.name)) } ?? []
    }

    /// The folder Desktop or Other folder names right now, nil until there is
    /// one (none chosen, the remembered one not yet checked).
    private var chosenFolder: URL? {
        switch kind {
        case .desktop: Self.desktop
        case .otherFolder: otherFolderChecked ? otherFolder : nil
        case .originalLocation: nil
        }
    }

    /// Where a restore would go right now — one directory per item
    /// (`RestoreDestinationRequest.perform`) — or nil when the choice cannot
    /// be used yet: no folder, not checked, not available, or two items that
    /// would land on each other in it.
    private var directories: [URL]? {
        switch kind {
        case .desktop, .otherFolder:
            guard let chosenFolder, collidingNames.isEmpty else { return nil }
            return Array(repeating: chosenFolder, count: request.subject.directoryCount)
        case .originalLocation:
            if case let .available(directories, _) = original { return directories } else { return nil }
        }
    }

    @ViewBuilder
    private var detailLine: some View {
        switch kind {
        case .desktop, .otherFolder:
            if kind == .otherFolder, !otherFolderChecked {
                caption("Checking…")
            } else if !collidingNames.isEmpty {
                // A sentence, not a path: what is in the way, and the two
                // ways around it.
                caption("More than one selected item is named \(collidingNames.map { "“\($0)”" }.joined(separator: ", ")) — in one folder they would land on each other. Restore them one at a time, or to their original locations.")
            } else if let folder = chosenFolder {
                let landing = RestoreDestinationRules.landings(for: request.subject, into: [folder]).first ?? folder
                if itemName != nil {
                    pathCaption("Will restore to \(Self.abbreviated(landing))", fullPath: landing.path)
                } else if let items {
                    pathCaption("Will restore the \(Format.plural(items.count, "item")) into \(Self.abbreviated(folder))", fullPath: folder.path)
                } else {
                    // The path truncates and the sentence wraps: one line at
                    // this width cuts both to fragments.
                    VStack(alignment: .leading, spacing: 2) {
                        pathCaption("Will restore into \(Self.abbreviated(folder))", fullPath: folder.path)
                        caption("Each backed-up folder is recreated under its full original path inside it.")
                    }
                }
            } else {
                caption("No folder chosen")
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
    /// a one-line measure and otherwise cuts the whole-backup sentence to
    /// one line. Safe in this sheet, unlike in the window's detail column:
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

    private static var desktop: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    private static func abbreviated(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Actions

    /// Whether the item can go back where it was — off the main actor,
    /// like the remembered folder's look below.
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

    /// Whether the remembered Other folder is still there.
    private func checkRememberedFolder() async {
        guard let folderPath = otherFolder?.path, !otherFolderChecked else { return }
        let folderExists = await Task.detached(priority: .userInitiated) {
            RestoreDestinationRules.directoryExists(folderPath)
        }.value
        // A folder chosen while the check ran is the user's answer, not the
        // remembered one's.
        guard otherFolder?.path == folderPath, !otherFolderChecked else { return }
        if !folderExists { otherFolder = nil }
        otherFolderChecked = true
    }

    private func chooseFolder() {
        guard let url = FilePicker.chooseDirectory(
            message: "Choose where to restore \(subjectName)",
            directoryURL: otherFolder ?? Self.desktop
        ) else { return }
        otherFolder = url
        otherFolderChecked = true
        kind = .otherFolder
    }

    /// Keep starts at once. Replace first looks at what is actually at the
    /// landings (off the main actor) and asks only when something is there.
    private func restore() {
        guard let directories else { return }
        // The choice as pressed: the radios stay live while Replace looks.
        let chosen = policy
        let chosenKind = kind
        guard chosen == .replaceExisting else {
            commit(directories, chosen, kind: chosenKind)
            return
        }
        let landings = RestoreDestinationRules.landings(for: request.subject, into: directories)
        isConfirming = true
        confirmation = Task {
            let existing = await Task.detached(priority: .userInitiated) {
                RestoreDestinationRules.replaceConfirmationTargets(
                    policy: chosen,
                    landings: landings,
                    exists: RestoreDestinationRules.itemExists(at:)
                )
            }.value
            defer { isConfirming = false }
            // Cancel pressed while the look ran: nothing starts, and
            // nothing is remembered.
            guard !Task.isCancelled else { return }
            guard existing.isEmpty || confirmReplace(existing, in: directories[0]) else { return }
            guard !Task.isCancelled else { return }
            commit(directories, chosen, kind: chosenKind)
        }
    }

    /// NSAlert rather than a SwiftUI alert so the safe button provably owns
    /// Return — the quit alert's pattern: "Replace" is marked destructive,
    /// "Cancel" takes Return, and Escape keeps its built-in route to Cancel.
    private func confirmReplace(_ existing: [URL], in destination: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let backupOf = request.backupTime.map { " of \(Format.timestamp($0))" } ?? ""
        switch request.subject {
        case let .item(name, _, isDirectory):
            let landing = Self.abbreviated(existing[0])
            if isDirectory {
                alert.messageText = "Replace files in “\(name)”?"
                alert.informativeText = "“\(landing)” already exists. Files in it that differ from the backup\(backupOf) will be replaced with the backed-up versions. Files that aren't in the backup stay as they are."
            } else {
                alert.messageText = "Replace “\(name)”?"
                let version = request.backupTime.map { "the version from \(Format.timestamp($0))" } ?? "the backed-up version"
                alert.informativeText = "“\(landing)” already exists and will be replaced with \(version)."
            }
        case .items:
            // What is already there, by name — a count alone would not say
            // which of the selected items Replace is about to touch.
            let names = existing.map { "“\($0.lastPathComponent)”" }
            alert.messageText = existing.count == 1 ? "Replace \(names[0])?" : "Replace \(Format.count(existing.count)) existing items?"
            alert.informativeText = "\(names.joined(separator: ", ")) \(existing.count == 1 ? "is" : "are") already where \(existing.count == 1 ? "it" : "they") would be restored. Files that differ from the backup\(backupOf) will be replaced with the backed-up versions; files that aren't in the backup stay as they are."
        case .wholeSnapshot:
            alert.messageText = "Replace existing files?"
            let folders = existing.count == 1
                ? "1 of the backup's folders already exists"
                : "\(Format.count(existing.count)) of the backup's folders already exist"
            alert.informativeText = "\(folders) in “\(Self.abbreviated(destination))”. Files in them that differ from the backup will be replaced; files that aren't in the backup stay as they are."
        }
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[1].keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func commit(_ directories: [URL], _ policy: RestoreOverwritePolicy, kind: RestoreDestinationKind) {
        remember(kind, folder: directories[0])
        dismiss()
        request.perform(directories, policy)
    }

    /// Desktop or Other folder, written only when it differs from what the
    /// defaults already answer (the argument domain included).
    private func remember(_ kind: RestoreDestinationKind, folder: URL) {
        guard kind != .originalLocation else { return }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.kindKey) != kind.rawValue {
            defaults.set(kind.rawValue, forKey: Self.kindKey)
        }
        if kind == .otherFolder, defaults.string(forKey: Self.folderKey) != folder.path {
            defaults.set(folder.path, forKey: Self.folderKey)
        }
    }
}
