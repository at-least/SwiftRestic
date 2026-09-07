import SwiftUI

/// The restic vocabulary the app assumes, in one place: the terms the
/// critiques kept flagging as unexplained (prune vs forget, blobs, locks)
/// with the app's own framing, plus the way out to the real documentation.
struct ConceptsView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Concept: Identifiable {
        let term: String
        let definition: String
        var id: String { term }
    }

    private let concepts: [Concept] = [
        Concept(
            term: "Snapshot",
            definition: "One completed backup — a frozen copy of your folders at a moment in time. Snapshots are never partial: a failed run writes nothing."
        ),
        Concept(
            term: "Repository",
            definition: "Where snapshots live: a local folder, another machine over SSH, or cloud storage. Everything restic restores comes from one."
        ),
        Concept(
            term: "Plan",
            definition: "What gets backed up, on what schedule, with what retention. Each plan stamps its snapshots with an ID tag so its history stays separate."
        ),
        Concept(
            term: "Retention",
            definition: "How much history to keep: the newest runs plus bucket rules by hour, day, week, month and year. The editor projects how many snapshots survive."
        ),
        Concept(
            term: "forget",
            definition: "Removes snapshots from the repository's index. Their data stays on disk until prune reclaims it — deleting a snapshot is reversible until then."
        ),
        Concept(
            term: "Prune",
            definition: "Rewrites the repository to reclaim the space of deleted snapshots. Slow, and it locks the repository exclusively — backups to it are held back until it finishes."
        ),
        Concept(
            term: "Check",
            definition: "Verifies the repository's integrity. Structure checks are fast; reading more of the data finds more problems at the cost of time."
        ),
        Concept(
            term: "Blobs",
            definition: "The chunks your files are split into, encrypted, and stored as. You usually meet this word when a repository reports damage."
        ),
        Concept(
            term: "Locks",
            definition: "restic locks a repository while working. A lock left behind by a crashed process is stale and safe to remove — unless restic is genuinely running elsewhere right now."
        ),
        Concept(
            term: "Host and paths",
            definition: "Snapshots remember which Mac and which folders they came from. Compare defaults to the same host and paths so a diff means something."
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SwiftRestic concepts")
                    .font(.title2.weight(.semibold))
                Text("The restic vocabulary the app assumes, in plain terms.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 16)

            List(concepts) { concept in
                VStack(alignment: .leading, spacing: 3) {
                    Text(concept.term)
                        .font(.headline)
                    Text(concept.definition)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 3)
            }
            .listStyle(.inset)

            HStack {
                Link("restic documentation", destination: URL(string: "https://restic.readthedocs.io")!)
                Text("The app pins its decoding to restic 0.19.1's output.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 520)
    }
}
