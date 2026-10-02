import Foundation
import Testing

/// The destination sheet's rules: where "Original location" is, where each
/// restore lands, and when Replace has to ask first. Pure, with the file
/// system injected, so the paths here never need to exist.
@Suite("restore destination rules")
struct RestoreDestinationTests {
    private func original(
        _ subject: RestoreSubject,
        existing: Set<String> = ["/Users/x/Documents"],
        writable: Set<String> = ["/Users/x/Documents"]
    ) -> OriginalLocation {
        RestoreDestinationRules.originalLocation(
            for: subject,
            directoryExists: { existing.contains($0) },
            isWritable: { writable.contains($0) }
        )
    }

    private static let badPath = "This item's recorded path can't be used as a location on this Mac."

    @Test("original location resolves only to exactly the recorded path on this Mac")
    func originalLocationGate() {
        let project = RestoreSubject.item(name: "Project", path: "/Users/x/Documents/Project", isDirectory: true)
        guard case let .available(directories, landings) = original(project) else {
            Issue.record("expected available, got \(original(project))")
            return
        }
        #expect(directories.map(\.path) == ["/Users/x/Documents"])
        #expect(landings.map(\.path) == ["/Users/x/Documents/Project"])
        // The item lands exactly where it was: the one landing rule, applied
        // to the parent, gives back the recorded path.
        #expect(RestoreDestinationRules.landings(for: project, into: directories) == landings)

        #expect(original(project, existing: []) == .unavailable(reason: "“/Users/x/Documents” isn't on this Mac."))
        #expect(original(project, writable: []) == .unavailable(reason: "SwiftRestic can't write to “/Users/x/Documents”."))

        // Paths that would land somewhere other than where they claim to be,
        // or nowhere at all.
        #expect(original(.item(name: "..", path: "/a/..", isDirectory: true), existing: ["/a"], writable: ["/a"])
            == .unavailable(reason: Self.badPath))
        #expect(original(.item(name: "c", path: "/a/../b/c", isDirectory: false), existing: ["/a/../b", "/b"], writable: ["/a/../b", "/b"])
            == .unavailable(reason: Self.badPath))
        #expect(original(.item(name: "/", path: "/", isDirectory: true), existing: ["/"], writable: ["/"])
            == .unavailable(reason: Self.badPath))
        #expect(original(.item(name: "a.txt", path: "relative/a.txt", isDirectory: false), existing: ["relative"], writable: ["relative"])
            == .unavailable(reason: Self.badPath))
        // A name the landing rule would rewrite: restoring it "in place"
        // would write beside the item, not over it.
        #expect(original(.item(name: "other", path: "/Users/x/Documents/Project", isDirectory: true))
            == .unavailable(reason: Self.badPath))
        // No filesystem normalisation: /private/tmp must stay /private/tmp
        // (NSString.standardizingPath would answer /tmp and fail the gate).
        let privateTmp = original(
            .item(name: "Project", path: "/private/tmp/p/Project", isDirectory: true),
            existing: ["/private/tmp/p"],
            writable: ["/private/tmp/p"]
        )
        guard case let .available(tmpDirectories, tmpLandings) = privateTmp else {
            Issue.record("expected available, got \(privateTmp)")
            return
        }
        #expect(tmpDirectories.map(\.path) == ["/private/tmp/p"])
        #expect(tmpLandings.map(\.path) == ["/private/tmp/p/Project"])

        #expect(original(.wholeSnapshot(paths: ["/Users/x/Documents"]))
            == .unavailable(reason: "A whole backup can't be put back in one step. Select a folder in it and restore that to its original location."))

        // A combining mark right after the separator: a Character-level split
        // would merge it into the "/" and lose the name.
        let combining = RestoreSubject.item(name: "\u{0301}leading.txt", path: "/Users/x/Documents/\u{0301}leading.txt", isDirectory: false)
        guard case let .available(_, combiningLandings) = original(combining) else {
            Issue.record("expected available, got \(original(combining))")
            return
        }
        #expect(combiningLandings.map(\.lastPathComponent) == ["\u{0301}leading.txt"])
    }

    @Test("several items go back each into its own folder, or not at all")
    func originalLocationOfSeveral() {
        let items = RestoreSubject.items([
            RestoreItem(name: "a.txt", path: "/Users/x/Documents/a.txt", isDirectory: false),
            RestoreItem(name: "Trip", path: "/Users/x/Pictures/Trip", isDirectory: true),
        ])
        let both: Set<String> = ["/Users/x/Documents", "/Users/x/Pictures"]
        #expect(original(items, existing: both, writable: both) == .available(
            directories: [URL(fileURLWithPath: "/Users/x/Documents", isDirectory: true),
                          URL(fileURLWithPath: "/Users/x/Pictures", isDirectory: true)],
            landings: [URL(fileURLWithPath: "/Users/x/Documents/a.txt"),
                       URL(fileURLWithPath: "/Users/x/Pictures/Trip")]
        ))
        // One that cannot go back stops them all, and is named.
        #expect(original(items, existing: both, writable: ["/Users/x/Documents"])
            == .unavailable(reason: "“Trip”: SwiftRestic can't write to “/Users/x/Pictures”."))
        #expect(items.directoryCount == 2)
        #expect(RestoreSubject.item(name: "a", path: "/a", isDirectory: false).directoryCount == 1)
        #expect(RestoreSubject.wholeSnapshot(paths: ["/a", "/b"]).directoryCount == 1)
    }

    @Test("landings and replace-confirmation targets")
    func landingsAndConfirmation() {
        let destination = URL(fileURLWithPath: "/dest", isDirectory: true)
        #expect(RestoreDestinationRules.landings(
            for: .item(name: "Photos", path: "/Users/x/Photos", isDirectory: true), into: [destination]
        ).map(\.path) == ["/dest/Photos"])
        // A hostile name from a shared repository stays inside the destination.
        #expect(RestoreDestinationRules.landings(
            for: .item(name: "a/../../x", path: "/p/x", isDirectory: false), into: [destination]
        ).map(\.path) == ["/dest/x"])
        #expect(RestoreDestinationRules.landings(
            for: .wholeSnapshot(paths: ["/p/A", "/p/B"]), into: [destination]
        ).map(\.path) == ["/dest/p/A", "/dest/p/B"])
        // Several items: each in its own directory, by the same rule.
        #expect(RestoreDestinationRules.landings(
            for: .items([
                RestoreItem(name: "a.txt", path: "/p/a.txt", isDirectory: false),
                RestoreItem(name: "Trip", path: "/q/Trip", isDirectory: true),
            ]),
            into: [destination, URL(fileURLWithPath: "/q", isDirectory: true)]
        ).map(\.path) == ["/dest/a.txt", "/q/Trip"])

        let landings = [URL(fileURLWithPath: "/dest/p/A"), URL(fileURLWithPath: "/dest/p/B")]
        // Keep never asks: nothing is replaced, whatever is there.
        #expect(RestoreDestinationRules.replaceConfirmationTargets(
            policy: .keepExisting, landings: landings, exists: { _ in true }
        ).isEmpty)
        #expect(RestoreDestinationRules.replaceConfirmationTargets(
            policy: .replaceExisting, landings: landings, exists: { $0.path == "/dest/p/B" }
        ).map(\.path) == ["/dest/p/B"])
        #expect(RestoreDestinationRules.replaceConfirmationTargets(
            policy: .replaceExisting, landings: landings, exists: { _ in false }
        ).isEmpty)
    }

    @Test("the existence check sees a dangling symlink")
    func existenceIsLstat() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticDestination-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/nonexistent-\(UUID().uuidString)")

        // fileExists follows the link and answers no; the landing is still
        // taken — a rename or a restore over it would replace the link.
        #expect(!FileManager.default.fileExists(atPath: link.path))
        #expect(RestoreDestinationRules.itemExists(at: link))
        #expect(!RestoreDestinationRules.itemExists(at: directory.appendingPathComponent("free")))
        #expect(RestoreDestinationRules.directoryExists(directory.path))
        #expect(!RestoreDestinationRules.directoryExists(link.path))
    }

    @Test("the two overwrite modes map to restic's never and always")
    func policyMapping() {
        // Replace is `always`, never `if-changed`: if-changed trusts size and
        // modification time and kept a same-size, same-time corrupted file in
        // the probe, which is exactly what a restore exists to undo.
        #expect(RestoreOverwritePolicy.keepExisting.resticValue == "never")
        #expect(RestoreOverwritePolicy.replaceExisting.resticValue == "always")
    }
}
