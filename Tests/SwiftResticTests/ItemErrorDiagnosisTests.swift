import Foundation
import Testing

/// Why restic could not read an item, and what the user can do about it:
/// macOS's privacy protection (Full Disk Access fixes it) against the file's
/// own permissions (it does not). The fixture lines follow restic's message
/// shapes, stored as `"<item>: <message>"`.
@Suite("item error diagnosis")
struct ItemErrorDiagnosisTests {
    private let mailLine = "/Users/u/Library/Mail: openfile for readdirnames failed: open /Users/u/Library/Mail: operation not permitted"

    @Test("item errors are classified by restic's errno text, measured shapes")
    func classification() {
        #expect(ItemErrorDiagnosis.kind(of: mailLine) == .blockedByMacOS)
        #expect(ItemErrorDiagnosis.kind(of: "/x/locked.txt: open /x/locked.txt: permission denied") == .deniedByFilePermissions)
        // The unprefixed shape — no `<item>: ` prefix — still classifies.
        #expect(ItemErrorDiagnosis.kind(of: "open /x/locked.pdf: permission denied") == .deniedByFilePermissions)
        // The words anywhere but at the end are a path, not an errno.
        #expect(ItemErrorDiagnosis.kind(of: "/x/permission denied/y: open /x/permission denied/y: no such file or directory") == .other)
        #expect(ItemErrorDiagnosis.kind(of: RunRecord.retentionSkippedPrefix + "repository is already locked by PID 4242 on demo-mac") == .other)
        #expect(ItemErrorDiagnosis.kind(of: "1 restic message could not be decoded — a restic update may have changed its output; the run's numbers may be incomplete.") == .other)
        #expect(ItemErrorDiagnosis.kind(of: "/src/gone does not exist, skipping") == .other)
        // A parent folder's extended-attribute failure: restic ends this
        // message with a newline, and the stored line keeps it.
        #expect(ItemErrorDiagnosis.kind(of: "/Users/u/Library/Safari: can not obtain extended attribute com.apple.macl for /Users/u/Library/Safari: xattr.get /Users/u/Library/Safari com.apple.macl: operation not permitted\n") == .blockedByMacOS)

        let tally = ItemErrorDiagnosis.tally([
            mailLine,
            "/Users/u/Library/Safari: openfile for readdirnames failed: open /Users/u/Library/Safari: operation not permitted",
            "/x/locked.txt: open /x/locked.txt: permission denied",
            "/src/gone does not exist, skipping",
        ])
        #expect(tally == ItemErrorDiagnosis.Tally(blockedByMacOS: 2, deniedByFilePermissions: 1))
    }

    @Test("hints branch on access at the run and access now")
    func hintBranches() {
        let blocked = ItemErrorDiagnosis.Tally(blockedByMacOS: 3, deniedByFilePermissions: 0)
        let hints = ItemErrorDiagnosis.hints(tally:accessAtRun:accessNow:)
        #expect(hints(blocked, .notGranted, .notGranted) == [.grantFullDiskAccess(3)])
        #expect(hints(blocked, .notGranted, .granted) == [.retryNowGranted(3)])
        #expect(hints(blocked, .granted, .granted) == [.protectedEvenWithAccess(3)])
        // A record with no stamp reads the status now; an unknown one is
        // treated as missing.
        #expect(hints(blocked, nil, .notGranted) == [.grantFullDiskAccess(3)])
        #expect(hints(blocked, nil, .unknown) == [.grantFullDiskAccess(3)])
        // Nor is such a record ever told the grant was there at the run —
        // nothing says so, and "exclude them" would drop what the next
        // backup, now granted, reads.
        #expect(hints(blocked, nil, .granted) == [.retryNowGranted(3)])
        #expect(hints(blocked, .unknown, .granted) == [.retryNowGranted(3)])

        // macOS's block first, then what Full Disk Access cannot fix.
        let mixed = ItemErrorDiagnosis.Tally(blockedByMacOS: 1, deniedByFilePermissions: 2)
        #expect(hints(mixed, .notGranted, .notGranted) == [.grantFullDiskAccess(1), .filePermissions(2)])
        #expect(hints(ItemErrorDiagnosis.Tally(), .notGranted, .notGranted).isEmpty)
    }

