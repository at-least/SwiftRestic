import Foundation
import Testing

/// What a file's version row says of the version below it: the size change
/// when a diff cut the history or the sizes tell the versions apart, "may be
/// identical" where nothing does, and nothing for the oldest or while the
/// sizes are still being read.
@MainActor
@Suite("File version change")
struct FileVersionChangeTests {
    @Test("a diff's cut shows the size change, the same size included; the oldest version says nothing")
    func diffCut() {
        #expect(FileVersionChange.between(since: .changed, newerSize: 106, olderSize: 89, isReading: false)
            == .size(Format.sizeChange(from: 89, to: 106)))
        // Changed content of the same length: the diff said so, and the
        // size says it is no bigger.
        #expect(FileVersionChange.between(since: .changed, newerSize: 89, olderSize: 89, isReading: false)
            == .size("Same size"))
        #expect(FileVersionChange.between(since: nil, newerSize: 89, olderSize: 89, isReading: false) == .none)
        // No sizes: the cut stands without a number.
        #expect(FileVersionChange.between(since: .changed, newerSize: nil, olderSize: 89, isReading: false) == .none)
    }

    @Test("a cut no diff made is settled by different sizes, and stays in doubt with equal or unknown ones")
    func uncertainCut() {
        #expect(FileVersionChange.between(since: .uncertain, newerSize: 106, olderSize: 89, isReading: false)
            == .size(Format.sizeChange(from: 89, to: 106)))
        #expect(FileVersionChange.between(since: .uncertain, newerSize: 89, olderSize: 89, isReading: false) == .mayBeIdentical)
        // While the find runs, nothing flashes up; once it failed, the doubt shows.
        #expect(FileVersionChange.between(since: .uncertain, newerSize: nil, olderSize: nil, isReading: true) == .none)
        #expect(FileVersionChange.between(since: .uncertain, newerSize: nil, olderSize: 89, isReading: false) == .mayBeIdentical)
    }
}
