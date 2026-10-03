import AppKit
import SwiftUI

// MARK: - Card

/// Titled card container, the visual unit of the redesigned dashboard and
/// detail panes: an opaque control-coloured plate with a hairline border and a
/// headline row, optionally carrying a trailing accessory (segmented pickers,
/// refresh buttons).
struct Card<Accessory: View, Content: View>: View {
    var title: LocalizedStringKey
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(
        _ title: LocalizedStringKey,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.content = content
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                Spacer()
                accessory()
            }
            content()
        }
        .padding(Theme.Space.cardPadding)
        .cardSurface()
    }
}

// MARK: - Sheet header

/// Title row for utility sheets, which live outside the navigation stack and
/// would otherwise carry no identity of their own.
struct SheetHeader: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

// MARK: - Banner

/// Dismissible message strip shown above a detail pane. Banners built in
/// place (rather than posted to the queue) have nothing to dismiss, so they
/// hide the close button.
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

    private var hue: Color { banner.isError ? Theme.danger : Theme.success }
    private var symbol: String {
        banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // The success check is decoration beside a title that already
            // says what happened, and its SF label read "Selected" to
            // VoiceOver. The error triangle stays, named for what it means
            // rather than SF's "Warning": not every error title says it
            // failed ("Keychain").
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(hue)
                .accessibilityLabel(banner.isError ? "Error" : "")
                .accessibilityHidden(!banner.isError)
            // Title and message read as one utterance; the Reveal action and
            // the dismiss button stay their own elements beside them.
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(banner.title).font(.headline)
                    if !banner.message.isEmpty {
                        // Never fixedSize(vertical:): the split view asks its
                        // detail column for a minimum size at zero width, where
                        // a height-pinned message wraps to about a character
                        // per line, and the non-scrolling hosts (Activity, the
                        // console, the Restore pane, the restic-missing strip)
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
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(banner.revealPaths.map { URL(fileURLWithPath: $0) })
                    }
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
        .padding(Theme.Space.cardPadding)
        .cardSurface()
    }
}

// MARK: - Stat tile

/// One figure: a caption above a large rounded numeral, on its own card
/// plate. The compare sheet's statistics are its one use since the
/// dashboard and the repository page moved to label/value cards.
struct StatTile: View {
    let title: String
    let value: String
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(Theme.statValue)
                .monospacedDigit()
                .lineLimit(1)
                // 75%, not less: these are the app's most prominent
                // numerals, and shrinking further trades legibility for a
                // fit a truncation ellipsis would serve better.
                .minimumScaleFactor(0.75)
        }
        // Caption and value read as one utterance — as separate stops a row
        // of tiles would cost VoiceOver twice the trips.
        .accessibilityElement(children: .combine)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.cardPadding)
        .cardSurface()
        .modifier(TileHelp(help: help))
    }
}

/// `.help` only when there is text to show; an empty tooltip would still hit.
private struct TileHelp: ViewModifier {
    let help: String?

    func body(content: Content) -> some View {
        if let help {
            content.help(help)
        } else {
            content
        }
    }
}

/// For buttons that are tiles or rows and do not look pressable: a quiet
/// hover tint so the pointer reveals the affordance before the click.
struct HoverableButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                (isHovering || configuration.isPressed)
                    ? Color.primary.opacity(0.045)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .onHover { isHovering = $0 }
    }
}

// MARK: - Detail rows

/// A label/value row inside an information card.
///
/// `LabeledContent` only aligns its two columns inside a `Form`; dropped into a
/// plain card it renders the value hard against the label, which reads as a
/// typo. These rows go in a `Grid` so the values line up in a column.
struct DetailRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: () -> Value

    init(_ label: String, @ViewBuilder value: @escaping () -> Value) {
        self.label = label
        self.value = value
    }

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension DetailRow where Value == Text {
    init(_ label: String, _ value: String) {
        self.init(label) { Text(value) }
    }
}

/// Container for `DetailRow`s.
struct DetailGrid<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            content()
        }
    }
}

// MARK: - Expandable caption