    @Test("a record without a stored tally is diagnosed from its unreadable items only")
    func recordFallsBackToItsItems() {
        var record = RunRecord(kind: .backup, planName: "Documents")
        record.outcome = .completedWithErrors
        // A retention line that happens to end in an errno phrase: stored
        // after the unreadable items, so it is never one of them.
        record.itemErrors = [
            mailLine,
            RunRecord.retentionSkippedPrefix + "open /Volumes/NAS/repo/locks: operation not permitted",
        ]
        record.itemErrorCount = 1
        #expect(ItemErrorDiagnosis.hints(for: record, accessNow: .notGranted) == [.grantFullDiskAccess(1)])

        // No stored tally and no stamp: diagnosed from its items —
        // permissions only.
        var legacy = RunRecord(kind: .backup, planName: "Documents")
        legacy.itemErrors = ["open /x/Taxes/2025/locked.pdf: permission denied"]
        legacy.itemErrorCount = 1
        #expect(ItemErrorDiagnosis.hints(for: legacy, accessNow: .granted) == [.filePermissions(1)])

        // A stored tally wins over the capped sample.
        record.itemErrorTally = ItemErrorDiagnosis.Tally(blockedByMacOS: 60, deniedByFilePermissions: 1)
        record.fullDiskAccessAtRun = .notGranted
        #expect(ItemErrorDiagnosis.hints(for: record, accessNow: .granted) == [.retryNowGranted(60), .filePermissions(1)])
    }

    @Test("each hint's words, in the drawer and in the short surfaces")
    func hintWords() {
        #expect(ItemErrorDiagnosis.detail(.grantFullDiskAccess(1))
            == "macOS blocked 1 item because SwiftRestic doesn't have Full Disk Access.")
        #expect(ItemErrorDiagnosis.detail(.retryNowGranted(2))
            == "macOS blocked 2 items because SwiftRestic didn't have Full Disk Access at the time. It has it now — back up again to include them.")
        #expect(ItemErrorDiagnosis.detail(.protectedEvenWithAccess(1))
            == "macOS blocked 1 item even though SwiftRestic had Full Disk Access — they are likely protected by macOS itself. Exclude them if this keeps happening.")
        #expect(ItemErrorDiagnosis.detail(.filePermissions(1))
            == "1 item can't be read with your account's file permissions. Full Disk Access doesn't change that — fix them with Finder › Get Info, or exclude them.")

        #expect(ItemErrorDiagnosis.headline(.grantFullDiskAccess(1)) == "macOS blocked 1 item: SwiftRestic needs Full Disk Access.")
        #expect(ItemErrorDiagnosis.headline(.retryNowGranted(3)) == "macOS blocked 3 items while SwiftRestic lacked Full Disk Access.")
        #expect(ItemErrorDiagnosis.headline(.protectedEvenWithAccess(1)) == "macOS blocked 1 item even with Full Disk Access on.")
        #expect(ItemErrorDiagnosis.headline(.filePermissions(2)) == "2 items can't be read with your account's file permissions.")
    }

    @Test("sources that reach macOS-protected data are recognised, measured paths only")
    func protectedSources() {
        let home = "/Users/u"
        for source in ["~", "/Users/u", "/Users", "/", "/Users/u/Library", "/Users/u/Library/Mail/V10",
                       "/users/U/library/safari", "/Users/u/Library/Application Support",
                       "/Users/u/./Library/../Library/Messages", "/Library/Application Support/com.apple.TCC/TCC.db"] {
            #expect(ProtectedLocations.needsFullDiskAccess(source, home: home), "\(source)")
        }
        for source in ["/Users/u/Documents", "/Users/u/Library/Preferences", "/Users/u/LibraryX",
                       "/Users/u/Library/MailX", "/Volumes/NAS", "/Users/other", "~/Documents"] {
            #expect(!ProtectedLocations.needsFullDiskAccess(source, home: home), "\(source)")
        }
        #expect(ProtectedLocations.firstProtectedSource(["/Users/u/Documents", "/Users/u/Library/Messages"], home: home)
            == "/Users/u/Library/Messages")
        #expect(ProtectedLocations.firstProtectedSource(["/Users/u/Documents"], home: home) == nil)
    }
}
