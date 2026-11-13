import Foundation

/// The repository page's used/free strip; restic cannot report the disk.
struct VolumeCapacity: Equatable {
    let totalBytes: Int64
    let freeBytes: Int64

    var usedBytes: Int64 { max(0, totalBytes - freeBytes) }

    var isLow: Bool { totalBytes > 0 && freeBytes * 20 < totalBytes }

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }

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