/// A form caption that keeps its teaching text but stops charging for it on
/// every render: the summary line is always visible, and the rest sits
/// behind the info button for whoever wants it — the same on-demand depth
/// the app already gives hook variables and diff metadata.
struct ExpandableCaption: View {
    /// The always-visible line.
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
                // (measured with HID-level clicks, macOS 26).
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
                .foregroundStyle(Theme.tint)
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

// MARK: - Operation progress

/// Live progress of a running backup or restore, on its own card plate with a
/// tinted bar.
struct OperationProgressView: View {
    let title: String
    let progress: OperationProgress
    let startedAt: Date?
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // No leading glyph: the bar below is the live status, and the
                // card's title names the work — a decorative symbol would
                // only re-draw the eye to a card that is already the answer.
                Text(title).font(.headline)
                Spacer()
                if let onCancel {
                    Button("Cancel", role: .destructive, action: onCancel)
                        .controlSize(.small)
                }
            }

            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)

            // The numbers once restic has reported any: before that — a
            // plan's before-backup hooks, restic starting up — they read
            // "0 / 0 files, 0 bytes / 0 bytes, 0%", and the title already
            // says what is happening.
            if progress != OperationProgress() {
                HStack(spacing: 14) {
                    Text("\(Format.count(progress.filesDone)) / \(Format.count(progress.totalFiles)) files")
                    Text("\(Format.bytes(progress.bytesDone)) / \(Format.bytes(progress.totalBytes))")
                    if let startedAt {
                        Text(Format.rate(
                            bytes: progress.bytesDone,
                            over: Date.now.timeIntervalSince(startedAt)
                        ))
                    }
                    if let remaining = progress.secondsRemaining, remaining > 0 {
                        Text("\(Format.duration(TimeInterval(remaining))) left")
                    }
                    Spacer()
                    Text(progress.fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.tint)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let current = progress.currentFile {
                Text(current)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(Theme.Space.cardPadding)
        .cardSurface()
    }
}

// MARK: - Restore progress strip

/// The app-level restore strip: while a restore runs, its progress is a fact
/// above whatever surface is on screen, wired to the model's cancel. A
/// restore outlives the pane that started it, so every browser surface and
/// the window's detail column show the same strip instead of private copies.
struct RestoreProgressStrip: View {
    @Environment(AppModel.self) private var model
    /// Replaces an empty description. The app-level strip over the panes has
    /// no other context to name the work; the sheets sit beside the entry
    /// point that started the restore, so they show the bare description.
    var fallbackTitle: String? = nil

    var body: some View {
        if let progress = model.restoreActivity {
            OperationProgressView(
                title: title,
                progress: progress,
                startedAt: nil,
                onCancel: { model.cancelRestore() }
            )
        }
    }

    private var title: String {
        if model.restoreDescription.isEmpty, let fallbackTitle {
            return fallbackTitle
        }
        return model.restoreDescription
    }
}

// MARK: - Snapshot listing outcome

/// Why a Snapshots value may read "—", in visible text, under the card that
/// shows it (the plan and repository pages). The tooltips carry the same
/// lines, but a reason only a hovering mouse user can reach is no reason at
/// all for a keyboard or VoiceOver user.
struct SnapshotListingCaveat: View {
    let outcome: SnapshotListingOutcome

    var body: some View {
        switch outcome {
        case let .failed(message):
            // The glyph carries the alarm and the words stay secondary:
            // the sentence in orange measured 2.33:1 on the repository page.
            Label {
                Text("Snapshots could not be read — \(Format.firstSentence(message))")
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
            }
            .font(.caption)
        case .idle:
            Label("The snapshot list has not finished loading.", systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .loaded:
            EmptyView()
        }
    }
}

/// A snapshot count traces to the moment it was read: an "Updated 7:27 AM"
/// caption, or a spinner while a refresh is in flight.
struct SnapshotFreshnessLabel: View {
    let loadedAt: Date?
    let isLoading: Bool

    var body: some View {
        if isLoading {
            ProgressView().controlSize(.small)
        } else if let loadedAt {
            Text("Updated \(loadedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - Snapshot completeness

/// A snapshot's completeness, where snapshots are named (the sidebar's
/// backups, Activity's run drawer). Only trouble wears a glyph — the rule
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
/// as its own static text in both (AX probe harness, 2026-09-26).
struct SnapshotCompletenessMark: View {
    let run: RunRecord?

    private static let outcome = RunRecord.Outcome.completedWithErrors
    private static let symbolName = outcome.symbolName ?? "exclamationmark.triangle.fill"

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

// MARK: - Snapshot browser chrome

/// The chrome the snapshot browsers share — one icon map, one keyboard
/// grammar, one ascent step, one row. These used to live as private per-view
/// clones that could only drift.
extension SnapshotNode {
    /// The list glyph for a node's kind.
    var browserIconName: String {
        switch type {
        case .dir: "folder.fill"
        case .symlink: "arrow.turn.up.right"
        case .file: "doc"
        default: "questionmark.square.dashed"
        }
    }

    /// What the glyph means, for VoiceOver. SF Symbols' own labels name the
    /// picture, not the meaning — folder.fill reads "Move", doc "Document".
    var kindName: String {
        switch type {
        case .dir: "Folder"
        case .symlink: "Symbolic link"
        case .file: "File"
        default: "Special file"
        }
    }
}

/// The keyboard grammar the browsers' lists speak, and the parent step their
/// go-up buttons take.
enum BrowserListGrammar {
    /// The ⌫ key as `onKeyPress` delivers it: U+007F, what AppKit's Delete
    /// key types. SwiftUI's `KeyEquivalent.delete` is U+0008, which ⌫ never
    /// matched — a probe list's handler received 127 for it on macOS 26 —
    /// so ⌫ went up nowhere.
    static let deleteKey = KeyEquivalent("\u{7F}")

    /// The lists' keyboard grammar. Everything unrecognised returns
    /// `.ignored` so the List keeps its own arrow-key selection movement.
    /// Return opens the selected directory through `open`; ⌫ and ⌘↑ ascend
    /// through `goUp` when a parent exists (`hasParent`) — Finder's own
    /// grammar.
    static func keyPress(
        _ press: KeyPress,
        selected: SnapshotNode?,
        hasParent: Bool,
        open: (SnapshotNode) -> Void,
        goUp: () -> Void
    ) -> KeyPress.Result {
        switch press.key {
        case .return:
            if let node = selected, node.isDirectory {
                open(node)
                return .handled
            }
            return .ignored
        case deleteKey:
            guard hasParent else { return .ignored }
            goUp()
            return .handled
        case .upArrow where press.modifiers.contains(.command):
            guard hasParent else { return .ignored }
            goUp()
            return .handled
        default:
            return .ignored
        }
    }

    /// The parent of an absolute path for browser ascent: both the empty
    /// parent and "/" mean "above the top", which the caller renders as its
    /// pseudo-root.
    static func parent(of path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty || parent == "/" ? nil : parent
    }
}

/// The row Browse Folders renders for one node: icon, name, and the size
/// and modification columns. (The restore pane's change-annotated row is
/// its own shape.)
struct SnapshotNodeRow: View {
    let node: SnapshotNode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.browserIconName)
                .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 16)
                .accessibilityLabel(node.kindName)
            Text(node.name)
                .lineLimit(1)
            Spacer()
            if !node.isDirectory {
                Text(Format.bytes(node.size))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(Format.timestamp(node.mtime))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 140, alignment: .trailing)
        }
    }
}

// MARK: - Path list editor

/// A list of paths with add/remove buttons, used for sources and excludes.
///
/// Typing, pasting and dropping are first-class: the audience keeps paths on
/// the clipboard, and an NSOpenPanel per source is the app's biggest
/// efficiency tax.
struct PathListEditor: View {
    let title: String
    /// Names the list's meaning in the row: sources and excludes are not the
    /// same thing, so they no longer wear the same icon.
    var systemImage = "folder.badge.gearshape"
    @Binding var paths: [String]
    var allowsBrowsing = true
    var placeholder = "Add a pattern"
    /// Sources are real paths, so a leading `~` has to become the home
    /// directory — restic never sees a shell. Excludes are match patterns
    /// where `~` must stay literal.
    var expandsTildeInPath = false

    @State private var selection: Set<String> = []
    @State private var draft = ""
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            List(selection: $selection) {
                ForEach(paths, id: \.self) { path in
                    Text(path)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .tag(path)
                }
            }
            // The plan editor's give: the lists grow toward 220 when the
            // sheet has room, and shrink first when it does not — the adopt
            // sheet stacks a header strip and footer warnings on the same
            // frame, and content that outgrows a sheet loses its top edge.
            .frame(minHeight: 44, maxHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? Theme.tint : Color.primary.opacity(0.09),
                        lineWidth: isDropTargeted ? 2 : 1
                    )
            )
            .dropDestination(for: URL.self) { urls, _ in
                // Only file URLs are sources: a dragged web link's `.path`
                // would silently become a nonexistent backup source.
                let filePaths = urls.filter(\.isFileURL).map(\.path)
                guard !filePaths.isEmpty else { return false }
                addPaths(filePaths)
                return true
            } isTargeted: { isDropTargeted = $0 }

            HStack(spacing: 6) {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addDraft)
                Button("Add", action: addDraft)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                if allowsBrowsing {
                    Button("Choose…") { browse() }
                }
                Spacer()
                Button("Remove") {
                    paths.removeAll { selection.contains($0) }
                    selection.removeAll()
                }
                .disabled(selection.isEmpty)
            }
        }
    }

    private func addDraft() {
        addPaths([draft])
    }

    private func addPaths(_ rawPaths: [String]) {
        for raw in rawPaths {
            // Trim first: a pasted " ~/Documents" does not start with `~`, so
            // expanding before trimming would leave the tilde literal — and
            // restic, seeing no shell, would stat a path that cannot exist.
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let value = expandsTildeInPath
                ? (trimmed as NSString).expandingTildeInPath
                : trimmed
            guard !paths.contains(value) else { continue }
            paths.append(value)
        }
        draft = ""
    }

    private func browse() {
        guard let chosen = FilePicker.chooseFoldersAndFiles() else { return }
        addPaths(chosen.map(\.path))
    }
}

