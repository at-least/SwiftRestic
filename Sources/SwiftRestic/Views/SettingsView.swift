import SwiftUI

struct SettingsView: View {
    private static let width: CGFloat = 560
    @State private var isConfirmingCacheCleanup = false
    @Environment(AppModel.self) private var model
    /// Arms the "you can strand the app" confirmation: menu bar item off and
    /// window closed leaves the scheduler running with no visible way back.
    @State private var isConfirmingMenuBarOff = false
    /// The network share whose Remove asks first.
    @State private var removingShare: NetworkShare?

    var body: some View {
        // Each pane at its own height, the window following it (the
        // Settings scene's `.contentSize`): the HIG's "a settings window
        // accommodates the size of the current pane", no pane scrolling.
        TabView {
            generalTab(model: model)
                .frame(width: Self.width, height: 670)
                .tabItem { Label("General", systemImage: "gearshape") }
            notificationsTab(model: model)
                .frame(width: Self.width, height: 290)
                .tabItem { Label("Notifications", systemImage: "bell") }
            NotificationChannelsTab()
                .environment(model)
                .frame(width: Self.width, height: 460)
                .tabItem { Label("Webhooks", systemImage: "point.3.connected.trianglepath.dotted") }
            resticTab(model: model)
                .frame(width: Self.width, height: 380)
                .tabItem { Label("restic", systemImage: "terminal") }
        }
        .confirmationDialog(
            "Turn off the menu bar item?",
            isPresented: $isConfirmingMenuBarOff,
            titleVisibility: .visible
        ) {
            Button("Turn Off") {
                model.configuration.settings.showMenuBarExtra = false
            }
        } message: {
            Text("Backups keep running with the window closed, and SwiftRestic opens again only when you launch it.")
        }
        .confirmationDialog(
            "Remove \(removingShare?.url ?? "this share") from SwiftRestic?",
            isPresented: Binding(get: { removingShare != nil }, set: { if !$0 { removingShare = nil } }),
            titleVisibility: .visible,
            presenting: removingShare
        ) { share in
            Button("Remove") {
                Task {
                    do {
                        try await model.removeNetworkShare(share)
                    } catch {
                        model.post(Banner(
                            title: "The password for \(share.url) could not be removed",
                            message: error.localizedDescription,
                            isError: true
                        ))
                    }
                }
            }
        } message: { share in
            Text("Its saved password is deleted too. A backup that needs \(share.url) is skipped while it is not mounted, until its password is entered again in the repository's or plan's editor.")
        }
        .task {
            await model.refreshFullDiskAccess()
            await model.refreshLoginItemStatus()
        }
    }

