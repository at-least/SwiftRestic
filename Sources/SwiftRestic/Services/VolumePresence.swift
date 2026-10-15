import Foundation

/// Whether the drive a path lives on is here. macOS mounts every other
/// volume as a folder under /Volumes, so a path there names its drive by
/// that folder; anything else is on the startup disk, which is always here.
enum VolumePresence {
    /// "Archive SSD" for "/Volumes/Archive SSD/restic"; nil for a path on
    /// the startup disk.
    static func volumeName(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        return String(parts[1])
    }

    /// Whether the volume holding `path` is mounted; nil for a path on the
    /// startup disk.
    static func isMounted(volumeOf path: String) -> Bool? {
        volumeName(of: path).map { isVolumeRoot("/Volumes/\($0)") }
    }

    /// The network share holding `path`, read from its mounted volume: the
    /// volume's name and its remount URL (`volumeURLForRemountingKey`), as
    /// a backup would reconnect it (`NetworkShare`). Nil for a path on the
    /// startup disk or a local drive, a volume that is away, or a share
    /// mounted with no user name in its URL — a password has no one to
    /// sign in as. Reads the file system, which a stalled share can hold
    /// for seconds: callers run it off the main actor.
    static func mountedShare(holding path: String) -> MountedShare? {
        guard let volume = volumeName(of: path), isVolumeRoot("/Volumes/\(volume)"),
              let values = try? URL(fileURLWithPath: "/Volumes/\(volume)")
                  .resourceValues(forKeys: [.volumeIsLocalKey, .volumeURLForRemountingKey]),
              values.volumeIsLocal == false,
              let url = values.volumeURLForRemounting, url.user != nil
        else { return nil }
        return MountedShare(volumeName: volume, url: url.absoluteString)
    }

    /// Whether `folder` is the root of a mounted volume. A folder left
    /// under /Volumes after its drive went away uncleanly is not: it sits
    /// on the startup disk. /Volumes lists the startup disk too, as a link
    /// to /, which is followed.
    static func isVolumeRoot(_ folder: String) -> Bool {
        let url = URL(fileURLWithPath: folder).resolvingSymlinksInPath()
        guard let volume = try? url.resourceValues(forKeys: [.volumeURLKey]).volume else { return false }
        return volume.standardizedFileURL.path == url.standardizedFileURL.path
    }
}

/// A network share as its mounted volume reports it (`VolumePresence.mountedShare`).
struct MountedShare: Equatable, Sendable {
    var volumeName: String
    var url: String
}
