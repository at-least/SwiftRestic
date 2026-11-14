import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

struct OperationProgressView: View {
    let title: String
    let progress: OperationProgress
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

            // Before restic reports numbers the title already says what is
            // happening.
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
    private static func caption(_ progress: OperationProgress) -> String? {
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

/// Why a `snapshotsValue` may read "—", in visible text: a reason only a
/// hovering mouse user can reach is no reason at all for a keyboard or
/// VoiceOver user. A failed read's one way forward sits under its words:
/// the known fix, or Try Again.
struct SnapshotListingCaveat: View {
    @Environment(AppModel.self) private var model
    let repositoryID: UUID?

    var body: some View {
        let outcome = model.snapshotListingOutcome(for: repositoryID)
        if case let .notConnected(volume) = outcome {
            // A normal state, not a failed read: its sentence alone.
            // Locate, for a disk renamed, is in the sidebar row's menu.
            Text(SnapshotListingOutcome.connectText(volume: volume))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let message = outcome.failureMessage {
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
                if let fix = repositoryID.flatMap(outcome.failureFix(repositoryID:)) {
                    RunFixButton(fix: fix)
                        .controlSize(.small)
                } else if let repositoryID {
                    Button("Try Again") {
                        Task { await model.refreshSnapshots(repositoryID: repositoryID) }
                    }
                    .controlSize(.small)
                    .disabled(model.loadingSnapshots.contains(repositoryID))
                }
            }
        } else if outcome == .idle {
            Text(OverviewMetrics.listingIdleText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A snapshot's completeness. Only trouble wears a glyph: the
/// completed-with-errors triangle, because that is what the run behind it
/// was. A known-complete snapshot keeps an invisible "Complete" for
/// VoiceOver; one with no run record here makes no claim. The caller's
/// fixed-width slot lines neighbouring text up whether or not a glyph shows.
///
/// The invisible label is clear ink: on macOS 26 a zero-opacity Text or
/// Image is dropped from the accessibility tree in both a List row and a
/// Table cell, and in a sidebar row it folds into the timestamp beside it.
/// A clear Text survives as its own static text in both.
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

    private static let size: CGFloat = 16

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
            .frame(width: Self.size, height: Self.size)
    }
}

extension UTType {
    static func backedUp(name: String, isDirectory: Bool) -> UTType {
        if isDirectory { return .folder }
        return UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
    }
}

enum FilePicker {
    /// `directoryURL` is where the panel opens; nil leaves it to AppKit's
    /// own memory of the last folder.
    @MainActor
    static func chooseDirectory(message: String, directoryURL: URL? = nil, prompt: String = "Choose") -> URL? {
        let panel = directoryPanel(message: message, prompt: prompt)
        if let directoryURL { panel.directoryURL = directoryURL }
        return panel.runModal() == .OK ? panel.urls.first : nil
    }

    @MainActor
    static func directoryPanel(message: String, prompt: String) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = prompt
        return panel
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

/// What to do about a run's unreadable items, in `ItemErrorDiagnosis`'s
/// words. The hints take the current access state, so a fresh grant turns
/// "grant it" into "back up again". No Back Up Now on "back up again": the
/// plan page's Backups section and the drawer's footer hold it wherever the
/// plan can back up.
struct ItemErrorHintsView: View {
    @Environment(AppModel.self) private var model
    let run: RunRecord

    var body: some View {
        let hints = ItemErrorDiagnosis.hints(for: run, accessNow: model.fullDiskAccess)
        let plan = run.planID.flatMap { model.plan(id: $0) }
        if !hints.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                    let paths = plan == nil ? [] : ItemErrorDiagnosis.excludablePaths(for: hint, in: run)
                    Text(ItemErrorDiagnosis.detail(hint, offersExclude: !paths.isEmpty))
                        .textSelection(.enabled)
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
            model.exclude(paths: pending, fromPlan: plan.id)
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
}

/// One unreadable item's line, with Show in Finder and Exclude from the plan
/// in a menu at its end and in its context menu, where the run stored the
/// item's path (`RunRecord.unreadableItemPaths`). Exclude acts at once; the
/// plan page's Excluded Items list takes it back.
struct UnreadableItemLine: View {
    @Environment(AppModel.self) private var model
    let run: RunRecord
    let line: String
    /// Nil until the check lands; Show in Finder waits disabled until then.
    @State private var existence = PathExistence()

    var body: some View {
        let path = run.unreadableItemPaths?[PathKey(line)]
        let plan = run.planID.flatMap { model.plan(id: $0) }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // By name, where and why; restic's whole line in the tooltip,
            // the copied details and the log. A line with no stored path stays
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
            Button("Exclude from “\(model.label(of: plan))”") { model.exclude(paths: [path], fromPlan: plan.id) }
                .disabled(plan.excludePatterns.contains(ResticService.globEscaped(path)))
        }
    }
}

/// What a fresh password field says under itself, on both onboarding
/// surfaces that ask for one (the first backup's sheet, the location
/// editor) — one fact, one spelling.
enum PasswordWords {
    static let recoveryWarning =
        "Everything is encrypted with it, and it can’t be recovered — keep it in your password manager."
}
