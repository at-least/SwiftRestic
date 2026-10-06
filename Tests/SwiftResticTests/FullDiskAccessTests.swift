import Foundation
import Testing

/// The Full Disk Access probe. What it answers inside SwiftRestic.app
/// depends on how the app was launched and what the user granted, so no test
/// can pin the real answer; these pin the mapping and that the probe really
/// opens files instead of guessing from `stat`.
@Suite("Full Disk Access probe")
struct FullDiskAccessTests {
    @Test("status from open results: EPERM anywhere wins, any open is granted, nothing found is unknown")
    func statusFromOpenResults() {
        #expect(FullDiskAccess.status(fromOpenResults: [EPERM]) == .notGranted)
        #expect(FullDiskAccess.status(fromOpenResults: [0, EPERM]) == .notGranted)
        #expect(FullDiskAccess.status(fromOpenResults: [ENOENT, 0]) == .granted)
        #expect(FullDiskAccess.status(fromOpenResults: [0, 0, 0]) == .granted)
        #expect(FullDiskAccess.status(fromOpenResults: [ENOENT, ENOENT]) == .unknown)
        #expect(FullDiskAccess.status(fromOpenResults: []) == .unknown)
    }

    @Test("the probe maps real open results and does not trust stat")
    func probeOpensFiles() throws {
        // The test host's own Full Disk Access is not asserted: it answers
        // for whatever process macOS holds responsible — under xcodebuild
        // that is Xcode, not the terminal.
        //
        // These files tell `open` from a `stat` guess (the mode-000 file
        // exists but does not open); `access(R_OK)` and `isReadableFile`
        // answer the same for them. The case that separates them is a
        // TCC-protected path, whose answer depends on the machine, so it
        // belongs to the running app, not to a test.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticFDA-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("readable.txt")
        try Data("x".utf8).write(to: file)

        #expect(FullDiskAccess.probe(paths: [file.path]) == .granted)
        #expect(FullDiskAccess.probe(paths: [directory.appendingPathComponent("missing").path]) == .unknown)
        // A file only its owner could read, were it not this test's own:
        // a mode-000 file is EACCES, which says nothing about Full Disk Access.
        let locked = directory.appendingPathComponent("locked.txt")
        try Data("x".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        #expect(FullDiskAccess.probe(paths: [locked.path]) == .unknown)
    }

    @Test("the settings link is the Full Disk Access list")
    func settingsLink() {
        // A constant literal, pinned the way AppLinks are: a typo reads red
        // here instead of opening the wrong pane.
        #expect(FullDiskAccess.settingsURL.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }
}
