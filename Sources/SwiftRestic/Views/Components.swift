import AppKit
import SwiftUI
import UniformTypeIdentifiers


/// Banners built in place (rather than posted to the queue) have nothing to
/// dismiss, so they hide the close button.
///
/// Banners keep their icons by rule, where run lists and tiles drop theirs:
/// a banner is action feedback — success ones dismiss themselves within
/// seconds, and a persistent error banner *is* the intervention marker —
/// so neither is ambient decoration competing for attention. The glyph is
/// bare: colouring a plate behind it is the one ornament the interface
/// grammar elsewhere refuses.
struct BannerView: View {
    @Environment(AppModel.self) private var model
    let banner: Banner
    var isDismissible = true

    /// The status palette's glyph and hue for the banner's level, so a
    /// colour means one thing app-wide: a failure's red octagon and a
    /// warning's orange triangle are Activity's and the sidebar's for a run
    /// that failed or completed with warnings.
    private var hue: Color {
        switch banner.level {
        case .error: StatusPalette.status(.failed)
        case .warning: StatusPalette.status(.completedWithErrors)
        case .success, .notice: .secondary
        }
    }
    private var symbol: String {
        switch banner.level {
        case .error: RunRecord.Outcome.failed.symbolName!
        case .warning: RunRecord.Outcome.completedWithErrors.symbolName!
        case .success: "checkmark.circle.fill"
        case .notice: banner.symbolName ?? "info.circle"
        }
    }
    /// Named for what it means — not every error's title says it failed
    /// ("Keychain") — and silent for success and news, whose titles say it.
    private var symbolLabel: String? {
        switch banner.level {
        case .error: "Error"
        case .warning: "Warning"
        case .success, .notice: nil
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // The success check is decoration beside a title that already
            // says what happened, and its SF label read "Selected" to
            // VoiceOver.
            Image(systemName: symbol)
                .imageScale(.large)
                .foregroundStyle(hue)
                .accessibilityLabel(symbolLabel ?? "")
                .accessibilityHidden(symbolLabel == nil)
            // Title and message read as one utterance; the Show in Finder action and
            // the dismiss button stay their own elements beside them.
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(banner.title).font(.headline)
                    if !banner.message.isEmpty {
                        // Never fixedSize(vertical:): the split view asks its
                        // detail column for a minimum size at zero width, where
                        // a height-pinned message wraps to about a character
                        // per line, and the non-scrolling hosts (Activity, the
                        // console, the Restore pane, the damaged-install strip)
                        // then lay out thousands of points taller than the
                        // window and render blank.
                        Text(banner.message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .combine)
                if !banner.revealPaths.isEmpty {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(banner.revealPaths.map { URL(fileURLWithPath: $0) })
                    }
                    .controlSize(.small)
                }
                // The fix as a button, where the words would only say
                // where it is.
                if let link = banner.link {
                    Button(link.title) { NSWorkspace.shared.open(link.url) }
                        .controlSize(.small)
                }
            }
            Spacer()
            if isDismissible {
                Button {
                    model.dismiss(banner)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// `.help` only when there is text to show; an empty tooltip would still hit.
struct TileHelp: ViewModifier {
    let help: String?

    func body(content: Content) -> some View {
        if let help {
            content.help(help)
        } else {
            content
        }
    }
}

/// A repository's folder or a plan's folder on a network share: which
/// share, and the password SwiftRestic reconnects it with before a backup
/// when it is not mounted (`NetworkShare`). Rows, so a Form lays them out
/// as its own and a stack stacks them. A secure field reads back empty, so
/// a saved password shows in the prompt, and an empty field leaves it as
/// it is.
struct NetworkSharePasswordRows: View {
    let url: String
    let isSaved: Bool
    @Binding var password: String

    var body: some View {
        Label {
            Text("On the network share \(url)")
                .lineLimit(1)
                .truncationMode(.middle)
                .help(url)
        } icon: {
            Image(systemName: "network")
        }
        // Labelled in a stack as in a Form: a bare field outside a Form
        // shows only its prompt.
        LabeledContent("Share password") {
            SecureField("Share password", text: $password, prompt: Text(isSaved ? "Saved in Keychain" : "Optional"))
                .labelsHidden()
        }
        Text(isSaved
            ? "When the share isn’t mounted, SwiftRestic reconnects it as needed. Type a password to replace the saved one."
            : "When the share isn’t mounted, SwiftRestic reconnects it as needed.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}


/// A form caption whose teaching text sits behind an info button: the
/// summary line is always visible, the rest for whoever wants it — the
/// same on-demand depth the app gives hook variables and diff metadata.
struct ExpandableCaption: View {
    let summary: String
    /// What reveals on demand; written to read continuously after the summary.
    let detail: String

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // The macOS minimum control size, 20×20, without growing the
                // caption line: the square hangs 4 pt past its layout box
                // above and below. The padding sits outside the Button —
                // inside the label, the Button hit-tests only the 20×12 box
                // (macOS 26).
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .padding(.vertical, -4)
                .foregroundStyle(.secondary)
                .help("More about this")
                .accessibilityLabel("More about this")
            }
            if isExpanded {
                // Not height-pinned, for BannerView's reason: the console
                // hosts this caption outside any scroll view.
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

struct OperationProgressView: View {
    let title: String
    let progress: OperationProgress
    let startedAt: Date?
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                Spacer()
                if let onCancel {
                    Button("Stop", action: onCancel)
                        .controlSize(.small)
                }
            }

            // Indeterminate until restic reports numbers: a determinate
            // bar parked at 0% does not move and reads as stalled.
            if progress == OperationProgress() {
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityLabel(Text(title))
            } else {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .accessibilityLabel(Text(title))
            }

            // Once restic has reported any numbers: before that — a plan's
            // before-backup hooks, restic starting up — the title already
            // says what is happening.
            if let caption = Self.caption(progress) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    /// "1.2 GB of 3.4 GB — about 4 minutes left", each part only when
    /// restic has said it.
    static func caption(_ progress: OperationProgress) -> String? {
        guard progress != OperationProgress() else { return nil }
        var parts: [String] = []
        if progress.totalBytes > 0 {
            parts.append("\(Format.bytes(progress.bytesDone)) of \(Format.bytes(progress.totalBytes))")
        } else if progress.bytesDone > 0 {
            parts.append(Format.bytes(progress.bytesDone))
        }
        if let remaining = progress.secondsRemaining, remaining > 0 {
            let time = Duration.seconds(remaining)
                .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 1))
            parts.append("about \(time) left")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }
}


/// Orange on the glyph only, the words secondary — the contrast rule the
/// sidebar's captions follow.
struct WarningLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}


/// Why a Snapshots value may read "—", in visible text: under the plan page's
/// Backups section, and as the repository page's Status section body. The tooltips carry the same
/// lines, but a reason only a hovering mouse user can reach is no reason at
/// all for a keyboard or VoiceOver user.
struct SnapshotListingCaveat: View {
    let outcome: SnapshotListingOutcome

    var body: some View {
        switch outcome {
        case let .failed(message, fix):
            // The glyph carries the alarm and the words stay secondary:
            // a warning-coloured sentence at caption size is too
            // low-contrast to read. The whole message, where the rows have
            // one line: its second sentence says what to do.
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("Can’t read backups — \(message)")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                }
                .font(.caption)
                if let fix {
                    RunFixButton(fix: fix)
                        .controlSize(.small)
                }
            }
        case .idle:
            Label(OverviewMetrics.listingIdleText, systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .loaded:
            EmptyView()
        }
    }
}

/// A snapshot's completeness, where snapshots are named (a page's
/// Backups tab, Activity's run drawer). Only trouble wears a glyph — the rule
/// Activity's outcome column follows — and it is the completed-with-errors
/// triangle, because that is what the run behind it was. A known-complete
/// snapshot keeps an invisible "Complete" for VoiceOver; one with no run
/// record here makes no claim at all. The caller's fixed-width slot lines
/// neighbouring text up whether or not a glyph shows.
///
/// The invisible label is clear ink, as in Activity's outcome column: on
/// macOS 26 a zero-opacity Text or Image is dropped from the accessibility
/// tree in both a List row and a Table cell, and in a sidebar row it
/// folds into the timestamp beside it, label lost. A clear Text survives
/// as its own static text in both.
struct SnapshotCompletenessMark: View {
    let run: RunRecord?

    private static let outcome = RunRecord.Outcome.completedWithErrors
    private static let symbolName = outcome.symbolName!

    var body: some View {
        switch run?.snapshotCompleteness {
        case .incomplete?:
            let label = Format.snapshotCompleteness(run) ?? ""
            Image(systemName: Self.symbolName)
                .foregroundStyle(StatusPalette.status(Self.outcome))
                .help(label)
                .accessibilityLabel(label)
        case .complete?:
            Text("Complete")
                .foregroundStyle(.clear)
                .lineLimit(1)
                .accessibilityLabel("Complete")
        case .unknown?, nil:
            // Holds the slot — an empty branch would collapse it, and the
            // row's text would shift left of its neighbours'.
            Image(systemName: Self.symbolName)
                .hidden()
        }
    }
}

/// Finder's icon for a kind of item. By type, not by path: what a backup holds
/// need not be on this Mac. Cached per type, since a row re-renders on every
/// scroll and `NSWorkspace` is not free.
struct FileKindIcon: View {
    let type: UTType
    var size: CGFloat = 16

    @MainActor private static var icons: [String: NSImage] = [:]

    @MainActor private static func icon(for type: UTType) -> NSImage {
        if let icon = icons[type.identifier] { return icon }
        let icon = NSWorkspace.shared.icon(for: type)
        icons[type.identifier] = icon
        return icon
    }

    var body: some View {
        Image(nsImage: Self.icon(for: type))
            .resizable()
            .frame(width: size, height: size)
    }
}

extension UTType {
    static func backedUp(name: String, isDirectory: Bool) -> UTType {
        if isDirectory { return .folder }
        return UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
    }
}

extension SnapshotNode {
    var iconType: UTType {
        switch type {
        case .dir: .folder
        case .symlink: .symbolicLink
        case .file: .backedUp(name: name, isDirectory: false)
        default: .item
        }
    }

    /// The icon's meaning, for VoiceOver.
    var kindName: String {
        switch type {
        case .dir: "Folder"
        case .symlink: "Symbolic link"
        case .file: "File"
        default: "Special file"
        }
    }
}

/// A list of paths with add/remove buttons: a plan's exclude patterns. A row
/// is edited in place, as Finder renames: double-click or Return on it, or
/// Edit in its menu; Return or a click away keeps the edit, Escape drops it.
///
/// Typing, pasting and dropping are first-class: the audience keeps paths on
/// the clipboard, and an NSOpenPanel per entry is the app's biggest
/// efficiency tax.
struct PathListEditor: View {
    let title: String
    @Binding var paths: [String]
    var placeholder = "Add a pattern"
    var browseMessage = "Choose folders and files to exclude from backups"
    var browsePrompt = "Add"
    /// Excludes: an item chosen in the panel or dropped from Finder is
    /// entered as its own path, matching itself alone (`PathListEntry`).
    var escapesPickedGlobs = false

    @State private var selection: Set<String> = []
    @State private var draft = ""
    @State private var isDropTargeted = false
    /// The row being edited in place, its text so far, and its value
    /// before the edit, which Escape puts back.
    @State private var editing: Int?
    @State private var editDraft = ""
    @State private var editOriginal = ""

    /// About six one-line rows: the list scrolls past them rather than
    /// pushing the switches off the sheet.
    private static let listHeight: CGFloat = 132

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                // By position, not value: the edited row's value changes per
                // keystroke, and a new identity would drop the field's focus.
                ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                    if editing == index {
                        RowEditField(
                            text: editDraft,
                            accessibilityLabel: title,
                            onChange: {
                                editDraft = $0
                                paths = PathListEntry.typing($0, at: index, original: editOriginal, in: paths)
                                // The row's tag is its value: keep it selected.
                                selection = [paths[index]]
                            },
                            onSubmit: commitEdit,
                            onCancel: cancelEdit,
                            onEnd: commitEdit
                        )
                        .tag(path)
                    } else {
                        Text(path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                            .tag(path)
                    }
                }
            }
            .contextMenu(forSelectionType: String.self) { items in
                if items.count == 1, let path = items.first {
                    Button("Edit") { startEditing(path) }
                }
                Button("Remove") { remove(items) }
            } primaryAction: { items in
                guard items.count == 1, let path = items.first else { return }
                startEditing(path)
            }
            .listStyle(.plain)
            .alternatingRowBackgrounds()
            .environment(\.defaultMinListRowHeight, 22)
            .overlay {
                if paths.isEmpty {
                    Text("Drag folders and files here, or click +.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: Self.listHeight)
            .dropDestination(for: URL.self) { urls, _ in
                // Only file URLs are paths: a dragged web link's `.path`
                // would silently become a pattern matching nothing.
                let filePaths = urls.filter(\.isFileURL).map(\.path)
                guard !filePaths.isEmpty else { return false }
                addPaths(filePaths, picked: true)
                return true
            } isTargeted: { isDropTargeted = $0 }
            Divider()
            // + chooses items in a panel, as Time Machine's exclusions do;
            // a pattern is typed into the bar's field beside it.
            HStack(spacing: 0) {
                ListBarButton(symbol: "plus", title: "Choose items") { browse() }
                    .accessibilityIdentifier(AccessibilityID.PathList.add)
                Divider()
                    .frame(height: 14)
                ListBarButton(symbol: "minus", title: "Remove") { remove(selection) }
                .disabled(selection.isEmpty)
                Divider()
                    .frame(height: 14)
                // The placeholder is a prompt, not a label: inside a form a
                // title would stand beside the field as a row's label.
                TextField(text: $draft, prompt: Text(placeholder)) { Text(title) }
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .onSubmit(addDraft)
                Button("Add", action: addDraft)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .padding(.trailing, 6)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.leading, 2)
            .frame(height: 26)
        }
        .overlay {
            if isDropTargeted {
                Rectangle().strokeBorder(Theme.tint, lineWidth: 2)
            }
        }
    }

    private func addDraft() {
        addPaths([draft], picked: false)
        draft = ""
    }

    private func remove(_ items: Set<String>) {
        // − takes no focus, so the edit is still open; its row's position
        // is about to move.
        commitEdit()
        paths.removeAll { items.contains($0) }
        selection.subtract(items)
    }

    private func startEditing(_ path: String) {
        guard let index = paths.firstIndex(of: path) else { return }
        editDraft = path
        editOriginal = path
        editing = index
    }

    private func commitEdit() {
        guard let index = editing else { return }
        editing = nil
        let finished = PathListEntry.value(for: editDraft, expandsTildeInPath: false, escapesGlobs: false)
        paths = PathListEntry.finishing(editDraft, at: index, in: paths)
        selection = [finished ?? editOriginal]
    }

    private func cancelEdit() {
        guard let index = editing else { return }
        editing = nil
        paths[index] = editOriginal
        selection = [editOriginal]
    }

    /// `picked`: the paths came from the panel or a drop, not the field.
    private func addPaths(_ rawPaths: [String], picked: Bool) {
        for raw in rawPaths {
            // Stored as typed, `~` and all: the run expands it
            // (`ResticService.backup`).
            guard let value = PathListEntry.value(
                for: raw,
                expandsTildeInPath: false,
                escapesGlobs: picked && escapesPickedGlobs
            ), !paths.contains(value) else { continue }
            paths.append(value)
        }
    }

    private func browse() {
        guard let chosen = FilePicker.chooseFoldersAndFiles(message: browseMessage, prompt: browsePrompt) else { return }
        addPaths(chosen.map(\.path), picked: true)
    }
}

struct ListBarButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }
}

extension View {
    /// The editors' on/off settings: mini switches in a grouped form,
    /// the HIG's "consider using a mini switch to control the setting in a
    /// single row", the same on every tab.
    func editorSwitches() -> some View {
        toggleStyle(.switch).controlSize(.mini)
    }
}

/// Thin wrapper over `NSOpenPanel`, which SwiftUI's `fileImporter` cannot fully
/// replace here (we need multi-select across both files and folders).
enum FilePicker {
    @MainActor
    static func chooseFoldersAndFiles(message: String, prompt: String) -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = message
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.urls : nil
    }

    @MainActor
    static func chooseFolderOrFile(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.urls.first : nil
    }

    /// `directoryURL` is where the panel opens; nil leaves it to AppKit's
    /// own memory of the last folder.
    @MainActor
    static func chooseDirectory(message: String, directoryURL: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = "Choose"
        if let directoryURL { panel.directoryURL = directoryURL }
        return panel.runModal() == .OK ? panel.urls.first : nil
    }

    @MainActor
    static func chooseFile(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.urls.first : nil
    }
}

/// The one way to the grant, wherever the app asks for it. The grant
/// cannot be requested by prompt, so the list in System Settings is where
/// it happens.
struct FullDiskAccessButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Open Full Disk Access Settings") { model.openFullDiskAccessSettings() }
    }
}

