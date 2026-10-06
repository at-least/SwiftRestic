import Foundation
import Testing

/// A run's words outside the drawer: the Activity Detail column and Copy
/// Details. One wording site, so Activity and the plan page cannot disagree.
@Suite("run record presentation")
struct RunRecordPresentationTests {
    private func backup(_ configure: (inout RunRecord) -> Void = { _ in }) -> RunRecord {
        var record = RunRecord(kind: .backup, planName: "Documents")
        configure(&record)
        return record
    }

    private func restore(_ configure: (inout RunRecord) -> Void = { _ in }) -> RunRecord {
        var record = RunRecord(kind: .restore, planName: "Budget.numbers")
        configure(&record)
        return record
    }

    private func plan(name: String, repositoryID: UUID) -> BackupPlan {
        var plan = BackupPlan()
        plan.name = name
        plan.repositoryID = repositoryID
        return plan
    }

    private func repository(name: String) -> Repository {
        var repository = Repository()
        repository.name = name
        return repository
    }

    @Test("a plan and its repository are said in one string, once each")
    func planWithRepository() {
        #expect(RunRecordPresentation.planWithRepository("Documents", repositoryName: "Home Disk") == "Documents (Home Disk)")
        // No repository to say — or one named exactly like the plan, which
        // would state the same fact twice.
        #expect(RunRecordPresentation.planWithRepository("Documents", repositoryName: nil) == "Documents")
        #expect(RunRecordPresentation.planWithRepository("Documents", repositoryName: "") == "Documents")
        #expect(RunRecordPresentation.planWithRepository("Home Disk", repositoryName: "Home Disk") == "Home Disk")
        // An unnamed plan stays unnamed; the caller decides its fallback.
        #expect(RunRecordPresentation.planWithRepository("", repositoryName: "Home Disk") == "")
    }

