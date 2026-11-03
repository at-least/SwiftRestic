import Darwin
import Foundation

/// The items Time Machine's options list as left out of its backups
/// (`SkipPaths` in its preferences file). Not the mark apps put on single
/// items (`tmutil addexclusion` without `-p`): that lives on each item,
/// and finding it means walking the folder before every backup (measured:
/// about 35 s for a home folder of 330,000 items) — the user's call was to
/// leave it out (2026-10-30). Not Time Machine's built-in system
/// list either: no file holds it on macOS 27.
enum TimeMachineExclusions {
    /// Time Machine's preferences. macOS lets a process read them only
    /// with Full Disk Access (the test runner, without it: "you don’t have
    /// permission to view it"); a Terminal that holds the grant reads them.
    static let preferencesFile = URL(fileURLWithPath: "/Library/Preferences/com.apple.TimeMachine.plist")

    struct Reading: Equatable {
        /// The listed items inside the folder, spelled below the folder as
        /// given — what restic records and matches — each once, none inside
        /// another.
        var items: [String] = []
        /// What the run's log says of the list: why it, or one of its
        /// items, was not applied.
        var notes: [String] = []
    }

    enum ListProblem: Error, Equatable {
        case needsFullDiskAccess
        case damaged

        var note: String {
            switch self {
            case .needsFullDiskAccess: "Time Machine’s list of excluded items can be read only with Full Disk Access, so the items listed there were backed up."
            case .damaged: "Time Machine’s list of excluded items is damaged, so the items listed there were backed up."
            }
        }
    }

    /// The list as a backup of `folder` uses it. Never fails the backup:
    /// the file is the system's, so a list or an item that cannot be used
    /// is a note instead.
    ///
    /// An item is compared by its real location — its parent folder's real
    /// path and its own name, so a listed symbolic link is the link, not
    /// what it points to: Time Machine may list /private/tmp/proj/build
    /// while the plan says /tmp/proj. Only items whose spelling is near
    /// the folder are looked up on disk (`isNear`): a lookup on a network
    /// share that went away can block for the mount's timeout.
    static func reading(for folder: String, preferences: URL = preferencesFile) -> Reading {
        let listed: [String]
        switch listedPaths(in: preferences) {
        case let .success(paths): listed = paths
        case let .failure(problem): return Reading(notes: [problem.note])
        }
        guard !listed.isEmpty else { return Reading() }
        guard case let .found(realFolder) = location(of: folder) else {
            return Reading(notes: ["SwiftRestic couldn’t find this plan’s folder on disk, so the items Time Machine’s options list were backed up."])
        }
        var reading = Reading()
        var inside: [String] = []
        var seen: Set<PathKey> = []
        for path in listed where isNear(path, folder: folder, realFolder: realFolder) {
            switch location(of: path) {
            case .absent:
                continue
            case .unknown:
                reading.notes.append("SwiftRestic couldn’t check “\(path)”, listed in Time Machine’s options, so it was backed up.")
            case let .found(real):
                if real == realFolder {
                    // As every rule that would leave out the plan's own
                    // folder: a plan backs up its folder.
                    reading.notes.append("Time Machine’s options leave out this plan’s folder, “\(path)”. SwiftRestic backed it up anyway.")
                } else if ResticPath.holds(real, realFolder) {
                    reading.notes.append("Time Machine’s options leave out “\(path)”, which holds this plan’s folder. SwiftRestic backed it up anyway.")
                } else if ResticPath.holds(realFolder, real), seen.insert(PathKey(real)).inserted {
                    inside.append(real)
                }
            }
        }
        for real in inside where !inside.contains(where: { ResticPath.relative(real, below: $0) != nil }) {
            reading.items.append(ResticPath.child(of: folder, named: ResticPath.relative(real, below: realFolder)!))
        }
        return reading
    }

    /// The items Time Machine's options list, as absolute paths. None when
    /// Time Machine was never set up (no file) or lists nothing (no key).
    static func listedPaths(in preferences: URL) -> Result<[String], ListProblem> {
        guard FileManager.default.fileExists(atPath: preferences.path) else { return .success([]) }
        let settings: Any
        do {
            settings = try PropertyListSerialization.propertyList(from: Data(contentsOf: preferences), format: nil)
        } catch CocoaError.fileReadNoPermission {
            return .failure(.needsFullDiskAccess)
        } catch {
            return .failure(.damaged)
        }
        guard let settings = settings as? [String: Any] else { return .failure(.damaged) }
        guard let value = settings["SkipPaths"] else { return .success([]) }
        guard let skipPaths = value as? [String] else { return .failure(.damaged) }
        return .success(skipPaths.map { ResticPath.normalized(ResticService.expandTilde($0)) })
    }

    /// Whether `path`'s spelling lies inside the folder, or holds it, in
    /// either spelling of the folder, read as written or with its first
    /// component's link followed (`rootLinkFollowed`). A folder reached
    /// through a link deeper down (a home folder moved elsewhere) is not
    /// matched.
    static func isNear(_ path: String, folder: String, realFolder: String) -> Bool {
        [path, rootLinkFollowed(path)].contains { spelling in
            [folder, realFolder].contains { ResticPath.holds($0, spelling) || ResticPath.holds(spelling, $0) }
        }
    }

    /// `path` with its first component followed when that is a link at the
    /// root of the startup disk (/tmp → /private/tmp). Read at the root, so
    /// the lookup never reaches a share.
    static func rootLinkFollowed(_ path: String) -> String {
        guard let below = ResticPath.relative(path, below: "/") else { return path }
        let first = "/" + (below.utf8.firstIndex(of: ResticPath.separator).map { String(decoding: below.utf8[..<$0], as: UTF8.self) } ?? below)
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: first) else { return path }
        let resolved = target.utf8.first == ResticPath.separator ? target : "/" + target
        return resolved + String(decoding: path.utf8.dropFirst(first.utf8.count), as: UTF8.self)
    }

    enum Location: Equatable {
        case found(String)
        case absent
        /// On disk or not, the lookup failed (no permission on a folder
        /// above, a loop of links).
        case unknown
    }

    /// Where `path` is: its parent folder's real path (realpath(3), not
    /// URL.resolvingSymlinksInPath, which drops the /private the real path
    /// keeps) and its own name, the name itself not followed.
    static func location(of path: String) -> Location {
        guard path != "/" else { return .found("/") }
        let parent = ResticPath.parent(of: path)
        let name = ResticPath.basename(of: path)
        guard let resolved = realpath(parent, nil) else { return errno == ENOENT ? .absent : .unknown }
        defer { free(resolved) }
        let real = ResticPath.child(of: String(cString: resolved), named: name)
        var info = stat()
        guard lstat(real, &info) == 0 else { return errno == ENOENT ? .absent : .unknown }
        return .found(real)
    }
}
