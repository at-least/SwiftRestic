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
            text: "Click Back Up a Folder, choose the folder, a disk and a password, and click Back Up. Its first backup starts right away, then it runs on its schedule while SwiftRestic is open. For another folder, choose File ▸ Back Up a Folder."
        ),
        Topic(
            title: "Get a file back",
            text: "Choose Edit ▸ Find (⌘F) and type its name. Or open the plan’s Backups tab, pick a backup in the list, and select the file: its earlier versions appear below. Click Restore to put it back where it was, or choose File ▸ Restore To… to pick a folder. To bring back everything from one moment, select the backup’s top folders and click Restore."
        ),
        Topic(
            title: "When a backup fails",
            text: "Activity lists every backup, restore, verification and freeing of space. Select one to see what happened, with a button for the fix when there is one. Edit ▸ Copy copies its details. A backup that couldn’t read some files still saves the rest and is marked Some files skipped."
        ),
        Topic(
            title: "Keep old backups tidy",
            text: "After each backup, SwiftRestic removes old backups, then frees the space they held. Verify Backups, in the Location menu, makes sure nothing is damaged. SwiftRestic verifies each location every week on its own."
        ),
        Topic(
            title: "Backups from elsewhere",
            text: "Backups no plan here made, from another Mac or a removed plan, appear under Other backups in the sidebar. Those a SwiftRestic plan made can continue on this Mac with Continue Backups, keeping their history."
        ),
    ]

    private let terms: [Topic] = [
        Topic(title: "Backup Location", text: "Where backups are kept: a disk, another computer, or cloud storage. Everything in it is encrypted with its password. restic calls it a repository."),
        Topic(title: "Backup Plan", text: "One folder, the backup location it backs up to, and when."),
        Topic(title: "Backup", text: "The folder as it was at one moment. restic calls it a snapshot."),
        Topic(title: "Freeing space", text: "Frees the space of removed backups, on its own. Slow; backups to the location wait for it."),
        Topic(title: "Verification", text: "Makes sure a location’s backups are sound."),
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
