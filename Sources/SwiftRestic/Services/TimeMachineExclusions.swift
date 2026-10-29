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

    /// What a backup of one folder takes from the list.
    struct Reading: Equatable {
        /// The listed items inside the folder, spelled below the folder as
        /// given — what restic records and matches — none inside another.
        var items: [String] = []
        /// What the run's log says of the list: why it was not read, or a
        /// listed item that holds the folder itself.
        var notes: [String] = []
    }

    /// The list as a backup of `folder` uses it. Never throws: the file is
    /// the system's, and a backup must not fail on it — a list macOS will
    /// not let this process read, or a damaged one, is a note instead.
    ///
    /// Compared by real path (realpath(3)): Time Machine may list
    /// /private/tmp/proj/build while the plan says /tmp/proj. A listed item
    /// that is not on disk leaves out nothing and is passed over.
    static func reading(for folder: String, preferences: URL = preferencesFile) -> Reading {
        let listed: [String]
        switch listedPaths(in: preferences) {
        case let .success(paths?):
            listed = paths
        case .success(nil):
            return Reading(notes: ["Time Machine’s list of excluded items can be read only with Full Disk Access, so the items listed there were backed up."])
        case let .failure(error):
            return Reading(notes: ["Time Machine’s list of excluded items couldn’t be read (\(error.localizedDescription)), so the items listed there were backed up."])
        }
        let realFolder = realPath(folder) ?? folder
        var reading = Reading()
        var inside: [String] = []
        for path in listed {
            guard let real = realPath(path) else { continue }
            if ResticPath.holds(real, realFolder) {
                // As every rule that would leave out the plan's own folder:
                // a plan backs up its folder.
                reading.notes.append("Time Machine’s options leave out “\(path)”, which holds this plan’s folder. SwiftRestic backed it up anyway.")
            } else if ResticPath.holds(realFolder, real) {
                inside.append(real)
            }
        }
        let realPrefix = realFolder == "/" ? "/" : realFolder + "/"
        let givenPrefix = folder == "/" ? "/" : folder + "/"
        for real in inside where !inside.contains(where: { $0 != real && ResticPath.holds($0, real) }) {
            reading.items.append(givenPrefix + String(decoding: real.utf8.dropFirst(realPrefix.utf8.count), as: UTF8.self))
        }
        return reading
    }

    /// The items Time Machine's options list, as absolute paths. None when
    /// Time Machine was never set up (no file) or lists nothing (no key);
    /// nil when macOS will not let this process read the file; a failure
    /// for a file that is there but damaged.
    static func listedPaths(in preferences: URL) -> Result<[String]?, any Error> {
        guard FileManager.default.fileExists(atPath: preferences.path) else { return .success([]) }
        do {
            let data = try Data(contentsOf: preferences)
            guard let settings = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let skipPaths = settings["SkipPaths"] as? [String]
            else { return .success([]) }
            return .success(skipPaths.map { ResticPath.normalized(ResticService.expandTilde($0)) })
        } catch CocoaError.fileReadNoPermission {
            return .success(nil)
        } catch {
            return .failure(error)
        }
    }

    /// realpath(3), not URL.resolvingSymlinksInPath, which drops the
    /// /private the real path keeps. Nil for a path that is not on disk.
    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