// MARK: - File picker

/// Thin wrapper over `NSOpenPanel`, which SwiftUI's `fileImporter` cannot fully
/// replace here (we need multi-select across both files and folders).
enum FilePicker {
    @MainActor
    static func chooseFoldersAndFiles() -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders and files to back up"
        panel.prompt = "Add"
        return panel.runModal() == .OK ? panel.urls : nil
    }

    /// `directoryURL` is where the panel opens; nil leaves it to AppKit's
    /// own memory of the last folder.
    @MainActor
    static func chooseDirectory(message: String, prompt: String = "Choose", directoryURL: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = prompt
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
        return panel.runModal() == .OK ? panel.urls.first : nil
    }

    @MainActor
    static func chooseExecutable() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the restic executable"
        return panel.runModal() == .OK ? panel.urls.first : nil
    }
}

// MARK: - Pane container

extension View {
    /// Standard padded detail-pane container.
    func detailPane() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                self
            }
            .padding(Theme.Space.pane)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Path breadcrumb

/// A path rendered as clickable crumbs, walking down from the deepest root
/// that contains it. The crumb for the current path renders as plain text —
/// it is where you are, not where you can go. An empty path renders nothing:
/// callers show their own pseudo-root face instead.
struct PathBreadcrumb: View {
    let path: String
    let roots: [String]
    let onJump: (String) -> Void

