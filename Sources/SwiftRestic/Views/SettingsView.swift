import SwiftUI

struct SettingsView: View {
    @State private var isConfirmingCacheCleanup = false
    @Environment(AppModel.self) private var model
    /// Arms the "you can strand the app" confirmation: menu bar item off and
    /// window closed leaves the scheduler running with no visible way back.
    @State private var isConfirmingMenuBarOff = false

    var body: some View {
        TabView {
            generalTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            NotificationChannelsTab()
                .environment(model)
                .tabItem { Label("Alerts", systemImage: "bell") }
            resticTab(model: model)
                .tabItem { Label("restic", systemImage: "terminal") }
        }
        .frame(minWidth: 560, idealWidth: 560, minHeight: 460, idealHeight: 500)
        .confirmationDialog(
            "Turn off the menu bar item?",
            isPresented: $isConfirmingMenuBarOff,
            titleVisibility: .visible
        ) {
            Button("Turn Off", role: .destructive) {
                model.configuration.settings.showMenuBarExtra = false
            }
        } message: {
            Text("Closing the main window afterwards leaves scheduled backups running with no visible way back into SwiftRestic — reopening means launching the app again. Keep the item on to always have a way in.")
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
                    Text("restic runs as part of SwiftRestic, so macOS's privacy protection doesn't keep your plans' data from it. Files your account can't read are still skipped.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Unknown is treated as missing, as the run hints do:
                    // nothing observable says the grant is there.
                    Text("Without it, macOS keeps Mail, Messages, Safari and other apps' data away from SwiftRestic and the restic it runs. Backups that include them finish with warnings.")
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
                    summary: "Closing the window never quits SwiftRestic — scheduled backups keep firing until you quit or log out.",
                    detail: "The menu bar item is how you get back to it. Its icon pulses while work is in progress (held still if you've turned on Reduce Motion), dims while backups are paused or waiting for power on battery, wears a warning mark while a run from the last seven days failed or completed with errors — a backup's until its plan's next backup succeeds — and asks with a question mark until a repository is set up."
                )
            }

            Section("Notifications") {
                Toggle("Notify when a backup succeeds", isOn: $model.configuration.settings.notifyOnSuccess)
                // What it gates (`AppModel.notify(about:)`), in the alert
                // channels' own event words.
                Toggle("Notify when a backup fails or finishes with warnings", isOn: $model.configuration.settings.notifyOnFailure)
                // A plan that never runs writes no failure to notify about:
                // an unplugged drive at every slot, a Mac asleep through them.
                Picker("Notify when a scheduled plan has not backed up for", selection: $model.configuration.settings.staleAlertDays) {
                    ForEach(StaleAlert.choices, id: \.self) { days in
                        Text(days == 0 ? "Never" : Format.plural(days, "day")).tag(days)
                    }
                }
                Text("Once per quiet stretch, until the plan's next successful backup. Checked every minute while SwiftRestic runs — a Mac asleep the whole time hears at its first check after waking. Paused and manual plans are never named, nor a plan that is running or starting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // The relationship between the two toggle layers, stated
                // where both are visible: these gate this Mac's notification
                // centre; the Alerts tab's channels carry their own
                // per-event switches, and neither gates the other.
                ExpandableCaption(
                    summary: "These switches control this Mac's notifications.",
                    detail: "Webhook and chat channels on the Alerts tab have their own per-event switches and don't follow them."
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
                .disabled(!LoginItem.isInInstallableLocation && !model.startsAtLogin)
                Text(LoginItem.isInInstallableLocation
                    ? LoginItem.statusDescription
                    : LoginItem.notInstalledMessage)
                    .font(.caption)
                    .foregroundStyle(LoginItem.needsApproval ? Theme.warning : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if LoginItem.needsApproval {
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
                            repositories: model.configuration.repositories
                        )
                    )
                } else {
                    LabeledContent("Next backup", value: "Nothing scheduled")
                }
            }

            Section("History") {
                Stepper(value: $model.configuration.settings.maxRunHistory, in: 20 ... 2000, step: 20) {
                    LabeledContent("Keep runs", value: "\(model.configuration.settings.maxRunHistory)")
                }
                // The trim's exemption (`OverviewMetrics.standingProblemIDs`).
                Text("A problem that still stands is kept past this number: a plan's until a backup fixes it, any other for a week.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                        prompt: Text(model.resticPath.isEmpty ? "Searching the usual locations" : model.resticPath)
                    )
                    Button("Choose…") {
                        if let url = FilePicker.chooseExecutable() {
                            model.configuration.settings.resticPathOverride = url.path
                        }
                    }
                }
                if model.isResticAvailable {
                    LabeledContent("Using", value: model.resticPath)
                    LabeledContent("Version", value: model.resticVersion.isEmpty ? "—" : model.resticVersion)
                } else if let problem = model.binaryProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Re-detect") { Task { await model.resolveBinary() } }
            }

            // restic keeps one cache folder per repository it has opened
            // here and never removes one; the only user action that exists
            // is its own cleanup, so it lives where the restic facts sit —
            // with the cost said before it runs.
            Section("Cache") {
                resticCacheRows(model: model)
            }

            Section("Bandwidth") {
                // Typeable, not steppers. Values are clamped on commit; the
                // assignment itself refreshes the field even when the clamp
                // lands on the value it already held.
                TextField(
                    "Upload limit (KiB/s, 0 for unlimited)",
                    value: clampedLimit($model.configuration.settings.uploadLimitKiBps),
                    format: .number.grouping(.never)
                )
                TextField(
                    "Download limit (KiB/s, 0 for unlimited)",
                    value: clampedLimit($model.configuration.settings.downloadLimitKiBps),
                    format: .number.grouping(.never)
                )
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
            Text(
                "At \((report.directory as NSString).abbreviatingWithTildeInPath): one folder per repository restic has opened on this Mac, kept after a repository is removed here. "
                    + AppModel.unusedLine(report)
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
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
                Button("Remove", role: .destructive) { Task { await model.cleanupResticCache() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "A repository still set up here loses its cache too when it went unused that long — a drive away for a month, for instance. restic rebuilds it the next time it opens that repository, over the network for a remote one. Nothing inside any repository is touched."
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

    /// Keeps the typed value inside restic's accepted range: out-of-range
    /// input is corrected on commit, never mid-keystroke.
    private func clampedLimit(_ binding: Binding<Int>) -> Binding<Int> {
        Binding(
            get: { binding.wrappedValue },
            set: { binding.wrappedValue = min(1_000_000, max(0, $0)) }
        )
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

        VSplitView {
            VStack(spacing: 6) {
                List(selection: $selection) {
                    ForEach($model.configuration.settings.notificationChannels) { $channel in
                        HStack(spacing: 8) {
                            Toggle("", isOn: $channel.isEnabled)
                                .labelsHidden()
                                .controlSize(.mini)
                                .accessibilityLabel("Enable \(channel.displayName)")
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
                                    .help("The URL is missing or not http(s)")
                            }
                        }
                        .tag(channel.id)
                    }
                }
                .frame(minHeight: 110)

                HStack {
                    Button("Add") {
                        var channel = NotificationChannel()
                        channel.name = "New alert"
                        model.configuration.settings.notificationChannels.append(channel)
                        selection = channel.id
                    }
                    Button("Remove") { isConfirmingRemove = true }
                        .disabled(selection == nil)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }

            detail(model: model)
        }
        .confirmationDialog(
            "Remove this alert channel?",
            isPresented: $isConfirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                model.configuration.settings.notificationChannels.removeAll { $0.id == selection }
                selection = nil
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
                    Label("This channel cannot fire: the URL is missing or not http(s).", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                        .font(.callout)
                }

                Section("Send when a run") {
                    Toggle(
                        "Succeeds",
                        isOn: $model.configuration.settings.notificationChannels[index].notifyOnSuccess
                    )
                    Toggle(
                        "Finishes with warnings",
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
                        .disabled(!channel.isUsable || isTesting)
                        if isTesting {
                            ProgressView().controlSize(.small)
                        }
                    }
                    // The outcome belongs here, next to the button that caused
                    // it — a global banner would land on a different window
                    // than the Settings one the user is looking at.
                    switch testOutcome {
                    case .unusable:
                        Label("That URL does not look usable.", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(Theme.danger)
                            .font(.callout)
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
                        summary: "A failed notification is reported here but never changes what the run history says happened.",
                        detail: "The backup either ran or it did not."
                    )
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(
                "No alert selected",
                systemImage: "bell",
                description: Text("Add a webhook, a Slack or Discord channel, or a Healthchecks.io ping URL.")
            )
        }
    }
}
