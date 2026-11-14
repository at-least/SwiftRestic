import Foundation
import Testing

@Suite("Volume capacity")
struct VolumeCapacityTests {
    @Test("a disk under 5% free is low on space; at 5% it isn't")
    func lowSpace() {
        #expect(VolumeCapacity(totalBytes: 1000, freeBytes: 49).isLow)
        #expect(!VolumeCapacity(totalBytes: 1000, freeBytes: 50).isLow)
    }

    @Test("the volume holding a real path reports positive numbers")
    func readsRealVolume() throws {
        let capacity = try #require(VolumeCapacity.of(path: FileManager.default.temporaryDirectory.path))
        #expect(capacity.totalBytes > 0)
        #expect(capacity.freeBytes > 0)
    }

    @Test("an empty path has no volume")
    func emptyPath() {
        #expect(VolumeCapacity.of(path: "") == nil)
    }
}
