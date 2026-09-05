import AppKit
import SwiftUI

/// Dismissible message strip shown above a detail pane.
struct BannerView: View {
    @Environment(AppModel.self) private var model
    let banner: Banner

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? .orange : .green)
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
        }
        .padding(12)
        .background(banner.isError ? Color.orange.opacity(0.12) : Color.green.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A label/value row inside an information card.
///
/// `LabeledContent` only aligns its two columns inside a `Form`; dropped into a
/// `GroupBox` it renders the value hard against the label, which reads as a
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

/// One number with a caption, used in the header of a plan or repository.
struct StatTile: View {
    let title: String
    let value: String
    var systemImage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).imageScale(.small)
                }
                Text(title)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(value)
                .font(.title3.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Live progress of a running backup or restore.
struct OperationProgressView: View {
    let title: String
    let progress: OperationProgress
    let startedAt: Date?
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
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
                    .monospacedDigit()
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
        .padding(12)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

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
            Text(title).font(.headline)

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
            .border(.quaternary)

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

extension View {
    /// Standard padded detail-pane container.
    func detailPane() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                self
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
