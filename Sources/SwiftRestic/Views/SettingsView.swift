import SwiftUI

struct SettingsView: View {
    private static let width: CGFloat = 560
    /// Past this a pane scrolls: its webhooks can outgrow a small screen.
    private static let maxHeight: CGFloat = 620
    /// Not the old "lastSettingsPane": it can hold the restic pane, now gone.
    private static let paneKey = "lastSettingsTab"
    /// The pane the window reopens on. UserDefaults, not
    /// `configuration.settings`: it is window state, not a preference.
    @AppStorage(Self.paneKey) private var lastSettingsPane = 0
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            // General only while it has something for the user to do;
            // otherwise Settings is the Notifications pane, with no tab bar.
            if needsFullDiskAccess || model.loginItemNeedsApproval {
                TabView(selection: $lastSettingsPane) {
                    pane(generalTab(model: model))
                        .tag(0)
                        .tabItem { Label("General", systemImage: "gearshape") }
                    pane(NotificationsTab())
                        .tag(1)
                        .tabItem { Label("Notifications", systemImage: "bell") }
                }
            } else {
                pane(NotificationsTab())
            }
        }
        .task {
            await model.refreshFullDiskAccess()
            await model.refreshLoginItemStatus()
        }
    }

    /// Unknown is treated as missing, as the run hints do: nothing
    /// observable says the grant is there.
    private var needsFullDiskAccess: Bool { model.fullDiskAccess != .granted }

    /// Each pane at its own height, the window following it (the Settings
    /// scene's `.contentSize`): the HIG's "a settings window accommodates
    /// the size of the current pane", no pane scrolling.
    private func pane(_ content: some View) -> some View {
        content
            .environment(model)
            .frame(width: Self.width)
            .frame(maxHeight: Self.maxHeight)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func generalTab(model: AppModel) -> some View {
        @Bindable var model = model
        return Form {
            // First: it is the app's permission, and restic inherits it.
            if needsFullDiskAccess {
                Section("Full Disk Access") {
                    LabeledContent("Status") {
                        FullDiskAccessStatusLabel(status: model.fullDiskAccess)
                    }
                    Text("Without it, Mail, Messages, Safari and other apps’ data can’t be read, and backups that include them end with warnings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    FullDiskAccessButton()
                    ExpandableCaption(
                        summary: "Turn on SwiftRestic in the list. macOS asks for an administrator password.",
                        detail: "If SwiftRestic is not in the list, click + and choose it from your Applications folder. If it is already on and this still says Not granted, turn it off and on again: a rebuilt or updated copy of SwiftRestic may not inherit the permission. If that doesn’t help, quit and reopen SwiftRestic."
                    )
                }
            }

            // No switch: the app starts at login while a plan has a
            // schedule (`LoginItem.change`). Only the step macOS leaves to
            // the user shows here.
            if model.loginItemNeedsApproval {
                Section("Scheduling") {
                    WarningLine(text: LoginItem.approvalNeeded)
                        .font(.caption)
                    Button("Open Login Items") { LoginItem.openLoginItemsSettings() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Quiet when granted. Colour on the glyph only: coloured caption text falls
/// short of the contrast small text needs.
/// Shown only while access is not granted (`needsFullDiskAccess`).
private struct FullDiskAccessStatusLabel: View {
    let status: FullDiskAccessStatus

    var body: some View {
        HStack(spacing: 4) {
            if status == .notGranted {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(status.displayName)
        }
    }
}

/// macOS notifications, and whatever else should hear: one list of addresses.
private struct NotificationsTab: View {
    @Environment(AppModel.self) private var model
    @State private var testOutcomes: [NotificationChannel.ID: AppModel.TestNotificationOutcome] = [:]
    @State private var testing: Set<NotificationChannel.ID> = []
    @State private var removing: NotificationChannel?
    @State private var newChannel: NotificationChannel?

    private func addNewChannel() {
        guard let channel = newChannel, channel.hasUsableURL else { return }
        model.configuration.settings.notificationChannels.append(channel)
        newChannel = nil
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Notify when a backup succeeds", isOn: $model.configuration.settings.notifyOnSuccess)
                Text("Successes go to macOS notifications and to the addresses below. SwiftRestic always tells you when a backup fails, or when a scheduled plan has not backed up for \(StaleAlert.thresholdDays) days. A failure that repeats with the same cause notifies once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach($model.configuration.settings.notificationChannels) { $channel in
                Section {
                    channelRows($channel)
                }
            }
            // Saved only once its address can send: a blank one would sit in
            // the configuration doing nothing.
            if let newChannel = Binding($newChannel) {
                Section {
                    TextField("Address", text: newChannel.url, prompt: Text("https://…"))
                        .onSubmit(addNewChannel)
                    if !newChannel.wrappedValue.url.isEmpty, !newChannel.wrappedValue.hasUsableURL {
                        WarningLine(text: "This address can’t be used until it starts with http:// or https://.")
                            .font(.callout)
                    }
                    HStack {
                        Spacer()
                        Button("Cancel") { self.newChannel = nil }
                        Button("Add Address", action: addNewChannel)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!newChannel.wrappedValue.hasUsableURL)
                    }
                }
            } else {
                Section {
                    Button("Add Notification Address") { newChannel = NotificationChannel() }
                    Text("Paste a Slack, Discord or Healthchecks address, or any webhook.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Remove “\(removing?.displayName ?? "")”?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { channel in
            Button("Remove") {
                model.configuration.settings.notificationChannels.removeAll { $0.id == channel.id }
                testOutcomes[channel.id] = nil
            }
        } message: { _ in
            Text("Only the address leaves SwiftRestic. The Slack channel or Healthchecks check it points to is not touched.")
        }
    }

    @ViewBuilder
    private func channelRows(_ channel: Binding<NotificationChannel>) -> some View {
        let current = channel.wrappedValue
        // The address names its service (`NotificationChannel.Kind`).
        TextField("Address", text: channel.url, prompt: Text("https://…"))
            .onChange(of: current.url) { _, _ in testOutcomes[current.id] = nil }
        if !current.url.isEmpty, !current.hasUsableURL {
            WarningLine(text: "This address can’t be used until it starts with http:// or https://.")
                .font(.callout)
        }
        if current.kind.usesStartPing {
            ExpandableCaption(
                summary: "Healthchecks hears every backup: when it starts and how it ends.",
                detail: "The start is what arms the timer it measures against, so a Mac that never wakes up still raises the alarm."
            )
        }
        HStack {
            Button("Send Test") { sendTest(current) }
                .disabled(!current.hasUsableURL || testing.contains(current.id))
            if testing.contains(current.id) {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Remove") { removing = current }
        }
        // Here, next to the button that caused it: a global banner would land
        // on a different window than this one.
        switch testOutcomes[current.id] {
        case let .failed(failure):
            Label {
                Text("Couldn’t send the test: " + failure)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(Theme.danger)
            }
            .font(.callout)
        case .delivered:
            Text("Test sent to “\(current.displayName)”.")
                .foregroundStyle(.secondary)
                .font(.callout)
        case nil:
            EmptyView()
        }
    }

    private func sendTest(_ channel: NotificationChannel) {
        testOutcomes[channel.id] = nil
        testing.insert(channel.id)
        Task {
            let outcome = await model.sendTestNotification(channel)
            testOutcomes[channel.id] = outcome
            testing.remove(channel.id)
        }
    }
}
