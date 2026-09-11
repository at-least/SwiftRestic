import Foundation
import Testing

/// The repository page's volume strip is only as honest as this arithmetic.
@Suite("Volume capacity")
struct VolumeCapacityTests {
    @Test("used and fraction come back from total and free")
    func arithmetic() {
        let capacity = VolumeCapacity(totalBytes: 1000, freeBytes: 250)
        #expect(capacity.usedBytes == 750)
        #expect(capacity.usedFraction == 0.75)
    }

    @Test("a degenerate total reads as empty, never NaN")
    func zeroTotal() {
        let capacity = VolumeCapacity(totalBytes: 0, freeBytes: 0)
        #expect(capacity.usedBytes == 0)
        #expect(capacity.usedFraction == 0)
    }

    @Test("a filesystem reporting more free than total clamps to nothing used")
    func clamping() {
        let capacity = VolumeCapacity(totalBytes: 100, freeBytes: 150)
        #expect(capacity.usedBytes == 0)
        #expect(capacity.usedFraction == 0)
    }

    @Test("the volume holding a real path reports positive numbers")
    func readsRealVolume() throws {
        let capacity = try #require(VolumeCapacity.of(path: FileManager.default.temporaryDirectory.path))
        #expect(capacity.totalBytes > 0)
        #expect(capacity.freeBytes > 0)
        #expect(capacity.usedBytes >= 0)
        #expect(capacity.usedFraction > 0 && capacity.usedFraction <= 1)
    }

    @Test("an empty path has no volume")
    func emptyPath() {
        #expect(VolumeCapacity.of(path: "") == nil)
    }
}