    @Test("a run's display name is derived from IDs, for every kind")
    func displayNameForEveryKind() {
        let home = repository(name: "Home Disk")
        let documents = plan(name: "Documents", repositoryID: home.id)

        func run(
            _ kind: RunRecord.Kind,
            planID: UUID? = nil,
            planName: String,
            repositoryID: UUID? = nil
        ) -> RunRecord {
            RunRecord(kind: kind, planID: planID, planName: planName, repositoryID: repositoryID)
        }

        // Backup and forget: the plan by its current name, with the repository.
        #expect(
            RunRecordPresentation.displayName(
                for: run(.backup, planID: documents.id, planName: "Documents", repositoryID: home.id),
                plans: [documents],
                repositories: [home]
            ) == "Documents (Home Disk)"
        )
        #expect(
            RunRecordPresentation.displayName(
                for: run(.forget, planID: documents.id, planName: "Documents", repositoryID: home.id),
                plans: [documents],
                repositories: [home]
            ) == "Documents (Home Disk)"
        )
        // The plan is called what it is called now.
        var renamed = documents
        renamed.name = "Papers"
        #expect(
            RunRecordPresentation.displayName(
                for: run(.backup, planID: documents.id, planName: "Documents", repositoryID: home.id),
                plans: [renamed],
                repositories: [home]
            ) == "Papers (Home Disk)"
        )
        // Restore: its step label with the repository, as for backups.
        #expect(
            RunRecordPresentation.displayName(
                for: run(.restore, planName: "Budget.numbers", repositoryID: home.id),
                plans: [documents],
                repositories: [home]
            ) == "Budget.numbers (Home Disk)"
        )
        // Check and prune: the repository from its ID.
        for kind in [RunRecord.Kind.check, .prune] {
            #expect(
                RunRecordPresentation.displayName(
                    for: run(kind, planName: "Whatever was stored", repositoryID: home.id),
                    plans: [],
                    repositories: [home]
                ) == "Home Disk"
            )
        }
    }

    @Test("an ID that no longer resolves falls back to the stored name, and that is history")
    func displayNameFallbacks() {
        let home = repository(name: "Home Disk")

        // The plan is gone; the record keeps the name it was recorded under.
        #expect(
            RunRecordPresentation.displayName(
                for: RunRecord(kind: .backup, planID: UUID(), planName: "Documents", repositoryID: home.id),
                plans: [],
                repositories: [home]
            ) == "Documents (Home Disk)"
        )
        // The repository is gone: a backup names its plan alone, a check or
        // prune the repository name the record stored at run time.
        #expect(
            RunRecordPresentation.displayName(
                for: RunRecord(kind: .backup, planID: nil, planName: "Documents", repositoryID: nil),
                plans: [],
                repositories: [home]
            ) == "Documents"
        )
        #expect(
            RunRecordPresentation.displayName(
                for: RunRecord(kind: .check, planName: "Home NAS", repositoryID: nil),
                plans: [],
                repositories: []
            ) == "Home NAS"
        )
    }

    @Test("the log sheet's header names the run by the same rule")
    func logSheetTitle() {
        let home = repository(name: "Home Disk")
        let documents = plan(name: "Documents", repositoryID: home.id)

        #expect(
            RunRecordPresentation.logSheetTitle(
                for: RunRecord(kind: .backup, planID: documents.id, planName: "Documents", repositoryID: home.id),
                plans: [documents],
                repositories: [home]
            ) == "Backup log — Documents (Home Disk)"
        )
        #expect(
            RunRecordPresentation.logSheetTitle(
                for: RunRecord(kind: .check, planName: "Home Disk", repositoryID: home.id),
                plans: [],
                repositories: [home]
            ) == "Check log — Home Disk"
        )
        #expect(
            RunRecordPresentation.logSheetTitle(
                for: RunRecord(kind: .restore, planName: "Budget.numbers", repositoryID: home.id),
                plans: [],
                repositories: [home]
            ) == "Restore log — Budget.numbers (Home Disk)"
        )
    }

    @Test("Settings' Next run line says the plan with its repository, then when")
    func nextRunLine() {
        let home = repository(name: "Home Disk")
        let documents = plan(name: "Documents", repositoryID: home.id)
        let date = Date(timeIntervalSince1970: 1_790_409_497) // RunLogTests' pinned instant

        #expect(
            RunRecordPresentation.nextRunLine(plan: documents, date: date, repositories: [home])
                == "Documents (Home Disk) — \(Format.timestamp(date))"
        )
        // A repository the list does not resolve leaves the plan's name alone.
        #expect(
            RunRecordPresentation.nextRunLine(plan: documents, date: date, repositories: [])
                == "Documents — \(Format.timestamp(date))"
        )
    }

    @Test("the Detail column's wording for each kind of run")
    func detailWording() {
        let detail = RunRecordPresentation.detail(for:)

        #expect(detail(backup {
            $0.outcome = .failed
            $0.failureMessage = "The repository does not exist — Fatal: …"
        }) == "The repository does not exist — Fatal: …")

        #expect(detail(backup {
            $0.outcome = .completedWithErrors
            $0.itemErrors = ["/a: permission denied", "/b: permission denied"]
            $0.itemErrorCount = 2
        }) == "2 unreadable items")

        // restic's count, not the stored lines: the retention line stored
        // after the unreadable item is a fact of its own, never a second item.
        #expect(detail(backup {
            $0.outcome = .completedWithErrors
            $0.itemErrors = ["/a: permission denied", RunRecord.retentionSkippedPrefix + "locked"]
            $0.itemErrorCount = 1
        }) == "1 unreadable item · Retention skipped")

        #expect(detail(backup {
            $0.outcome = .completedWithErrors
            $0.itemErrors = [RunRecord.retentionSkippedPrefix + "locked"]
        }) == "Retention skipped")

        #expect(detail(backup {
            $0.outcome = .completedWithErrors
            $0.hookMessages = ["Hook “notify” exited 1"]
        }) == "1 hook issue")

        #expect(detail(backup {
            $0.filesNew = 2
            $0.filesChanged = 1
        }) == "2 new, 1 changed")

        // restic exited 3 and named nothing: the snapshot is short something,
        // and a file count would pass for a clean run.
        #expect(detail(backup {
            $0.outcome = .completedWithErrors
            $0.exitCode = 3
            $0.filesNew = 1
        }) == "Some source data could not be read")

        // …and it stays said when other facts come along: a skipped retention
        // step or a failing hook must not stand in for the unread data.
        #expect(detail(backup {
            $0.outcome = .completedWithErrors
            $0.exitCode = 3
            $0.itemErrors = [RunRecord.retentionSkippedPrefix + "locked"]
        }) == "Some source data could not be read · Retention skipped")
        #expect(detail(backup {
            $0.outcome = .completedWithErrors
            $0.exitCode = 3
            $0.hookMessages = ["Hook “notify” exited 1"]
        }) == "Some source data could not be read · 1 hook issue")

        // A reporting gap alone: nothing was unreadable, and the line itself
        // is the explanation.
        #expect(detail(backup {
            $0.outcome = .completedWithErrors
            $0.exitCode = 0
            $0.itemErrors = ["1 restic message could not be decoded"]
        }) == "1 restic message could not be decoded")

        #expect(detail(restore {
            $0.filesRestored = 12
            $0.bytesProcessed = 24_000_000
        }) == "12 files, \(Format.bytes(24_000_000))")

        #expect(detail(restore {
            $0.filesSkipped = 3
            $0.bytesProcessed = 0
        }) == "3 files kept as they were — nothing restored")

        let partlyKept = detail(restore {
            $0.filesRestored = 2
            $0.filesSkipped = 1
            $0.bytesProcessed = 2048
        })
        #expect(partlyKept == "2 files, \(Format.bytes(2048)) · 1 kept as it was")
        // One kept file is singular, as the restore banner says it
        // ("Kept 1 existing file as it was.").
        #expect(detail(restore {
            $0.filesSkipped = 1
            $0.bytesProcessed = 0
        }) == "1 file kept as it was — nothing restored")
        #expect(RunRecordPresentation.restoreFiles(restore {
            $0.filesRestored = 2
            $0.filesSkipped = 1
            $0.bytesProcessed = 14
        }) == "2 restored · 1 kept as it was · \(Format.bytes(14))")

        // Records from before restores kept their counts.
        #expect(detail(restore()) == "Succeeded")

        #expect(detail(RunRecord(kind: .check, planName: "Home NAS")) == "Succeeded")
        var failedCheck = RunRecord(kind: .check, planName: "Home NAS")
        failedCheck.outcome = .completedWithErrors
        #expect(detail(failedCheck) == "Completed with errors")
    }

    @Test("the warning banner says what the plan row says, the unnamed exit 3 and a hook's complaint included")
    func warningBannerWording() {
        let message = RunRecordPresentation.warningBannerMessage(for:)
        let retention = RunRecord.retentionSkippedPrefix + "repository is already locked by PID 123 on host"

        // The first unreadable item and restic's count, never the stored lines.
        #expect(message(backup {
            $0.outcome = .completedWithErrors
            $0.itemErrors = ["/a: permission denied", retention]
            $0.itemErrorCount = 1
        }) == "/a: permission denied — 1 unreadable item in total.")

        // A retention skip alone says it, reason and all.
        #expect(message(backup {
            $0.outcome = .completedWithErrors
            $0.itemErrors = [retention]
        }) == retention)

        // restic exited 3 and named nothing: that leads, as it leads the
        // facts, so the retention line does not pass for the whole story.
        #expect(message(backup {
            $0.outcome = .completedWithErrors
            $0.exitCode = 3
            $0.itemErrors = [retention]
        }) == "Some source data could not be read. \(retention)")
        #expect(message(backup {
            $0.outcome = .completedWithErrors
            $0.exitCode = 3
        }) == "Some source data could not be read.")

        // A failing hook is not restic reporting problems.
        #expect(message(backup {
            $0.outcome = .completedWithErrors
            $0.hookMessages = ["Hook “notify” exited 1"]
        }) == "Hook “notify” exited 1")
        #expect(message(backup {
            $0.outcome = .completedWithErrors
            $0.exitCode = 3
            $0.hookMessages = ["Hook “notify” exited 1"]
        }) == "Some source data could not be read. Hook “notify” exited 1")

        // A reporting gap explains itself; nothing at all falls back.
        #expect(message(backup {
            $0.outcome = .completedWithErrors
            $0.itemErrors = ["2 of restic's messages could not be read."]
        }) == "2 of restic's messages could not be read.")
        #expect(message(backup {
            $0.outcome = .completedWithErrors
        }) == RunRecord.unexplainedWarningMessage)
    }

    @Test("a retention run's Detail says what it removed, or why it did not")
    func retentionRunDetail() {
        var applied = RunRecord(kind: .forget, planName: "Documents")
        applied.detailText = "Removed 2 snapshots. Their data stays until the next prune."
        #expect(RunRecordPresentation.detail(for: applied)
            == "Removed 2 snapshots. Their data stays until the next prune.")

        var failed = RunRecord(kind: .forget, planName: "Documents")
        failed.outcome = .failed
        failed.failureMessage = "The repository is already locked"
        #expect(RunRecordPresentation.detail(for: failed) == "The repository is already locked")

        // A forget recorded before a count was kept (a stopped one, say)
        // falls back to its outcome.
        var bare = RunRecord(kind: .forget, planName: "Documents")
        bare.outcome = .succeeded
        #expect(RunRecordPresentation.detail(for: bare) == "Succeeded")
    }

    @Test("the Detail column and the plan page's facts agree word for word")
    func detailAgreesWithPlanFacts() {
        let record = backup {
            $0.outcome = .completedWithErrors
            $0.itemErrors = ["/a: permission denied", RunRecord.retentionSkippedPrefix + "locked"]
            $0.itemErrorCount = 1
            $0.hookMessages = ["Hook “notify” exited 1"]
        }
        #expect(RunRecordPresentation.detail(for: record) == PlanStatus.facts(for: record).joined(separator: " · "))
    }

    @Test("exit codes are explained only where the meaning is command-independent")
    func exitCodeText() {
        #expect(RunRecordPresentation.exitCodeText(3) == "3 — Finished, but some data could not be read")
        #expect(RunRecordPresentation.exitCodeText(10) == "10 — The repository does not exist")
        #expect(RunRecordPresentation.exitCodeText(11) == "11 — The repository is already locked by another process")
        #expect(RunRecordPresentation.exitCodeText(12) == "12 — Wrong repository password or no matching key")
        // check exits 1 when it finds damage; "a fatal error" would mislabel it.
        #expect(RunRecordPresentation.exitCodeText(1) == "1")
        #expect(RunRecordPresentation.exitCodeText(130) == "130")
        #expect(RunRecordPresentation.exitCodeText(0) == nil)
    }

    @Test("Copy Details names the run, the numbers and the versions, and never a hook's output")
    func copyDetails() {
        let snapshotID = "73d9b51de71d34eb451a02fefd7e94ca3daa4e6c817f27549d2ff6bbf54d093f"
        let record = backup {
            $0.outcome = .completedWithErrors
            $0.snapshotID = snapshotID
            $0.filesNew = 2
            $0.filesChanged = 1
            $0.filesUnmodified = 13
            $0.exitCode = 3
            $0.itemErrors = ["open /Users/me/Documents/Taxes/2025/locked.pdf: permission denied"]
            $0.itemErrorCount = 1
            $0.hookMessages = ["Hook “curl” exited 1 — Authorization: Bearer x"]
            $0.resticVersion = "restic 0.19.1 compiled with go1.26.5 on darwin/arm64"
        }
        let text = RunRecordPresentation.detailsText(
            for: record,
            repositoryName: "Home NAS",
            versionsNow: RunLogVersions(app: "SwiftRestic 0.1.0 (1)", macOS: "macOS 26.6.2 (Build 25G83)", restic: "restic 0.20.0")
        )
        let lines = text.components(separatedBy: "\n")
        #expect(lines.first == "Backup of “Documents” — Completed with errors")
        #expect(lines.contains("Repository: Home NAS"))
        #expect(lines.contains("Snapshot: \(snapshotID)"))
        #expect(lines.contains("restic exit: 3 — Finished, but some data could not be read"))
        #expect(lines.contains("Unreadable items (1):"))
        #expect(lines.contains("  open /Users/me/Documents/Taxes/2025/locked.pdf: permission denied"))
        #expect(lines.contains("Hooks: 1 failed"))
        #expect(lines.contains("restic 0.19.1 compiled with go1.26.5 on darwin/arm64"))
        #expect(lines.last == "Copied from SwiftRestic 0.1.0 (1) on macOS 26.6.2 (Build 25G83)")
        // A hook's output stays on this Mac: counted, never quoted.
        #expect(!text.contains("Bearer"))
        #expect(!text.contains("curl"))
    }

    @Test("Copy Details for a retention run says what it removed")
    func copyDetailsForARetentionRun() {
        var record = RunRecord(kind: .forget, planName: "Documents")
        record.outcome = .succeeded
        record.detailText = "Removed 2 snapshots. Their data stays until the next prune."
        let text = RunRecordPresentation.detailsText(
            for: record,
            repositoryName: "Home NAS",
            versionsNow: RunLogVersions(app: "SwiftRestic 0.1.0 (1)", macOS: "macOS 26.6.2", restic: "restic 0.19.1")
        )
        let lines = text.components(separatedBy: "\n")
        #expect(lines.first == "Forget of “Documents” — Succeeded")
        #expect(lines.contains("Result: Removed 2 snapshots. Their data stays until the next prune."), "details were \(lines)")
    }

    @Test("Copy Details for a restore names the backup, the item and where it landed")
    func copyDetailsForARestore() {
        let record = restore {
            $0.snapshotID = "abf728998814d029"
            $0.sourcePath = "/src/Documents/Budget.numbers"
            $0.destinationPath = "/tmp/restored/Budget.numbers"
            $0.filesRestored = 1
            $0.filesSkipped = 2
            $0.bytesProcessed = 14
        }
        let text = RunRecordPresentation.detailsText(
            for: record,
            repositoryName: nil,
            versionsNow: RunLogVersions(app: "SwiftRestic 0.1.0 (1)", macOS: "macOS 26.6.2", restic: "restic 0.19.1")
        )
        let lines = text.components(separatedBy: "\n")
        #expect(lines.first == "Restore of “Budget.numbers” — Succeeded")
        #expect(lines.contains("Repository: No longer set up in SwiftRestic"))
        #expect(lines.contains("Snapshot: abf728998814d029"))
        #expect(lines.contains("Item: /src/Documents/Budget.numbers"))
        #expect(lines.contains("Restored to: /tmp/restored/Budget.numbers"))
        #expect(lines.contains("Files: 1 restored · 2 kept as they were · \(Format.bytes(14))"))
    }

    @Test("Copy Details for a whole-snapshot restore says so in the drawer's vocabulary")
    func copyDetailsForAWholeRestore() {
        let record = restore {
            $0.snapshotID = "abf728998814d029"
            $0.destinationPath = "/tmp/restored"
            $0.filesRestored = 17
            $0.bytesProcessed = 250_000
        }
        let text = RunRecordPresentation.detailsText(
            for: record,
            repositoryName: "Home NAS",
            versionsNow: RunLogVersions(app: "SwiftRestic 0.1.0 (1)", macOS: "macOS 26.6.2", restic: "restic 0.19.1")
        )
        let lines = text.components(separatedBy: "\n")
        // The drawer keeps "snapshot" beside its Snapshot row; "backup" is
        // the Restore pane's word.
        #expect(lines.contains("Item: Entire snapshot"), "details were \(lines)")
        #expect(lines.contains("Restored to: /tmp/restored"))
    }
}
