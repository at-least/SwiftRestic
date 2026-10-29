import Foundation

/// What Time Machine leaves out under a folder, from the two places the app
/// can read: the mark apps put on their own items (`tmutil addexclusion`
/// without `-p`, NSURLIsExcludedFromBackupKey — the
/// com.apple.metadata:com_apple_backup_excludeItem attribute, which travels
/// with the item), and the items listed in Time Machine's options
/// (`SkipPaths` in its preferences file). Not Time Machine's built-in
/// system list (~/Library/Caches and the like): no file holds it on macOS
/// 27.
enum TimeMachineExclusions {
    /// Time Machine's preferences. macOS lets a process read them only
    /// with Full Disk Access (the test runner, without it: "you don’t have
    /// permission to view it"); a Terminal that holds the grant reads them.
    static let preferencesFile = URL(fileURLWithPath: "/Library/Preferences/com.apple.TimeMachine.plist")

    /// What a walk found under a plan's folder.
    struct Found: Equatable {
        /// The items to leave out, as `items(under:preferences:)` spells them.
        var items: [String]
        /// False when Time Machine's list could not be read for want of
        /// Full Disk Access: `items` then holds the marked items alone.
        var readTheList: Bool
    }

    /// Every excluded item strictly inside `folder`, spelled below `folder`
    /// as given — what restic reads and matches: the marked ones in walk
    /// order, then the listed ones; an item inside an excluded folder is
    /// not named again. Empty for a file, and for a symbolic link, which
    /// restic backs up as the link alone. A folder the walk cannot read is
    /// passed over: restic cannot read it either, and says so itself.
    ///
    /// Not Spotlight's index of the mark (`mdfind
    /// "com_apple_backup_excludeItem = 'com.apple.backupd'"`): it names only
    /// a small part of what a walk finds.
    static func items(under folder: String, preferences: URL = preferencesFile) throws -> Found {
        let root = URL(fileURLWithPath: folder)
        let kind = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard kind?.isDirectory == true, kind?.isSymbolicLink != true else { return Found(items: [], readTheList: true) }
        // The enumerator spells every item below the folder's real path
        // (/private/tmp/… for a folder given as /tmp/…), so the cut is
        // below that spelling and the result is put back under `folder`.
        // realpath(3), not URL.resolvingSymlinksInPath, which drops the
        // /private the enumerator keeps. Gone since the look above: restic
        // will say the folder is missing.
        guard let resolved = realpath(folder, nil) else { return Found(items: [], readTheList: true) }
        defer { free(resolved) }
        let real = String(cString: resolved)
        let realPrefix = real == "/" ? "/" : real + "/"
        let givenPrefix = folder == "/" ? "/" : folder + "/"
        guard let walk = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isExcludedFromBackupKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return Found(items: [], readTheList: true) }
        var marked: [String] = []
        var visited = 0
        for case let url as URL in walk {
            visited += 1
            if visited % 1000 == 0, Task.isCancelled { throw ResticError.cancelled }
            guard try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else { continue }
            precondition(url.path.utf8.starts(with: realPrefix.utf8), "\(url.path) is not below \(real)")
            marked.append(givenPrefix + String(decoding: url.path.utf8.dropFirst(realPrefix.utf8.count), as: UTF8.self))
            walk.skipDescendants()
        }
        guard let listedEverywhere = try listedPaths(in: preferences) else {
            return Found(items: marked, readTheList: false)
        }
        let listed = listedEverywhere.filter { path in
            path != folder && ResticPath.holds(folder, path)
                && !marked.contains(where: { ResticPath.holds($0, path) })
        }
        return Found(items: marked + listed, readTheList: true)
    }

    /// The items Time Machine's options list, as absolute paths. None when
    /// Time Machine was never set up (no file) or lists nothing (no key);
    /// nil when macOS will not let this process read the file; a file that
    /// is there but damaged throws.
    static func listedPaths(in preferences: URL) throws -> [String]? {
        guard FileManager.default.fileExists(atPath: preferences.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: preferences)
        } catch CocoaError.fileReadNoPermission {
            return nil
        }
        guard let settings = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let skipPaths = settings["SkipPaths"] as? [String]
        else { return [] }
        return skipPaths.map { ResticPath.normalized(ResticService.expandTilde($0)) }
    }
}
