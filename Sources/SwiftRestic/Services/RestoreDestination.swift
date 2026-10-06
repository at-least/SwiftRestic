import Foundation

/// What a restore does with a file that is already where the backed-up one
/// would land. Chosen in the destination sheet for every restore, never
/// remembered, and required at every API on the way down: a defaulted
/// destructive mode would be a silent overwrite.
///
/// Two modes, not restic's four. `if-changed` trusts size and modification
/// time, so it keeps a same-size, same-time file with different bytes — the
/// damage a restore exists to undo. `always` already skips files whose
/// content matches, and `if-newer` does not differ from `never` on edited
/// files.
enum RestoreOverwritePolicy: String, Sendable, CaseIterable {
    case keepExisting
    case replaceExisting

    /// The `restic restore --overwrite` value.
    var resticValue: String {
        switch self {
        case .keepExisting: "never"
        case .replaceExisting: "always"
        }
    }
}

/// Where the destination sheet restores to. Desktop and Other folder are
/// remembered between restores; Original location never is, so a reflexive
/// Return, Return can never restore in place because of an earlier session.
enum RestoreDestinationKind: String, Sendable, CaseIterable {
    case desktop
    case otherFolder
    case originalLocation
}

/// What is being restored: one item of a backup, several, or the whole of
/// it.
enum RestoreSubject: Sendable, Equatable {
    case item(name: String, path: String, isDirectory: Bool)
    /// Two or more items — the Restore pane's multiple selection, with any
    /// item inside a selected folder already dropped
    /// (`RestoreBatch.covering`).
    case items([RestoreItem])
    case wholeSnapshot(paths: [String])

    /// One directory per item, in order — the shape the destination sheet
    /// hands its restore: one for an item or a whole backup.
    var directoryCount: Int {
        if case let .items(items) = self { items.count } else { 1 }
    }
}

/// One of several items restored together.
struct RestoreItem: Sendable, Equatable {
    var name: String
    var path: String
    var isDirectory: Bool
}

/// Whether the items can go back exactly where they were backed up from.
enum OriginalLocation: Sendable, Equatable {
    /// Restore each item into its parent, `directories` (one per item, in
    /// order), and it lands at its own recorded path, `landings`.
    case available(directories: [URL], landings: [URL])
    case unavailable(reason: String)
}

/// The destination sheet's rules, pure and with the file system injected, so
/// the sheet's answers are testable without the paths existing.
enum RestoreDestinationRules {
    /// The item's recorded path as a place on this Mac, when restoring its
    /// parent would put it back exactly there.
    ///
    /// The path must be absolute and already in normal form, checked on its
    /// Unicode scalars: no empty, `.` or `..` component (a Character-level
    /// split would fold a combining mark after the separator into the `/`),
    /// and no file-system normalisation — `standardizingPath` answers
    /// `/tmp` for an existing `/private/tmp` and would fail an honest path.
    /// Its last component must survive the landing rule unchanged, or the
    /// item would land beside itself. The parent must exist and be writable.
    /// A whole backup has no single parent: `restic restore --target /`
    /// would write the metadata of every root-owned directory above the
    /// backed-up folders.
    static func originalLocation(
        for subject: RestoreSubject,
        directoryExists: (String) -> Bool,
        isWritable: (String) -> Bool
    ) -> OriginalLocation {
        switch subject {
        case .wholeSnapshot:
            return .unavailable(reason: "A whole backup can't be put back in one step. Select a folder in it and restore that to its original location.")
        case let .item(name, path, _):
            return originalLocation(name: name, path: path, directoryExists: directoryExists, isWritable: isWritable)
        case let .items(items):
            var directories: [URL] = []
            var landings: [URL] = []
            for item in items {
                switch originalLocation(name: item.name, path: item.path, directoryExists: directoryExists, isWritable: isWritable) {
                case let .available(parents, landed):
                    directories += parents
                    landings += landed
                case let .unavailable(reason):
                    // The first that cannot, named: the reasons speak of
                    // "this item" or of its folder.
                    return .unavailable(reason: "“\(item.name)”: \(reason)")
                }
            }
            return .available(directories: directories, landings: landings)
        }
    }

    private static func originalLocation(
        name: String,
        path: String,
        directoryExists: (String) -> Bool,
        isWritable: (String) -> Bool
    ) -> OriginalLocation {
        let badPath = OriginalLocation.unavailable(
            reason: "This item's recorded path can't be used as a location on this Mac."
        )
        let components = path.unicodeScalars
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
        // "/a/b" splits as ["", "a", "b"]: the leading empty piece is the
        // root, every later one must be a real name.
        guard components.count >= 2, components[0].isEmpty,
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return badPath }
        let last = components[components.count - 1]
        guard ResticService.sanitizedRestoreName(name) == last else { return badPath }
        let parent = components.count == 2 ? "/" : components.dropLast().joined(separator: "/")
        guard directoryExists(parent) else {
            return .unavailable(reason: "“\(parent)” isn't on this Mac.")
        }
        guard isWritable(parent) else {
            return .unavailable(reason: "SwiftRestic can't write to “\(parent)”.")
        }
        let directory = URL(fileURLWithPath: parent, isDirectory: true)
        return .available(directories: [directory], landings: [ResticService.restoredItemURL(named: name, in: directory)])
    }

    /// Where a restore into `directories` (one per item, as
    /// `RestoreSubject.directoryCount` counts them) writes: each item under
    /// the one landing rule (`ResticService.restoredItemURL(named:in:)`),
    /// or each backed-up folder under its full original path (`restic
    /// restore <id> --target` recreates them).
    static func landings(for subject: RestoreSubject, into directories: [URL]) -> [URL] {
        switch subject {
        case let .item(name, _, _):
            [ResticService.restoredItemURL(named: name, in: directories[0])]
        case let .items(items):
            zip(items, directories).map { ResticService.restoredItemURL(named: $0.name, in: $1) }
        case let .wholeSnapshot(paths):
            paths.map { directories[0].appendingPathComponent($0) }
        }
    }

    /// The landings a Replace would overwrite, which the sheet confirms
    /// first. Keep never asks; Replace asks only when something is actually
    /// there — a prompt over nothing teaches the user to click through it.
    static func replaceConfirmationTargets(
        policy: RestoreOverwritePolicy,
        landings: [URL],
        exists: (URL) -> Bool
    ) -> [URL] {
        guard policy == .replaceExisting else { return [] }
        return landings.filter(exists)
    }

    // MARK: - The file system's answers

    static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func isWritable(_ path: String) -> Bool {
        FileManager.default.isWritableFile(atPath: path)
    }

    /// lstat semantics: a dangling symlink occupies the name even though
    /// `fileExists` (which follows it) answers no.
    static func itemExists(at url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}
