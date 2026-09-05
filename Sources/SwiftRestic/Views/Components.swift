import AppKit
import SwiftUI

// MARK: - Card

/// Titled card container, the visual unit of the redesigned dashboard and
/// detail panes: an opaque control-coloured plate with a hairline border and a
/// headline row, optionally carrying a trailing accessory (segmented pickers,
/// refresh buttons).
struct Card<Accessory: View, Content: View>: View {
    var title: LocalizedStringKey
    var systemImage: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.tint)
                }
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
    let systemImage: String
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.tint)
                .frame(width: 30, height: 30)
                .background(
                    Theme.tint.opacity(0.13),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                )
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

/// Dismissible message strip shown above a detail pane.
struct BannerView: View {
    @Environment(AppModel.self) private var model
    let banner: Banner

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
            Spacer()
            Button {
                model.banner = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(Theme.Space.cardPadding)
        .cardSurface()
    }
}

// MARK: - Stat tile

/// One KPI: an icon chip beside a caption and a large rounded numeral, on its
/// own card plate. Used in overview, detail headers and diff statistics.
struct StatTile: View {
    let title: String
    let value: String
    var systemImage: String?
    var hue: Color = Theme.tint
    var help: String?

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
                    .minimumScaleFactor(0.6)
            }
        }
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
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.tint)
                Text(title).font(.headline)
                Spacer()
                if let onCancel {
                    Button("Cancel", role: .destructive, action: onCancel)
                        .controlSize(.small)
                }
            }

            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .tint(Theme.tint)

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
struct PathListEditor: View {
    let title: String
    @Binding var paths: [String]
    var allowsBrowsing = true
    var placeholder = "Add a pattern"

    @State private var selection: Set<String> = []
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "folder.badge.gearshape")
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
            .frame(minHeight: 110, maxHeight: 160)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
            )

            HStack(spacing: 6) {
                if allowsBrowsing {
                    Button("Choose…") { browse() }
                } else {
                    TextField(placeholder, text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addDraft)
                    Button("Add", action: addDraft)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
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
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !paths.contains(value) else { return }
        paths.append(value)
        draft = ""
    }

    private func browse() {
        guard let chosen = FilePicker.chooseFoldersAndFiles() else { return }
        for url in chosen where !paths.contains(url.path) {
            paths.append(url.path)
        }
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
