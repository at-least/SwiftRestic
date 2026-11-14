import Foundation

/// The repository page's Disk row; restic cannot report the disk.
struct VolumeCapacity: Equatable {
    let totalBytes: Int64
    let freeBytes: Int64

    var isLow: Bool { totalBytes > 0 && freeBytes * 20 < totalBytes }

    /// `nil` rather than zeros, which would pass an empty disk off as fact.
    static func of(path: String) -> VolumeCapacity? {
        guard !path.isEmpty else { return nil }
        guard
            let values = try? URL(fileURLWithPath: path)
                .resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
            let total = values.volumeTotalCapacity,
            let free = values.volumeAvailableCapacity,
            total > 0
        else { return nil }
        return VolumeCapacity(totalBytes: Int64(total), freeBytes: Int64(max(0, free)))
    }
}
