import SwiftUI

struct SettingsView: View {
    private static let width: CGFloat = 560
    /// Past this a pane scrolls: its webhooks can outgrow a small screen.
    private static let maxHeight: CGFloat = 620
    /// Not the old "lastSettingsPane": it can hold the restic pane, now gone.
    static let paneKey = "lastSettingsTab"
    /// The pane the window reopens on. UserDefaults, not
    /// `configuration.settings`: it is window state, not a preference.
    @AppStorage(Self.paneKey) private var lastSettingsPane = 0
    @Environment(AppModel.self) private var model
    @State private var removingShare: NetworkShare?

    /// The login switch's caption: what it means while off, in the plan
    /// editor's words. The model's copies of the daemon's answer: a read
    /// here would be an XPC round trip on every render. The needsApproval
    /// state keeps its short form — the button below opens the pane, and
    /// the banner's full form has no button to point with.
    private var loginCaption: String? {
        guard model.loginItemInstallable else { return LoginItem.notInstalledMessage }
        switch model.loginItemState {
        case .enabled: return nil
        case .off: return LoginItemAdvice.caption(for: .startAtLogin)
        case .needsApproval: return LoginItem.needsApprovalShort
        case .notFound: return LoginItem.description(of: .notFound)
        }
    }

    var body: some View {
        // Each pane at its own height, the window following it (the
        // Settings scene's `.contentSize`): the HIG's "a settings window
        // accommodates the size of the current pane", no pane scrolling.
        TabView(selection: $lastSettingsPane) {
            generalTab(model: model)
                .frame(width: Self.width)
                .frame(maxHeight: Self.maxHeight)
                .fixedSize(horizontal: false, vertical: true)
                .tag(0)
                .tabItem { Label("General", systemImage: "gearshape") }
            NotificationsTab()
                .environment(model)
                .frame(width: Self.width)
                .frame(maxHeight: Self.maxHeight)
                .fixedSize(horizontal: false, vertical: true)
                .tag(1)
                .tabItem { Label("Notifications", systemImage: "bell") }
        }
        .confirmationDialog(
            "Remove “\(removingShare?.url ?? "")” from SwiftRestic?",
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
                            title: "Couldn’t remove the password for “\(share.url)”",
                            message: error.localizedDescription,
                            isError: true
                        ))
                    }
                }
            }
        } message: { share in
            Text("Its saved password is deleted too. A backup that needs \(share.url) is skipped while it is not mounted, until its password is entered again in the location’s or plan’s editor.")
        }
        .task {
            await model.refreshFullDiskAccess()
            await model.refreshLoginItemStatus()
        }
    }

    private func generalTab(model: AppModel) -> some View {
        @Bindable var model = model
        return Form {
            // First: it is the app's permission, and restic inherits it.
            Section("Full Disk Access") {
                LabeledContent("Status") {
                    FullDiskAccessStatusLabel(status: model.fullDiskAccess)
                }
                if model.fullDiskAccess != .granted {
                    // Unknown is treated as missing, as the run hints do:
                    // nothing observable says the grant is there.
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

            Section("Scheduling") {
                Toggle("Start SwiftRestic at login", isOn: Binding(
                    get: { model.startsAtLogin },
                    // Optimistic flip, as the plan editor's Start at Login:
                    // the model var moves now, and the daemon's answer
                    // confirms or corrects it.
                    set: { value in model.requestStartsAtLogin(value) }
                ))
                .disabled(!model.loginItemInstallable && !model.startsAtLogin)
                // Nothing while it starts at login: the switch says so.
                if let caption = loginCaption {
                    if model.loginItemNeedsApproval {
                        WarningLine(text: caption)
                            .font(.caption)
                    } else {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if model.loginItemNeedsApproval {
                    Button("Open Login Items") { LoginItem.openLoginItemsSettings() }
                }
            }

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

        }
        .formStyle(.grouped)
    }
}

/// Quiet when granted. Colour on the glyph only: coloured caption text falls
/// short of the contrast small text needs.
private struct FullDiskAccessStatusLabel: View {
    let status: FullDiskAccessStatus

    var body: some View {
        HStack(spacing: 4) {
            switch status {
            case .granted:
                EmptyView()
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

/// macOS notifications, and whatever else should hear: one list of addresses.
struct NotificationsTab: View {
    @Environment(AppModel.self) private var model
    @State private var testOutcomes: [NotificationChannel.ID: AppModel.TestNotificationOutcome] = [:]
    @State private var testing: Set<NotificationChannel.ID> = []
    @State private var removing: NotificationChannel?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Notify when a backup succeeds", isOn: $model.configuration.settings.notifyOnSuccess)
                Text("SwiftRestic always tells you when a backup fails, or when a scheduled plan has not backed up for \(StaleAlert.thresholdDays) days. A failure that repeats with the same cause notifies once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach($model.configuration.settings.notificationChannels) { $channel in
                Section {
                    channelRows($channel)
                }
            }
            Section {
                Button("Add Webhook") { model.configuration.settings.notificationChannels.append(NotificationChannel()) }
                Text("A webhook, a Slack or Discord channel, or a Healthchecks.io ping URL.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Text("The destination itself — the Slack channel, the Healthchecks check — is not touched.")
        }
    }

    @ViewBuilder
    private func channelRows(_ channel: Binding<NotificationChannel>) -> some View {
        let current = channel.wrappedValue
        TextField("URL", text: channel.url, prompt: Text(current.kind.urlPrompt))
            .onChange(of: current.url) { _, url in
                testOutcomes[current.id] = nil
                if let kind = NotificationChannel.Kind(inferringFrom: url) { channel.wrappedValue.kind = kind }
            }
        // An address that names its service has already set it.
        if NotificationChannel.Kind(inferringFrom: current.url) == nil {
            Picker("Service", selection: channel.kind) {
                ForEach(NotificationChannel.Kind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
        }
        if !current.url.isEmpty, !current.hasUsableURL {
            WarningLine(text: "This webhook can’t send until its URL starts with http:// or https://.")
                .font(.callout)
        }
        if current.kind.usesStartPing {
            ExpandableCaption(
                summary: "Healthchecks hears every backup: when it starts and how it ends.",
                detail: "The start is what arms the timer it measures against, so a Mac that never wakes up still raises the alarm."
            )
        } else {
            Toggle("Also send successes", isOn: channel.notifyOnSuccess)
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
