import AppKit
import SwiftUI

// MARK: - Card

/// Titled card container, the visual unit of the dashboard and detail
/// panes: an opaque control-coloured plate with a hairline border and a
/// headline row, optionally carrying a trailing accessory (segmented
/// pickers, refresh buttons).
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

// MARK: - Sheet tabs

/// An editor sheet's tabs: a segmented picker over the chosen pane, where a
/// SwiftUI `TabView` would be an `NSTabView`. That one sizes its tab control
/// only when its own frame changes size. In a sheet held below its ideal
/// height by a short window — the main window at its 652 pt minimum — the
/// last change comes before the control can size itself, and the control
/// stays 0×0, drawn as a box reading "R…": `NSTabViewSegmentedControl` at
/// 0×0 beside an intrinsic 160.5×24 (macOS 27.0.1). A relayout
/// left it so; only another size change of the tab view fixed it.
///
/// A pane is built when first shown and kept after, as a `TabView` keeps its
/// tabs: a pane's task starts on its first visit, and a half-typed field
/// survives a look at another tab. A hidden pane is disabled, so the Tab key
/// cannot walk into it.
struct SheetTabs<Tab: Hashable, Pane: View>: View {
    @Binding var selection: Tab
    let tabs: [Tab]
    let title: (Tab) -> String
    @ViewBuilder let pane: (Tab) -> Pane

    @State private var shown: Set<Tab> = []

