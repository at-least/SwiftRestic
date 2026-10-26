import SwiftUI

/// Help ▸ SwiftRestic Help's window, whose own close button and ⌘W close
/// it: how to do the few things the app is for, each in the menu's and the
/// buttons' own words, then the handful of terms the app uses — with a link
/// out to restic's documentation for the rest.
struct ConceptsView: View {
    private struct Topic: Identifiable {
        let title: String
        let text: String
        var id: String { title }
    }

    private let tasks: [Topic] = [
        Topic(
            title: "Back up a folder",
            text: "Choose File ▸ New Backup Plan, pick the folder and a repository, and click Create Plan. Its first backup starts within a minute; after that it runs on its schedule while SwiftRestic is open."
        ),
        Topic(
            title: "Get a file back",
            text: "Select the file on the plan’s Files tab and click Restore to put it back. Repository ▸ Find Files finds a file by name in every backup. To bring back everything from one moment, open the backup on the Backups tab, select its top folders, and click Restore."
        ),
        Topic(
            title: "When a backup fails",
            text: "Activity lists every backup, retention, check, cleanup and restore. Select one to see what happened, with Show Log and Copy Details below it — and a button for the fix, when there is one. A backup that couldn’t read some files still saves the rest and is marked Completed with warnings."
        ),
        Topic(
            title: "Keep the history tidy",
            text: "Retention, on the plan editor’s Retention tab, removes old backups after each one. The space they held is freed by a cleanup: Repository ▸ Clean Up Now, or the repository’s periodic cleanup. Repository ▸ Check Now verifies that nothing is damaged."
        ),
        Topic(
            title: "Backups from elsewhere",
            text: "Backups no plan here made — another Mac’s, or a deleted plan’s — appear under Other backups in the sidebar. Those a SwiftRestic plan made can continue on this Mac with Continue Backups…, keeping their history."
        ),
    ]

    private let terms: [Topic] = [
        Topic(title: "Repository", text: "Where backups are kept: a drive, another computer, or cloud storage. Everything in it is encrypted with its password."),
        Topic(title: "Plan", text: "One folder, the repository it backs up to, and when."),
        Topic(title: "Backup", text: "The folder as it was at one moment. restic calls it a snapshot."),
        Topic(title: "Retention", text: "Which backups to keep — the latest ones, and one per hour, day, week, month or year."),
        Topic(title: "Cleanup", text: "Frees the space of removed backups. Slow; backups to the repository wait for it."),
        Topic(title: "Check", text: "Verifies the repository. Reading data back finds more damage, and takes longer."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // A page to read, not a list to select from.
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("How to")
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(tasks) { topic in row(topic) }
                    Divider()
                    Text("Terms")
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(terms) { topic in row(topic) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            Divider()

            HStack {
                Link("restic documentation", destination: AppLinks.documentation)
                Spacer()
            }
            .padding(12)
        }
        .frame(minWidth: 440, idealWidth: 460, minHeight: 480, idealHeight: 520)
    }

    private func row(_ topic: Topic) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(topic.title)
                .font(.headline)
            Text(topic.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
