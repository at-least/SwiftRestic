import Foundation

/// A local volume's capacity — the numbers behind the repository page's
/// used/free strip, Arq's "Used Space / Free Space" pattern. A repository's
/// size only means something against the disk it lives on, and restic cannot
/// report that disk: only the filesystem can.
struct VolumeCapacity: Equatable {
    let totalBytes: Int64
    let freeBytes: Int64

    var usedBytes: Int64 { max(0, totalBytes - freeBytes) }

    /// The bar's fill. A degenerate total reads as empty rather than NaN.
    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }

    /// Reads the volume that holds `path`. `nil` when the filesystem reports
    /// nothing usable — callers render no strip rather than a zeroed one,
    /// which would pass an empty disk off as the truth.
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