/// What to do about a run's unreadable items: macOS's privacy protection,
/// with the grant's button while it is still missing, then the files' own
/// permissions, which the grant does not change. Nothing for a run whose
/// items say neither. The words are `ItemErrorDiagnosis`'s, the same the
/// banner, the notification and the channels carry; the hints take the
/// current access state, so a fresh grant turns "grant it" into "back up
/// again". The two the grant does not fix carry Exclude These Items when it
/// covers every item they count (`ItemErrorDiagnosis.excludablePaths`),
/// asked first as a line's Exclude is. No Back Up Now on "back up again":
/// the plan page's Backups section and the drawer's footer hold it wherever
/// the plan can back up.
struct ItemErrorHintsView: View {
    @Environment(AppModel.self) private var model
    let run: RunRecord
    /// The paths the confirmation names, fixed at the click.
    @State private var excluding: [String] = []
    @State private var isConfirmingExclude = false

    var body: some View {
        let hints = ItemErrorDiagnosis.hints(for: run, accessNow: model.fullDiskAccess)
        let plan = run.planID.flatMap { model.plan(id: $0) }
        if !hints.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                    let paths = plan == nil ? [] : ItemErrorDiagnosis.excludablePaths(for: hint, in: run)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // Decoration beside a sentence that says it all.
                        Image(systemName: Self.symbolName(for: hint))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(ItemErrorDiagnosis.detail(hint, offersExclude: !paths.isEmpty))
                            .textSelection(.enabled)
                    }
                    .font(.callout)
                    if case .grantFullDiskAccess = hint {
                        FullDiskAccessButton()
                            .controlSize(.small)
                    }
                    if let plan, !paths.isEmpty {
                        excludeButton(hint: hint, paths: paths, plan: plan)
                    }
                }
            }
            .confirmationDialog(
                "Exclude \(Format.plural(excluding.count, "item")) from “\(plan.map { model.label(of: $0) } ?? "")”?",
                isPresented: $isConfirmingExclude,
                titleVisibility: .visible
            ) {
                if let plan {
                    Button("Exclude") { model.exclude(paths: excluding, fromPlan: plan.id) }
                }
            } message: {
                Text(excluding.count == 1
                    ? "The plan’s next backups exclude it — backups already made keep it. The plan editor lists it under Exclude, where − takes it out again."
                    : "The plan’s next backups exclude them — backups already made keep them. The plan editor lists them under Exclude, where − takes each out again.")
            }
        }
    }

    /// Disabled once the plan skips every one of them, as a line's Exclude
    /// is. Two can share a row, so VoiceOver hears each by its cause;
    /// Voice Control still answers to the title on screen.
    private func excludeButton(hint: ItemErrorDiagnosis.Hint, paths: [String], plan: BackupPlan) -> some View {
        let pending = paths.filter { !plan.excludePatterns.contains(ResticService.globEscaped($0)) }
        let title = "Exclude These Items"
        let label = Self.excludeLabel(for: hint)
        return Button(title) {
            excluding = pending
            isConfirmingExclude = true
        }
        .controlSize(.small)
        .disabled(pending.isEmpty)
        .modifier(TileHelp(help: pending.isEmpty ? "“\(model.label(of: plan))” already excludes these items" : nil))
        .accessibilityLabel(label)
        .accessibilityInputLabels([title, label])
    }

    private static func excludeLabel(for hint: ItemErrorDiagnosis.Hint) -> String {
        switch hint {
        case .grantFullDiskAccess, .retryNowGranted, .protectedEvenWithAccess: "Exclude the items macOS blocked"
        case .filePermissions: "Exclude the items your account can’t read"
        }
    }

    private static func symbolName(for hint: ItemErrorDiagnosis.Hint) -> String {
        switch hint {
        case .grantFullDiskAccess, .retryNowGranted, .protectedEvenWithAccess: "lock.shield"
        case .filePermissions: "person.crop.circle.badge.exclamationmark"
        }
    }
}