    var body: some View {
        let crumbs = Format.crumbs(of: path, roots: roots)
        if !crumbs.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        // A separator, not a control: its SF label is
                        // "Forward", between crumbs VoiceOver already reads
                        // in order.
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    if crumb.target == path {
                        Text(crumb.label)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    } else {
                        Button(crumb.label) { onJump(crumb.target) }
                            .buttonStyle(.link)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Full Disk Access

/// The one way to the grant, wherever the app asks for it: Settings, the
/// Activity drawer, the plan page's problem row and the plan editor. The
/// grant cannot be requested by prompt, so the list in System Settings is
/// where it happens.
struct FullDiskAccessButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Open Full Disk Access Settings") { model.openFullDiskAccessSettings() }
            .help("System Settings › Privacy & Security › Full Disk Access")
    }
}

/// What to do about a run's unreadable items: macOS's privacy protection,
/// with the grant's button while it is still missing, then the files' own
/// permissions, which the grant does not change. Nothing for a run whose
/// items say neither. The words are `ItemErrorDiagnosis`'s, the same the
/// banner, the notification and the channels carry; the access state now
/// is read here, so granting it turns "grant it" into "back up again".
struct ItemErrorHintsView: View {
    @Environment(AppModel.self) private var model
    let run: RunRecord

    var body: some View {
        let hints = ItemErrorDiagnosis.hints(for: run, accessNow: model.fullDiskAccess)
        if !hints.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // Decoration beside a sentence that says it all.
                        Image(systemName: Self.symbolName(for: hint))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(ItemErrorDiagnosis.detail(hint))
                            .textSelection(.enabled)
                    }
                    .font(.callout)
                    if case .grantFullDiskAccess = hint {
                        FullDiskAccessButton()
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private static func symbolName(for hint: ItemErrorDiagnosis.Hint) -> String {
        switch hint {
        case .grantFullDiskAccess, .retryNowGranted, .protectedEvenWithAccess: "lock.shield"
        case .filePermissions: "person.crop.circle.badge.exclamationmark"
        }
    }
}
