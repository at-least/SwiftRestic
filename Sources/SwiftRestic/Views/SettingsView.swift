import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        TabView {
            generalTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            NotificationChannelsTab()
                .environment(model)
                .tabItem { Label("Alerts", systemImage: "bell") }
            resticTab(model: model)
                .tabItem { Label("restic", systemImage: "terminal") }
        }
        .frame(width: 560, height: 500)
        .task { model.refreshLoginItemStatus() }
        // Approving a login item happens in System Settings, so the only signal
        // that it went through is the user coming back to this app.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            model.refreshLoginItemStatus()
        }
    }

    private func generalTab(model: AppModel) -> some View {
        @Bindable var model = model
        return Form {
            Section("Menu bar") {
                Toggle("Show SwiftRestic in the menu bar", isOn: $model.configuration.settings.showMenuBarExtra)
                Text("The menu bar item keeps SwiftRestic running so scheduled backups can fire.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Notifications") {
                Toggle("Notify when a backup succeeds", isOn: $model.configuration.settings.notifyOnSuccess)
                Toggle("Notify when a backup fails", isOn: $model.configuration.settings.notifyOnFailure)
            }

            Section("Scheduling") {
                Toggle("Start SwiftRestic at login", isOn: Binding(
                    get: { model.startsAtLogin },
                    set: { model.setStartsAtLogin($0) }
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
                if let next = model.nextScheduledRun {
                    LabeledContent("Next run", value: "\(next.plan.name) — \(Format.timestamp(next.date))")
                } else {
                    LabeledContent("Next run", value: "Nothing scheduled")
                }
            }

            Section("History") {
                Stepper(value: $model.configuration.settings.maxRunHistory, in: 20 ... 2000, step: 20) {
                    LabeledContent("Keep runs", value: "\(model.configuration.settings.maxRunHistory)")
                }
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

            Section("Bandwidth") {
                Stepper(value: $model.configuration.settings.uploadLimitKiBps, in: 0 ... 1_000_000, step: 256) {
                    LabeledContent(
                        "Upload limit",
                        value: limitText(model.configuration.settings.uploadLimitKiBps)
                    )
                }
                Stepper(value: $model.configuration.settings.downloadLimitKiBps, in: 0 ... 1_000_000, step: 256) {
                    LabeledContent(
                        "Download limit",
                        value: limitText(model.configuration.settings.downloadLimitKiBps)
                    )
                }
            }

            Section("Full Disk Access") {
                Text(
                    "macOS asks for permission before any app reads ~/Documents, ~/Desktop and similar folders. Granting SwiftRestic Full Disk Access in System Settings › Privacy & Security avoids repeated prompts and silently skipped files."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy & Security") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func limitText(_ value: Int) -> String {
        value == 0 ? "Unlimited" : "\(value) KiB/s"
    }
}


/// Webhook, chat and dead-man's-switch destinations.
struct NotificationChannelsTab: View {
    @Environment(AppModel.self) private var model
    @State private var selection: NotificationChannel.ID?

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
                    Button("Remove") {
                        model.configuration.settings.notificationChannels.removeAll { $0.id == selection }
                        selection = nil
                    }
                    .disabled(selection == nil)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }

            detail(model: model)
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
                        Text("Healthchecks is also pinged when a backup starts — that is what arms the timer it measures against, so a Mac that never wakes up still raises the alarm.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section {
                    Button("Send Test Notification") { model.sendTestNotification(channel) }
                        .disabled(!channel.isUsable)
                    Text("A failed notification is reported here but never changes what the run history says happened — the backup either ran or it did not.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
