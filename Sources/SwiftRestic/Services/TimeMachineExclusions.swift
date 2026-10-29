import Foundation

/// The items Time Machine's options list as left out of its backups
/// (`SkipPaths` in its preferences file). Not the mark apps put on single
/// items (`tmutil addexclusion` without `-p`): that lives on each item,
/// and finding it means walking the folder before every backup — the
/// user's call was to leave it out. Not Time Machine's built-in system
/// list either: no file holds it on macOS 27.
enum TimeMachineExclusions {
    /// Time Machine's preferences. macOS lets a process read them only
    /// with Full Disk Access (the test runner, without it: "you don’t have
    /// permission to view it"); a Terminal that holds the grant reads them.
    static let preferencesFile = URL(fileURLWithPath: "/Library/Preferences/com.apple.TimeMachine.plist")

    /// The listed items strictly inside `folder`; nil when macOS will not
    /// let this process read the list.
    static func items(under folder: String, preferences: URL = preferencesFile) throws -> [String]? {
        try listedPaths(in: preferences)?.filter { $0 != folder && ResticPath.holds(folder, $0) }
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
