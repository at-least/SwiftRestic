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
/// so neither is ambient decoration competing for attention.
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
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(hue)
                .frame(width: 30, height: 30)
                .background(hue.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            // Title and message read as one utterance; the Reveal action and
            // the dismiss button stay their own elements beside them.
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(banner.title).font(.headline)
                    if !banner.message.isEmpty {
                        Text(banner.message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                if let revealPath = banner.revealPath {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: revealPath)])
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

/// One KPI: an icon chip beside a caption and a large rounded numeral, on its
/// own card plate. Used in overview, detail headers and diff statistics.
/// Icons are opt-in per tile and reserved for trouble — a healthy number
/// needs no glyph (the quiet rule the overview's tiles follow).
struct StatTile: View {
    let title: String
    let value: String
    var systemImage: String?
    var hue: Color = Theme.tint
    var help: String?
    /// Resting-state cue for tiles wrapped in a Button: the same trailing
    /// chevron the overview problem rows wear, so clickability does not
    /// exist only under the cursor. Decorative — the button's own
    /// accessibility label says where it goes.
    var trailingSymbol: String?

    var body: some View {
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(hue)
                    .frame(width: 30, height: 30)
                    .background(
                        hue.opacity(0.13),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    )
            }
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
            if let trailingSymbol {
                Spacer(minLength: 8)
                Image(systemName: trailingSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        // Caption and value read as one utterance — as separate stops every
        // pane's tile row would cost VoiceOver twice the trips.
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
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.tint)
                .help("More about this")
                .accessibilityLabel("More about this")
            }
            if isExpanded {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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
            .frame(minHeight: 110, maxHeight: 220)
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

    @MainActor
    static func chooseDirectory(message: String, prompt: String = "Choose") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = prompt
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