    var body: some View {
        VStack(spacing: 10) {
            Picker("Tab", selection: $selection) {
                ForEach(tabs, id: \.self) { tab in
                    Text(title(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            ZStack {
                ForEach(tabs, id: \.self) { tab in
                    if tab == selection || shown.contains(tab) {
                        let isSelected = tab == selection
                        pane(tab)
                            .opacity(isSelected ? 1 : 0)
                            .allowsHitTesting(isSelected)
                            .disabled(!isSelected)
                            .accessibilityHidden(!isSelected)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selection, initial: true) { _, tab in
            shown.insert(tab)
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
    /// The fix's own button where the banner's words would only say where
    /// it is — the restic-missing banner's "Open Settings".
    var settingsAction: (() -> Void)? = nil

    /// The status palette's glyph and hue for the banner's level, so a
    /// colour means one thing app-wide: a failure's red octagon and a
    /// warning's orange triangle are Activity's and the sidebar's for a run
    /// that failed or completed with warnings.
    private var hue: Color {
        switch banner.level {
        case .error: StatusPalette.status(.failed)
        case .warning: StatusPalette.status(.completedWithErrors)
        case .success: Theme.success
        case .notice: .secondary
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
                .font(.system(size: 14, weight: .semibold))
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
                if let settingsAction {
                    Button("Open Settings", action: settingsAction)
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
/// plate. The compare sheet's statistics are its one use.
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

// MARK: - Removed names

/// A "Deleted:" line — or "Not read:", for what the backup's own run could
/// not read — whose names are routes: each opens the item's versions at
/// the backup before, which still holds it — the incomplete strip's
/// grammar, inline. The names wear the accent, as a link does; the words
/// around them stay secondary. Each tooltip is its own: one on the line
/// would cover the names'.
struct RemovedNamesLine: View {
    let names: RemovedNames
    /// Every removed path or name, for the words around the names.
    let help: String
    /// When the backup before was made, for the names' tooltips.
    let before: Date
    /// Opens a name's versions; nil where there is no Files tab to open
    /// them on (a group's backups under Other backups), and the names are
    /// words only.
    let open: ((RemovedItem) -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            Text(names.label)
                .help(help)
            ForEach(Array(names.items.enumerated()), id: \.element) { index, item in
                let standing = item.reason.map {
                    "Not read by this backup — \($0); it may still be on this Mac. The backup of \(Format.timestamp(before)) has it"
                } ?? "The backup of \(Format.timestamp(before)) has it"
                if let open {
                    Button { open(item) } label: {
                        Text(verbatim: item.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(HoverableButtonStyle())
                    .help(standing + ". Show its versions")
                } else {
                    Text(verbatim: item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(standing)
                }
                if index < names.items.count - 1 || names.more > 0 {
                    Text(verbatim: ", ")
                }
            }
            if names.more > 0 {
                Text("and \(Format.count(names.more)) more")
                    .help(help)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Network shares

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
            SecureField("Share password", text: $password, prompt: Text(isSaved ? "Saved" : "Needed to reconnect it"))
                .labelsHidden()
        }
        Text(isSaved
            ? "SwiftRestic reconnects the share when it needs it and the share isn’t mounted. Type a password to replace the saved one."
            : "SwiftRestic reconnects the share when it needs it and the share isn’t mounted.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
                // One label-column width app-wide, so stacked cards' values
                // line up; a longer label widens the column, never truncates.
                .frame(minWidth: 110, alignment: .trailing)
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

/// A form caption whose teaching text sits behind an info button: the
/// summary line is always visible, the rest for whoever wants it — the
/// same on-demand depth the app gives hook variables and diff metadata.
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
                    Button("Cancel", action: onCancel)
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

/// Why a Snapshots value may read "—", in visible text: under the plan page's
/// Backups card, and as the repository page's Protection card body. The tooltips carry the same
/// lines, but a reason only a hovering mouse user can reach is no reason at
/// all for a keyboard or VoiceOver user.
struct SnapshotListingCaveat: View {
    let outcome: SnapshotListingOutcome

    var body: some View {
        switch outcome {
        case let .failed(message):
            // The glyph carries the alarm and the words stay secondary:
            // a warning-coloured sentence at caption size is too
            // low-contrast to read.
            Label {
                Text(OverviewMetrics.listingFailureText(message))
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
            }
            .font(.caption)
        case .idle:
            Label(OverviewMetrics.listingIdleText, systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .loaded:
            EmptyView()
        }
    }
}

// MARK: - Snapshot completeness

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

// MARK: - Snapshot browser chrome

/// The chrome the snapshot browsers share — one icon map, one keyboard
/// grammar, one ascent step, one row.
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
    /// produces, so only this constant matches the key.
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

/// The row a Files-view folder lists for one node: icon, name, its change
/// mark and a file's size. (The restore pane's change-annotated row is
/// its own shape.)
struct SnapshotNodeRow: View {
    let node: SnapshotNode
    /// How it changed since the backup before — Added, Modified — in the
    /// Restore pane's Change words; nil for unchanged.
    var change: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.browserIconName)
                .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 16)
                .accessibilityLabel(node.kindName)
            Text(node.name)
                .lineLimit(1)
            Spacer()
            if let change {
                Text(change)
                    .font(.caption)
                    .lineLimit(1)
            }
            // No Modified column: a folder as of a backup is chosen by the
            // backup's moment, and a file's dates are its own pane's rows.
            if !node.isDirectory {
                Text(Format.bytes(node.size))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Path list editor

/// A list of paths with add/remove buttons: a plan's exclude patterns.
///
/// Typing, pasting and dropping are first-class: the audience keeps paths on
/// the clipboard, and an NSOpenPanel per entry is the app's biggest
/// efficiency tax.
struct PathListEditor: View {
    /// The field's accessibility label.
    let title: String
    @Binding var paths: [String]
    var placeholder = "Add a pattern"
    /// Choose items's panel: what it asks for and its button.
    var browseMessage = "Choose folders and files to leave out of backups"
    var browsePrompt = "Add"
    /// Excludes: an item chosen in the panel or dropped from Finder is
    /// entered as its own path, matching itself alone (`PathListEntry`).
    var escapesPickedGlobs = false

    @State private var selection: Set<String> = []
    @State private var draft = ""
    @State private var isDropTargeted = false

    /// About six one-line rows: the list scrolls past them rather than
    /// pushing the switches off the sheet.
    private static let listHeight: CGFloat = 132

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(paths, id: \.self) { path in
                    Text(path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                        .tag(path)
                }
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
                Divider()
                    .frame(height: 14)
                ListBarButton(symbol: "minus", title: "Remove") {
                    paths.removeAll { selection.contains($0) }
                    selection.removeAll()
                }
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
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Theme.tint : Color.primary.opacity(0.09),
                    lineWidth: isDropTargeted ? 2 : 1
                )
        )
    }

    private func addDraft() {
        addPaths([draft], picked: false)
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
        draft = ""
    }

    private func browse() {
        guard let chosen = FilePicker.chooseFoldersAndFiles(message: browseMessage, prompt: browsePrompt) else { return }
        addPaths(chosen.map(\.path), picked: true)
    }
}

// MARK: - Skip switches

/// The plan editor's *Skip* switches by the names the editor and the plan
/// page's Excluding card both give them.
enum PlanSkips {
    static let finderFiles = "Finder files and the Trash"
    static let systemFiles = "App caches and system files"
    static let caches = "Folders marked as caches"
    static let developerFiles = "Developer files"
    static let cloudFiles = "Online-only files"
    static let otherDisks = "Other disks mounted inside"

    static let cachesHelp = "Folders holding a CACHEDIR.TAG file"
    static let otherDisksHelp = "Folders on another disk mounted inside this one"

    /// The rules a defaults switch passes, one a line, for its tooltip.
    static func rulesHelp(_ categories: Set<ExcludeCategory>) -> String {
        ExcludeRule.defaults
            .filter { categories.contains($0.category) }
            .map { "\($0.pattern) — \($0.what)" }
            .joined(separator: "\n")
    }

    /// The switches `plan` has on, in the editor's order, each with its
    /// tooltip. Developer files names its ticked groups when not all are.
    static func on(in plan: BackupPlan) -> [(title: String, help: String)] {
        var items: [(title: String, help: String)] = []
        if plan.skipsFinderFiles { items.append((finderFiles, rulesHelp(ExcludeCategory.finderFiles))) }
        if plan.skipsSystemFiles { items.append((systemFiles, rulesHelp(ExcludeCategory.systemFiles))) }
        if plan.excludeCaches { items.append((caches, cachesHelp)) }
        if plan.excludeDeveloperFiles {
            let groups = plan.developerGroups.map(\.title)
            let isAll = plan.developerGroups == ExcludeCategory.developerGroups
            items.append((isAll ? developerFiles : "\(developerFiles): \(Format.list(groups))", groups.joined(separator: "\n")))
        }
        if plan.excludeCloudFiles { items.append((cloudFiles, "Files kept only in iCloud Drive or OneDrive")) }
        if plan.oneFileSystem { items.append((otherDisks, otherDisksHelp)) }
        return items
    }
}

// MARK: - Editable list

/// A list people add rows to and take rows from, the Mac's way — the
/// Hooks tab's and the Webhooks tab's: framed, with + and − attached beneath
/// it, symbols and not words (the HIG's square buttons, "adding or removing
/// rows in a table"). Empty, the frame says so and what + does, rather than
/// standing as a blank box.
struct EditableListFrame<Content: View>: View {
    let isEmpty: Bool
    let emptyTitle: String
    /// The next step, naming the + it starts from.
    let emptyHint: String
    /// The buttons' names, for their tooltips and VoiceOver: "Add hook".
    let addTitle: String
    let removeTitle: String
    let canRemove: Bool
    let onAdd: () -> Void
    let onRemove: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if isEmpty {
                    VStack(spacing: 4) {
                        Text(emptyTitle)
                            .font(.headline)
                        Text(emptyHint)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content()
                }
            }
            Divider()
            HStack(spacing: 0) {
                ListBarButton(symbol: "plus", title: addTitle, action: onAdd)
                Divider()
                    .frame(height: 14)
                ListBarButton(symbol: "minus", title: removeTitle, action: onRemove)
                    .disabled(!canRemove)
                Spacer()
            }
            .padding(.horizontal, 2)
            .frame(height: 24)
        }
        // The exclude list's hairline frame, so the editors' lists match.
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
        )
    }

}

/// A + or − of the bar attached beneath an editable list: a symbol, its
/// name in the tooltip and for VoiceOver.
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

// MARK: - File picker

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

    /// One folder or file: a plan's path.
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

// MARK: - Full Disk Access

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
/// again".
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

/// One unreadable item's line — in Activity's drawer and on the plan
/// page's problem card — with the two fixes the diagnosis above it names,
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
    @State private var exists: Bool?
    @State private var isConfirmingExclude = false

    var body: some View {
        let path = run.unreadableItemPaths?[line]
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
                Button("Exclude") { model.exclude(path: path, fromPlan: plan.id) }
            }
        } message: {
            Text("The plan’s next backups skip \(path ?? "") — backups already made keep it. The plan editor lists it under Also skip, where − takes it out again.")
        }
        .task(id: path) {
            guard let path else { return }
            exists = nil
            let found = await Task.detached(priority: .utility) {
                FileManager.default.fileExists(atPath: path)
            }.value
            guard !Task.isCancelled else { return }
            exists = found
        }
    }

    @ViewBuilder
    private func actions(path: String, plan: BackupPlan?) -> some View {
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        .disabled(exists != true)
        if let plan {
            Button("Exclude from “\(model.label(of: plan))”") { isConfirmingExclude = true }
                .disabled(plan.excludePatterns.contains(ResticService.globEscaped(path)))
        }
    }
}

/// A picker over a history of more than `DiffCandidateGrouping.flatMonthLimit`
/// months, the shape `DiffCandidateGrouping.nested` answers with: the newest
/// month's rows flat under its caption, each older month a submenu of its
/// rows, a checkmark on the chosen one. The rows are Toggles, not a Picker
/// per month: several Pickers sharing one selection would each warn of a
/// tag none of their own rows carry. The Files pane's "As backed up" and
/// the Compare sheet's "Compared with" are both this view.
struct NestedMonthMenu<Item, Label: View>: View {
    let nested: (flat: DiffCandidateGrouping.Month<Item>, submenus: [DiffCandidateGrouping.Month<Item>])
    /// The row's identity, which `selected` names.
    let id: KeyPath<Item, String>
    /// The chosen row, resolved once by the caller: a pane whose nil means
    /// the newest resolves it before asking, so no row scans for it.
    let selected: String?
    let select: (String) -> Void
    let rowText: (Item) -> String
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            Section(nested.flat.label) {
                ForEach(nested.flat.items, id: id) { row($0) }
            }
            ForEach(nested.submenus, id: \.label) { month in
                Menu(month.label) {
                    ForEach(month.items, id: id) { row($0) }
                }
            }
        } label: {
            label()
        }
    }

    private func row(_ item: Item) -> some View {
        let itemID = item[keyPath: id]
        return Toggle(isOn: Binding(
            get: { selected == itemID },
            set: { if $0 { select(itemID) } }
        )) {
            Text(verbatim: rowText(item))
        }
    }
}