    private func generalTab(model: AppModel) -> some View {
        @Bindable var model = model
        return Form {
            // First, and on General rather than the restic tab: it is the
            // app's permission, and restic inherits it.
            Section("Full Disk Access") {
                LabeledContent("Status") {
                    FullDiskAccessStatusLabel(status: model.fullDiskAccess)
                }
                if model.fullDiskAccess == .granted {
                    // Only what the grant controls: a file the account can't
                    // read stays unreadable, and the run's hint says so.
                    Text("Full Disk Access is on for SwiftRestic.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Unknown is treated as missing, as the run hints do:
                    // nothing observable says the grant is there.
                    Text("Without it, Mail, Messages, Safari and other apps' data can't be read, and backups that include them end with warnings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    FullDiskAccessButton()
                    ExpandableCaption(
                        summary: "Turn on SwiftRestic in the list. macOS asks for an administrator password.",
                        detail: "If SwiftRestic is not in the list, click + and choose it from your Applications folder. If it is already on and this still says Not granted, turn it off and on again: a rebuilt or updated copy of SwiftRestic may not inherit the permission. If that doesn't help, quit and reopen SwiftRestic."
                    )
                }
            }

            Section("Menu bar") {
                Toggle(
                    "Show SwiftRestic in the menu bar",
                    isOn: Binding(
                        get: { model.configuration.settings.showMenuBarExtra },
                        set: { newValue in
                            if newValue {
                                model.configuration.settings.showMenuBarExtra = true
                            } else {
                                isConfirmingMenuBarOff = true
                            }
                        }
                    )
                )
                ExpandableCaption(
                    summary: "Shows what's running, and opens SwiftRestic after its window is closed.",
                    detail: "The icon pulses while work is in progress (held still with Reduce Motion), dims while backups are paused or waiting for power, and wears a warning mark while a run from the last seven days failed or completed with warnings."
                )
            }

            Section("Scheduling") {
                Toggle("Start SwiftRestic at login", isOn: Binding(
                    get: { model.startsAtLogin },
                    // Optimistic flip, as the plan editor's Start at Login:
                    // the model var moves now, and the daemon's answer
                    // confirms or corrects it.
                    set: { value in model.requestStartsAtLogin(value) }
                ))
                .disabled(!model.loginItemInstallable && !model.startsAtLogin)
                // The model's copies of the daemon's answer: a read here
                // would be an XPC round trip on every render.
                Text(model.loginItemInstallable
                    ? LoginItem.description(of: model.loginItemState)
                    : LoginItem.notInstalledMessage)
                    .font(.caption)
                    .foregroundStyle(model.loginItemNeedsApproval ? Theme.warning : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.loginItemNeedsApproval {
                    Button("Open Login Items") { LoginItem.openLoginItemsSettings() }
                }

                Toggle("Pause scheduled backups on battery power", isOn: $model.configuration.settings.pauseOnBattery)
                Toggle("Pause scheduled backups on a metered network", isOn: $model.configuration.settings.pauseOnMeteredNetwork)
                    .help("A network macOS reports as expensive, such as cellular, or as constrained. Back Up Now still runs.")
                // Held, the next run is whenever the hold lifts — say why
                // instead of a date the scheduler will not keep.
                if let hold = model.scheduleHold {
                    LabeledContent("Next backup", value: hold.summary())
                } else if let next = model.nextScheduledRun {
                    // The plan with its repository, the tray headline's
                    // words — two repositories can hold same-named plans.
                    LabeledContent(
                        "Next backup",
                        value: RunRecordPresentation.nextRunLine(
                            plan: next.plan,
                            date: next.date,
                            plans: model.configuration.plans,
                            repositories: model.configuration.repositories
                        )
                    )
                } else {
                    LabeledContent("Next backup", value: "Nothing scheduled")
                }
            }

            // Saved from the repository and plan editors, where a folder on
            // a share asks for its password.
            if !model.configuration.settings.networkShares.isEmpty {
                Section("Network shares") {
                    ForEach(model.configuration.settings.networkShares) { share in
                        LabeledContent {
                            Button("Remove") { removingShare = share }
                        } label: {
                            Text(share.url)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(share.url)
                        }
                    }
                    Text("Reconnected with their saved passwords before a backup needs them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("History") {
                Stepper(value: $model.configuration.settings.maxRunHistory, in: 20 ... 2000, step: 20) {
                    LabeledContent("Items kept in Activity", value: "\(model.configuration.settings.maxRunHistory)")
                }
                // The trim's exemption (`OverviewMetrics.standingProblemIDs`).
                Text("Unresolved problems are kept longer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// This Mac's own notifications; webhooks are the next pane's.
    private func notificationsTab(model: AppModel) -> some View {
        @Bindable var model = model
        return Form {
            // The pane's title names it; no section heading repeats it.
            Section {
                Toggle("Notify when a backup succeeds", isOn: $model.configuration.settings.notifyOnSuccess)
                // What it gates (`AppModel.notify(about:)`), in the
                // webhooks' own event words.
                Toggle("Notify when a backup fails or completes with warnings", isOn: $model.configuration.settings.notifyOnFailure)
                // `RunRecord.problemStretch`: the rule said where it is set.
                Text("A failure that repeats with the same cause notifies once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // A plan that never runs writes no failure to notify about:
                // an unplugged drive at every slot, a Mac asleep through them.
                Picker("Notify when a scheduled plan has not backed up for", selection: $model.configuration.settings.staleAlertDays) {
                    ForEach(StaleAlert.choices, id: \.self) { days in
                        Text(days == 0 ? "Never" : Format.plural(days, "day")).tag(days)
                    }
                }
                Text("Once, until the plan backs up again. Paused and manual plans are left out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // The relationship between the two toggle layers, stated
                // where both are visible: these gate this Mac's notification
                // centre; the Webhooks tab's channels carry their own
                // per-event switches, and neither gates the other.
                ExpandableCaption(
                    summary: "These switches control this Mac's notifications.",
                    detail: "Webhooks have their own per-event switches and don't follow them."
                )
            }
        }
        .formStyle(.grouped)
    }

    private func resticTab(model: AppModel) -> some View {
        @Bindable var model = model
        return Form {
            Section("Executable") {
                HStack {
                    TextField(
                        "Path",
                        text: $model.configuration.settings.resticPathOverride,
                        prompt: Text(model.binary?.url.path ?? (model.binaryProblem == nil ? "Searching the usual locations" : ""))
                    )
                    Button("Choose…") {
                        if let url = FilePicker.chooseExecutable() {
                            model.configuration.settings.resticPathOverride = url.path
                        }
                    }
                }
                // The field's prompt is the path in use when none is typed,
                // so the path is not repeated in a row of its own.
                if model.isResticAvailable {
                    LabeledContent("Version", value: model.resticVersion.isEmpty ? "—" : model.resticVersion)
                } else if let problem = model.binaryProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Find Again") { Task { await model.resolveBinary() } }
            }

            // restic keeps one cache folder per repository it has opened
            // here and never removes one; the only user action that exists
            // is its own cleanup, so it lives where the restic facts sit —
            // with the cost said before it runs.
            Section("Cache") {
                resticCacheRows(model: model)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func resticCacheRows(model: AppModel) -> some View {
        switch model.resticCache {
        case let .measured(report):
            LabeledContent("Size") {
                Text("\(Format.bytes(report.totalBytes)) in \(Format.plural(report.count, "folder"))")
                    .textSelection(.enabled)
            }
            Text("One folder per repository restic has opened on this Mac. " + AppModel.unusedLine(report))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                // Where it is, as a button rather than a path to read.
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: report.directory)])
                }
                Button("Remove Caches Unused for \(ResticCacheReport.oldAfterDays) Days…") { isConfirmingCacheCleanup = true }
                    .disabled(report.oldCount == 0 || model.isWorkingOnResticCache)
                if model.isWorkingOnResticCache { ProgressView().controlSize(.small) }
                if let note = model.resticCacheNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .confirmationDialog(
                "Remove \(Format.plural(report.oldCount, "cache folder")) restic has not used for \(ResticCacheReport.oldAfterDays) days?",
                isPresented: $isConfirmingCacheCleanup,
                titleVisibility: .visible
            ) {
                Button("Remove") { Task { await model.cleanupResticCache() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "A repository still set up here loses its cache too if unused that long; restic rebuilds it next time. Nothing in any repository is touched."
                )
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Measure Again") { Task { await model.measureResticCache() } }
                .disabled(model.isWorkingOnResticCache)
        case nil:
            HStack {
                ProgressView().controlSize(.small)
                Text("Measuring…")
                    .foregroundStyle(.secondary)
            }
            .task { await model.measureResticCache() }
        }
    }
}

/// "Granted", "Not granted" or "Unknown", beside the glyph that says how it
/// stands. Colour on the glyph only — coloured caption text falls short of
/// the contrast small text needs — and the glyph hidden, since the word
/// says it.
private struct FullDiskAccessStatusLabel: View {
    let status: FullDiskAccessStatus

    var body: some View {
        HStack(spacing: 4) {
            switch status {
            case .granted:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
                    .accessibilityHidden(true)
            case .notGranted:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
            case .unknown:
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(status.displayName)
        }
    }
}


/// Webhook, chat and dead-man's-switch destinations.
struct NotificationChannelsTab: View {
    @Environment(AppModel.self) private var model
    @State private var selection: NotificationChannel.ID?
    @State private var testOutcome: AppModel.TestNotificationOutcome?
    @State private var isTesting = false
    @State private var isConfirmingRemove = false

    var body: some View {
        @Bindable var model = model

        // A stack, not a VSplitView: the split sized itself from its
        // panes' ideal sizes, so the empty state's 400 pt left bars beside
        // it in the 560 pt window, and a channel's Form — a scroll view,
        // ideal height next to nothing — got 16 pt under the list. The list
        // keeps a few rows; the channel's settings get the rest. With no
        // channel yet, the list is all there is: its frame fills the tab
        // and says what + adds.
        let channels = model.configuration.settings.notificationChannels
        VStack(spacing: 0) {
            EditableListFrame(
                isEmpty: channels.isEmpty,
                emptyTitle: "No webhooks",
                emptyHint: "Click + to add a webhook, a Slack or Discord channel, or a Healthchecks.io ping URL.",
                addTitle: "Add Webhook",
                removeTitle: "Remove Webhook",
                canRemove: selection != nil,
                onAdd: {
                    var channel = NotificationChannel()
                    channel.name = "New Webhook"
                    model.configuration.settings.notificationChannels.append(channel)
                    selection = channel.id
                },
                onRemove: { isConfirmingRemove = true }
            ) {
                List(selection: $selection) {
                    ForEach($model.configuration.settings.notificationChannels) { $channel in
                        HStack(spacing: 8) {
                            Toggle("", isOn: $channel.isEnabled)
                                .labelsHidden()
                                .controlSize(.mini)
                                .accessibilityLabel(channel.displayName)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(channel.displayName)
                                Text(channel.kind.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !channel.isUsable, channel.isEnabled {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(Theme.warning)
                                    .help("Enter a URL that starts with http:// or https://.")
                            }
                        }
                        .tag(channel.id)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            .frame(maxHeight: channels.isEmpty ? .infinity : 130)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            if !channels.isEmpty {
                detail(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // A channel is always open below the list while there is one, so
        // its settings never stand empty: the first on arrival, a neighbour
        // after a removal.
        .onAppear {
            if selection == nil { selection = channels.first?.id }
        }
        .confirmationDialog(
            "Remove this webhook?",
            isPresented: $isConfirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove") {
                let channels = model.configuration.settings.notificationChannels
                guard let index = channels.firstIndex(where: { $0.id == selection }) else { return }
                model.configuration.settings.notificationChannels.remove(at: index)
                let rest = model.configuration.settings.notificationChannels
                selection = rest.indices.contains(index) ? rest[index].id : rest.last?.id
                testOutcome = nil
            }
        } message: {
            Text("The webhook URL is removed from SwiftRestic. The destination itself — the Slack channel, the Healthchecks check — is not touched.")
        }
        .onChange(of: selection) { _, _ in
            // A test result belongs to the channel it was sent from; showing
            // it under another selection would bless an untested webhook.
            testOutcome = nil
            isTesting = false
        }
    }

    @ViewBuilder
    private func detail(model: AppModel) -> some View {
        @Bindable var model = model

        if let index = model.configuration.settings.notificationChannels
            .firstIndex(where: { $0.id == selection })
        {
            let channel = model.configuration.settings.notificationChannels[index]
            Form {
                TextField("Name", text: $model.configuration.settings.notificationChannels[index].name)
                Picker("Service", selection: $model.configuration.settings.notificationChannels[index].kind) {
                    ForEach(NotificationChannel.Kind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                TextField(
                    "URL",
                    text: $model.configuration.settings.notificationChannels[index].url,
                    prompt: Text(channel.kind.urlPrompt)
                )
                // The row's warning triangle has a reason; it is repeated here
                // where the user edits, not only on hover.
                if !channel.isUsable, channel.isEnabled {
                    Label("This webhook can't send until its URL starts with http:// or https://.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                        .font(.callout)
                }

                Section("Send when") {
                    Toggle(
                        "Succeeds",
                        isOn: $model.configuration.settings.notificationChannels[index].notifyOnSuccess
                    )
                    Toggle(
                        "Completes with warnings",
                        isOn: $model.configuration.settings.notificationChannels[index].notifyOnWarning
                    )
                    Toggle(
                        "Fails",
                        isOn: $model.configuration.settings.notificationChannels[index].notifyOnFailure
                    )
                    if channel.kind.usesStartPing {
                        ExpandableCaption(
                            summary: "Healthchecks is also pinged when a backup starts.",
                            detail: "That ping is what arms the timer it measures against, so a Mac that never wakes up still raises the alarm."
                        )
                    }
                }

                Section {
                    HStack {
                    Button("Send Test Notification") {
                        guard let channelID = selection else { return }
                        testOutcome = nil
                        isTesting = true
                        Task {
                            let outcome = await model.sendTestNotification(channel)
                            // A switch to another channel while in flight
                            // must not land this result — or kill another
                            // test's spinner — under the wrong channel.
                            guard selection == channelID else { return }
                            testOutcome = outcome
                            isTesting = false
                        }
                    }
                        .disabled(!channel.hasUsableURL || isTesting)
                        if isTesting {
                            ProgressView().controlSize(.small)
                        }
                    }
                    // The outcome belongs here, next to the button that caused
                    // it — a global banner would land on a different window
                    // than the Settings one the user is looking at.
                    switch testOutcome {
                    case .failed(let failure):
                        Label {
                            Text(failure)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "xmark.octagon.fill")
                        }
                        .foregroundStyle(Theme.danger)
                        .font(.callout)
                    case .delivered:
                        Label("Test sent to “\(channel.displayName)”.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success)
                            .font(.callout)
                    case nil:
                        EmptyView()
                    }
                    ExpandableCaption(
                        summary: "A failed notification is reported here but never changes what Activity says happened.",
                        detail: "The backup either ran or it did not."
                    )
                }
            }
            .formStyle(.grouped)
        } else {
            // Only while a click in the list's empty space has cleared the
            // selection.
            ContentUnavailableView(
                "No webhook selected",
                systemImage: "bell",
                description: Text("Select a webhook in the list to change it.")
            )
        }
    }
}
