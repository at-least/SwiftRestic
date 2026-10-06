import Foundation
import Testing

/// When a file version's Preview is offered: a preview dumps the whole file
/// into a temporary folder, so it waits for the version's size and refuses
/// a file too big to copy just to look at.
@MainActor
@Suite("Version preview")
struct VersionPreviewTests {
    @Test("Preview waits for the size, says why it cannot run, and refuses a file past the limit")
    func availability() {
        #expect(VersionPreview.unavailableReason(size: 46, isReading: false) == nil)
        #expect(VersionPreview.unavailableReason(size: VersionPreview.sizeLimit, isReading: false) == nil)
        #expect(VersionPreview.unavailableReason(size: nil, isReading: true)
            == "Preview waits for the version's size, still being read")
        #expect(VersionPreview.unavailableReason(size: nil, isReading: false)
            == "Preview needs the version's size, which could not be read")
        let big = VersionPreview.sizeLimit + 1
        #expect(VersionPreview.unavailableReason(size: big, isReading: false)
            == "Too large to preview (\(Format.bytes(big))) — restore it to open it")
    }
}