/// One unreadable item's line — in Activity's drawer and on the plan
/// page's problem row — with the two fixes the diagnosis above it names,
/// Show in Finder and Exclude from the plan, in a menu at its end and in
/// its context menu. Only where restic named the
/// item's path and the run stored it (`RunRecord.unreadableItemPaths`); older
/// records' lines stay plain text. Exclude asks first: it changes what the
/// plan backs up from now on.
struct UnreadableItemLine: View {
    @Environment(AppModel.self) private var model
    let run: RunRecord
    let line: String
    /// Nil until the check lands; Show in Finder waits disabled until then.
    @State private var existence = PathExistence()
    @State private var isConfirmingExclude = false

    var body: some View {
        let path = run.unreadableItemPaths?[PathKey(line)]
        let plan = run.planID.flatMap { model.plan(id: $0) }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // By name, where and why; restic's whole line in the tooltip,
            // Copy Details and the log. A line with no stored path stays
            // restic's own.
            if let words = RunRecordPresentation.unreadableItemWords(line: line, path: path, sources: plan.map { [$0.path] } ?? []) {
                VStack(alignment: .leading, spacing: 1) {
                    (Text(words.name) + Text(" — \(words.reason)").foregroundStyle(.secondary))
                        .font(.callout)
                    Text(words.location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .textSelection(.enabled)
                .help(line)
            } else {
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let path {
                Spacer(minLength: 4)
                Menu {
                    actions(path: path, plan: plan)
                } label: {
                    // Named by the item, so VoiceOver tells one line's menu
                    // from the next.
                    Label("Actions for \((path as NSString).lastPathComponent)", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Show this item in Finder, or exclude it from the plan")
            }
        }
        .contextMenu {
            if let path { actions(path: path, plan: plan) }
        }
        .confirmationDialog(
            "Exclude “\(path.map { ($0 as NSString).lastPathComponent } ?? "")” from “\(plan.map { model.label(of: $0) } ?? "")”?",
            isPresented: $isConfirmingExclude,
            titleVisibility: .visible
        ) {
            if let path, let plan {
                Button("Exclude") { model.exclude(paths: [path], fromPlan: plan.id) }
            }
        } message: {
            Text("The plan’s next backups exclude \(path ?? "") — backups already made keep it. The plan editor lists it under Exclude, where − takes it out again.")
        }
        .task(id: path) {
            await existence.check(path)
        }
    }

    @ViewBuilder
    private func actions(path: String, plan: BackupPlan?) -> some View {
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        .disabled(existence.exists != true)
        if let plan {
            Button("Exclude from “\(model.label(of: plan))”") { isConfirmingExclude = true }
                .disabled(plan.excludePatterns.contains(ResticService.globEscaped(path)))
        }
    }
}

/// Where a search looks: this plan, or everything. Finder's search scope, in
/// the two places a search shows its results. Picking the other one hands the
/// query over.
struct SearchScopePicker: View {
    enum Scope: Hashable {
        case thisPlan
        case allBackups
    }

    let scope: Scope
    let onChange: () -> Void

    var body: some View {
        Picker("Search", selection: Binding(
            get: { scope },
            set: { if $0 != scope { onChange() } }
        )) {
            Text("This Plan").tag(Scope.thisPlan)
            Text("All Backups").tag(Scope.allBackups)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// A broken search index's failure, with its way out. Nothing the index
/// answered can be trusted as "nothing matches" while this stands.
struct IndexFailureView: View {
    @Environment(AppModel.self) private var model
    let title: String
    let message: String
    let repositoryID: UUID

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Rebuild Search Index") {
                model.rebuildIndex(repositoryID: repositoryID)
            }
        }
    }
}

/// The files panes' empty state, shared word for word and glyph for glyph:
/// the path is indexed, and no backup in the location holds a version of it.
struct NoBackupHoldsItYet: View {
    var body: some View {
        ContentUnavailableView("No backup holds it yet", systemImage: "clock.arrow.circlepath")
    }
}

/// What a fresh password field says under itself, on both onboarding
/// surfaces that ask for one (the first backup's sheet, the location
/// editor) — one fact, one spelling.
enum PasswordWords {
    static let recoveryWarning =
        "Everything is encrypted with it, and it can’t be recovered — keep it in your password manager."
}
