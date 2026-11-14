import Foundation
import Testing

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
        namedPlan(name, repositoryID: repositoryID)
    }

    private func repository(name: String) -> Repository {
        namedRepository(name)
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

        #expect(
            RunRecordPresentation.displayName(
                for: run(.backup, planID: documents.id, planName: "Documents", repositoryID: home.id),
                plans: [documents],
                repositories: [home]
            ) == "Documents (Home Disk)"
        )
        // The plan is called what it is called now, not what the record
        // stored.
        var renamed = documents
        renamed.path = "/Users/someone/Papers"
        #expect(
            RunRecordPresentation.displayName(
                for: run(.backup, planID: documents.id, planName: "Documents", repositoryID: home.id),
                plans: [renamed],
                repositories: [home]
            ) == "Papers (Home Disk)"
        )
        #expect(
            RunRecordPresentation.displayName(
                for: run(.restore, planName: "Budget.numbers", repositoryID: home.id),
                plans: [documents],
                repositories: [home]
            ) == "Budget.numbers (Home Disk)"
        )
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

    @Test("the menu bar's Next line says the plan with its repository, then when")
    func nextRunLine() {
        let home = repository(name: "Home Disk")
        let documents = plan(name: "Documents", repositoryID: home.id)
        let date = Date(timeIntervalSince1970: 1_790_409_497)

        #expect(
            RunRecordPresentation.nextRunLine(plan: documents, date: date, plans: [documents], repositories: [home])
                == "Documents (Home Disk) — \(Format.tileTimestamp(date))"
        )
        // A repository the list does not resolve leaves the plan's name alone.
        #expect(
            RunRecordPresentation.nextRunLine(plan: documents, date: date, plans: [documents], repositories: [])
                == "Documents — \(Format.tileTimestamp(date))"
        )
    }

    @Test("a failure whose cause the app knows offers its fix: the repository's editor for its password or path; a lock offers none, the run having unlocked already")
    func failureFixes() {
        let repository = UUID()
        var wrongPassword = backup {
            $0.repositoryID = repository
            $0.outcome = .failed
            $0.exitCode = 12
        }
        #expect(RunRecordPresentation.fix(for: wrongPassword, repositoryExists: true) == .enterPassword(repository))
        #expect(RunRecordPresentation.fix(for: wrongPassword, repositoryExists: false) == nil)

        // restic's "does not exist": the repository is not at its
        // location — its folder moved or renamed on a drive that is here.
        // A repository's location is fixed, so where it is now is a new
        // repository.
        let missing = backup {
            $0.repositoryID = repository
            $0.outcome = .failed
            $0.exitCode = 10
        }
        #expect(RunRecordPresentation.fix(for: missing, repositoryExists: true) == .addRepository(repository))

        let locked = backup {
            $0.repositoryID = repository
            $0.outcome = .failed
            $0.exitCode = 11
        }
        #expect(RunRecordPresentation.fix(for: locked, repositoryExists: true) == nil)

        // No known cause, or no failure: nothing to offer.
        var other = backup {
            $0.repositoryID = repository
            $0.outcome = .failed
            $0.exitCode = 1
        }
        #expect(RunRecordPresentation.fix(for: other, repositoryExists: true) == nil)
        other.outcome = .completedWithErrors
        other.exitCode = 12
        #expect(RunRecordPresentation.fix(for: other, repositoryExists: true) == nil)
        wrongPassword.repositoryID = nil
        #expect(RunRecordPresentation.fix(for: wrongPassword, repositoryExists: true) == nil)
        #expect(RunFix.enterPassword(repository).title == "Enter Password…")
        #expect(RunFix.addRepository(repository).title == "Add Backup Location…")
        // The failure message beside the button already says the cause.
        #expect(RunFix.enterPassword(repository).help == nil)
        #expect(RunFix.addRepository(repository).help == nil)
    }

    @Test("a backup whose folder is gone offers Locate Folder… for its plan, and nothing once the plan is gone")
    func goneFolderFix() {
        let plan = UUID()
        let gone = backup {
            $0.repositoryID = UUID()
            $0.planID = plan
            $0.outcome = .failed
            $0.missingSources = ["/Users/me/Documents"]
        }
        #expect(RunRecordPresentation.fix(for: gone, repositoryExists: true) == .locateFolder(planID: plan))
        #expect(
            RunRecordPresentation.fix(for: gone, repositoryExists: true, planExists: false) == nil,
            "a removed plan has no folder left to move"
        )
        // The failure message tells the user to press it by this name.
        #expect(RunFix.locateFolder(planID: plan).title == "Locate Folder…")
        #expect(RunFix.locateFolder(planID: plan).help == nil)
    }

    @Test("a failure for a network share that refused asks for the share's password: the repository's own share, or a plan folder's")
    func refusedShareFixes() {
        let repository = UUID()
        let plan = UUID()
        var refused = backup {
            $0.repositoryID = repository
            $0.planID = plan
            $0.outcome = .failed
            $0.refusedShares = ["NAS"]
        }
        #expect(RunRecordPresentation.fix(for: refused, repositoryExists: true, repositoryVolume: "NAS")
            == .enterSharePassword(.repository(repository)))
        #expect(RunRecordPresentation.fix(for: refused, repositoryExists: true, repositoryVolume: nil)
            == .enterSharePassword(.plan(plan)))
        #expect(RunRecordPresentation.fix(for: refused, repositoryExists: true, planExists: false, repositoryVolume: "Backups") == nil)
        // A check or prune refused its repository's share.
        refused.kind = .check
        refused.planID = nil
        #expect(RunRecordPresentation.fix(for: refused, repositoryExists: true, repositoryVolume: "NAS")
            == .enterSharePassword(.repository(repository)))
        #expect(RunFix.enterSharePassword(.repository(repository)).title == "Enter Share Password…")
        #expect(RunFix.enterSharePassword(.plan(plan)).help == "SwiftRestic uses this password to reconnect the network share")
    }

    @Test("a retention the storage refused offers no fix: only the storage can allow deletions")
    func refusedRetentionFix() {
        let refused = backup {
            $0.repositoryID = UUID()
            $0.planID = UUID()
            $0.outcome = .completedWithErrors
            $0.itemErrors = [RunRecord.retentionSkippedPrefix + "This storage doesn’t allow deleting, so 1 old backup stays."]
        }
        #expect(RunRecordPresentation.fix(for: refused, repositoryExists: true) == nil)
    }

    @Test("a run with problems reads in its kind's words: a backup skipped files or kept old backups, a verification found problems")
    func outcomeNamePerKind() {
        let kept = backup {
            $0.outcome = .completedWithErrors
            $0.itemErrors = [RunRecord.retentionSkippedPrefix + "This storage doesn’t allow deleting, so 1 old backup stays."]
        }
        #expect(kept.outcomeName == "Old backups not removed")
        var skipped = backup { $0.outcome = .completedWithErrors }
        skipped.itemErrorCount = 1
        #expect(skipped.outcomeName == "Some files skipped")
        skipped.itemErrorCount = 0
        skipped.exitCode = ResticError.backupPartialSuccessCode
        #expect(skipped.outcomeName == "Some files skipped", "an exit 3 that named nothing still skipped files")
        // Files skipped and old backups kept: the files lead.
        skipped.itemErrors = [RunRecord.retentionSkippedPrefix + "the location was busy."]
        #expect(skipped.outcomeName == "Some files skipped")
        var damaged = RunRecord(kind: .check)
        damaged.outcome = .completedWithErrors
        #expect(damaged.outcomeName == "Problems found")
        damaged.outcome = .failed
        #expect(damaged.outcomeName == "Failed")
    }

    @Test("a backup that filled its repository's disk says so in plain words and offers Free Up Space; a write anywhere else keeps restic's")
    func repositoryFull() {
        let words = "is full — the backup needed more room than it has free. What it uploaded before it stopped stays in the location until space is freed."
        var onDrive = Repository()
        onDrive.kind = .local
        onDrive.localPath = "/Volumes/TinyDisk/repo"
        let line = "Fatal: unable to save snapshot: write /Volumes/TinyDisk/repo/data/52/526d738f-tmp-77604366: no space left on device"
        #expect(RunRecord.repositoryFullMessage(resticMessage: line, repository: onDrive) == "“TinyDisk” \(words)")
        onDrive.localPath = "/Volumes/TinyDisk/repo/"
        #expect(RunRecord.repositoryFullMessage(resticMessage: line, repository: onDrive) == "“TinyDisk” \(words)")
        var onThisMac = Repository()
        onThisMac.kind = .local
        onThisMac.localPath = "/Users/me/Backups/repo"
        #expect(RunRecord.repositoryFullMessage(
            resticMessage: "Fatal: unable to save snapshot: write /Users/me/Backups/repo/data/aa/aa11-tmp-1: no space left on device",
            repository: onThisMac
        ) == "This Mac’s disk \(words)")
        // Written elsewhere — restic's cache on this Mac, a folder beside the
        // repository's — or another error, or a remote repository: restic's
        // words stand.
        #expect(RunRecord.repositoryFullMessage(
            resticMessage: "Fatal: unable to save snapshot: write /Users/me/Library/Caches/restic/abc/data/x: no space left on device",
            repository: onDrive
        ) == nil)
        onDrive.localPath = "/Volumes/TinyDisk/repo"
        #expect(RunRecord.repositoryFullMessage(resticMessage: "Fatal: write /Volumes/TinyDisk/repo2/data/x: no space left on device", repository: onDrive) == nil)
        #expect(RunRecord.repositoryFullMessage(resticMessage: "Fatal: write /Volumes/TinyDisk/repo/data/x: input/output error", repository: onDrive) == nil)
        var remote = Repository()
        remote.kind = .sftp
        #expect(RunRecord.repositoryFullMessage(resticMessage: line, repository: remote) == nil)

        let repository = UUID()
        let full = backup {
            $0.repositoryID = repository
            $0.outcome = .failed
            $0.exitCode = 1
            $0.repositoryFull = true
        }
        #expect(RunRecordPresentation.fix(for: full, repositoryExists: true) == .freeUpSpace(repository))
        #expect(RunRecordPresentation.fix(for: full, repositoryExists: false) == nil)
        #expect(RunFix.freeUpSpace(repository).title == "Free Up Space")
    }

    @Test("a check or prune that did not end clean offers itself again; nothing else does")
    func maintenanceRetry() {
        let repository = UUID()
        func run(_ kind: RunRecord.Kind, _ outcome: RunRecord.Outcome) -> RunRecord {
            var record = RunRecord(kind: kind, repositoryID: repository)
            record.outcome = outcome
            return record
        }
        #expect(RunRecordPresentation.maintenanceRetry(for: run(.check, .failed), repositoryExists: true) == .check(repository))
        // A check that found damage: its verdict, not a crash, is the news.
        #expect(RunRecordPresentation.maintenanceRetry(for: run(.check, .completedWithErrors), repositoryExists: true) == .check(repository))
        #expect(RunRecordPresentation.maintenanceRetry(for: run(.prune, .failed), repositoryExists: true) == .prune(repository))
        #expect(MaintenanceRetry.check(repository).title == "Verify Again")
        #expect(MaintenanceRetry.prune(repository).title == "Free Up Space Again")
        // A clean or cancelled one, another kind, a repository gone: nothing.
        #expect(RunRecordPresentation.maintenanceRetry(for: run(.check, .succeeded), repositoryExists: true) == nil)
        #expect(RunRecordPresentation.maintenanceRetry(for: run(.prune, .cancelled), repositoryExists: true) == nil)
        #expect(RunRecordPresentation.maintenanceRetry(for: run(.backup, .failed), repositoryExists: true) == nil)
        #expect(RunRecordPresentation.maintenanceRetry(for: run(.check, .failed), repositoryExists: false) == nil)

        // Only a check that found damage routes to the console, whose
        // `restic repair` its verdict advises.
        #expect(RunRecordPresentation.repairRoute(for: run(.check, .completedWithErrors), repositoryExists: true) == repository)
        #expect(RunRecordPresentation.repairRoute(for: run(.check, .failed), repositoryExists: true) == nil)
        #expect(RunRecordPresentation.repairRoute(for: run(.check, .succeeded), repositoryExists: true) == nil)
        #expect(RunRecordPresentation.repairRoute(for: run(.backup, .completedWithErrors), repositoryExists: true) == nil)
        #expect(RunRecordPresentation.repairRoute(for: run(.check, .completedWithErrors), repositoryExists: false) == nil)
    }

    @Test("a check's Detail is its verdict's first sentence; a row continuing a line drops the period")
    func checkVerdict() {
        func check(_ outcome: RunRecord.Outcome, _ verdict: String?) -> RunRecord {
            var record = RunRecord(kind: .check, planName: "")
            record.outcome = outcome
            record.detailText = verdict
            return record
        }
        let damaged = check(.completedWithErrors, "2 errors — restic repair can recover some damage. Freeing space is suggested.")
        #expect(RunRecordPresentation.detail(for: damaged) == "2 errors — restic repair can recover some damage")
        #expect(RunRecordPresentation.verdictClause(for: damaged) == "2 errors — restic repair can recover some damage")
        // A stored verdict with a period before the command, which the
        // sentence cut leaves alone: shown whole, its own final period
        // dropped like every entry's.
        let older = check(.completedWithErrors, "2 errors. `restic repair` can recover some damage.")
        #expect(RunRecordPresentation.detail(for: older) == "2 errors. `restic repair` can recover some damage")
        // No verdict at all: the outcome, as every kind without words.
        #expect(RunRecordPresentation.detail(for: check(.completedWithErrors, nil)) == "Problems found")
        #expect(RunRecordPresentation.verdictClause(for: check(.completedWithErrors, nil)) == "problems found")
        #expect(RunRecordPresentation.detail(for: check(.succeeded, "No errors found.")) == "No errors found")
    }

    @Test("the Detail column's wording for each kind of run")
    func detailWording() {
        let detail = RunRecordPresentation.detail(for:)

        #expect(detail(backup {
            $0.outcome = .failed
            $0.failureMessage = "The backup location does not exist — Fatal: …"
        }) == "The backup location does not exist — Fatal: …")

        // restic's multi-line tail stays in the drawer; the scan line keeps
        // the first sentence.
        #expect(detail(backup {
            $0.outcome = .failed
            $0.failureMessage = "restic stopped with an error — Fatal: unable to open config file: stat /Volumes/T/config: no such file or directory\nIs there a repository at the following location?"
        }) == "restic stopped with an error — Fatal: unable to open config file: stat /Volumes/T/config: no such file or directory")

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
        }) == "1 unreadable item · Old backups not removed")

        #expect(detail(backup {
            $0.outcome = .completedWithErrors
            $0.itemErrors = [RunRecord.retentionSkippedPrefix + "locked"]
        }) == "Old backups not removed")

        #expect(detail(backup {
            $0.filesNew = 2
            $0.filesChanged = 1
        }) == "2 new · 1 changed")

        // restic exited 3 and named nothing: the snapshot is short something,
        // and a file count would pass for a clean run.
        #expect(detail(backup {
            $0.outcome = .completedWithErrors
            $0.exitCode = 3
            $0.filesNew = 1
        }) == "Some files couldn’t be read")

        // …and it stays said when other facts come along: a skipped retention
        // step must not stand in for the unread data.
        #expect(detail(backup {
            $0.outcome = .completedWithErrors
            $0.exitCode = 3
            $0.itemErrors = [RunRecord.retentionSkippedPrefix + "locked"]
        }) == "Some files couldn’t be read · Old backups not removed")

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

        // A restore record with no stored counts falls back to its outcome.
        #expect(detail(restore()) == "Succeeded")

        #expect(detail(RunRecord(kind: .check, planName: "Home NAS")) == "Succeeded")
        var failedCheck = RunRecord(kind: .check, planName: "Home NAS")
        failedCheck.outcome = .completedWithErrors
        #expect(detail(failedCheck) == "Problems found")

        // A prune's is what it freed.
        var prune = RunRecord(kind: .prune, planName: "Home NAS")
        prune.detailText = "Freed 3 MB."
        #expect(detail(prune) == "Freed 3 MB.", "a prune's Detail names what it freed")
    }

    @Test("an unreadable item reads as its name, where it is and why — from the path the run stored, not restic's words taken apart")
    func unreadableItemWords() {
        let sources = ["/Volumes/Data/Documents", "/Volumes/Data/Projects"]
        func words(_ line: String, _ path: String?) -> UnreadableItemWords? {
            RunRecordPresentation.unreadableItemWords(line: line, path: path, sources: sources)
        }
        let denied = "/Volumes/Data/Documents/Medical/vacc.pdf"
        #expect(words("\(denied): open \(denied): permission denied", denied)
            == UnreadableItemWords(name: "vacc.pdf", location: "Documents/Medical", reason: "permission denied"))
        let mail = "/Volumes/Data/Documents/Mail"
        #expect(words("\(mail): open \(mail): operation not permitted", mail)
            == UnreadableItemWords(name: "Mail", location: "Documents", reason: "blocked by macOS"))
        // A top folder restic skipped is named where it lives.
        #expect(words("/Volumes/Data/Projects does not exist, skipping", "/Volumes/Data/Projects")
            == UnreadableItemWords(name: "Projects", location: "/Volumes/Data", reason: "not on this Mac"))
        #expect(words("/Volumes/Data/Projects cannot be accessed, skipping", "/Volumes/Data/Projects")?.reason == "can’t be accessed")
        // Any other cause in restic's words, after the item's own name.
        let odd = "/Volumes/Data/Documents/odd.bin"
        #expect(words("\(odd): read \(odd): input/output error", odd)?.reason == "read \(odd): input/output error")
        // Outside the plan's folders, where it is on disk.
        #expect(words("/Volumes/Other/x.txt: open /Volumes/Other/x.txt: permission denied", "/Volumes/Other/x.txt")?.location == "/Volumes/Other")
        // Byte for byte, as the index compares (ResticPath.holds): a folder
        // spelt in NFC does not hold the same name spelt in NFD.
        #expect(RunRecordPresentation.unreadableItemWords(line: "x", path: "/Caf\u{0065}\u{0301}/x.txt", sources: ["/Caf\u{00E9}"])?.location == "/Caf\u{0065}\u{0301}")
        // A whole-disk plan's "/" names no folder: its items read as on disk.
        #expect(RunRecordPresentation.unreadableItemWords(line: "x", path: NSHomeDirectory() + "/Library/Mail", sources: ["/"])?.location == "~/Library")
        // A plan folder written with a tilde holds what is under it.
        let home = NSHomeDirectory() + "/Notes/a.md"
        #expect(RunRecordPresentation.unreadableItemWords(line: "\(home): open \(home): permission denied", path: home, sources: ["~/Notes"])?.location == "Notes")
        // A Prepend character ending the item's name joins the ": " after it
        // into one Character, so a Character count of the name is one short
        // of the prefix on the line: cut by bytes, or the reason loses its
        // first letter.
        let prepend = "/Volumes/Data/Documents/new\u{0600}"
        #expect(words("\(prepend): lstat \(prepend): no such file or directory", prepend)?.reason
            == "lstat \(prepend): no such file or directory")
        // Nested plan folders: the item is placed under the nearest one.
        let nested = "/Volumes/Data/Documents/Medical/scan.pdf"
        #expect(RunRecordPresentation.unreadableItemWords(
            line: "\(nested): open \(nested): permission denied", path: nested,
            sources: ["/Volumes/Data", "/Volumes/Data/Documents"]
        )?.location == "Documents/Medical")
        // A line with no stored path stays restic's own.
        #expect(words("restic: some message without an item", nil) == nil)
    }

    @Test("the Detail column and the plan page's facts agree word for word")
    func detailAgreesWithPlanFacts() {
        let record = backup {
            $0.outcome = .completedWithErrors
            $0.itemErrors = ["/a: permission denied", RunRecord.retentionSkippedPrefix + "locked"]
            $0.itemErrorCount = 1
        }
        #expect(RunRecordPresentation.detail(for: record) == PlanStatus.facts(for: record).joined(separator: " · "))
    }

    @Test("exit codes show bare: the failure text says what they mean")
    func exitCodeText() {
        // forget's 3 is a refused deletion, not unread data.
        #expect(RunRecordPresentation.exitCodeText(3) == "3")
        #expect(RunRecordPresentation.exitCodeText(12) == "12")
        #expect(RunRecordPresentation.exitCodeText(1) == "1")
        #expect(RunRecordPresentation.exitCodeText(130) == "130")
        #expect(RunRecordPresentation.exitCodeText(0) == nil)
    }

    @Test("a copied Activity row names the run, the numbers and the versions")
    func copyDetails() {
        let snapshotID = "73d9b51de71d34eb451a02fefd7e94ca3daa4e6c817f27549d2ff6bbf54d093f"
        let record = backup {
            $0.outcome = .completedWithErrors
            $0.snapshotID = snapshotID
            $0.filesNew = 2
            $0.filesChanged = 1
            $0.filesUnmodified = 13
            $0.bytesProcessed = 3_400_000_000
            $0.dataAdded = 120_000_000
            $0.exitCode = 3
            $0.itemErrors = ["open /Users/me/Documents/Taxes/2025/locked.pdf: permission denied"]
            $0.itemErrorCount = 1
            $0.resticVersion = "restic 0.19.1 compiled with go1.26.5 on darwin/arm64"
        }
        let text = RunRecordPresentation.detailsText(
            for: record,
            repositoryName: "Home NAS",
            versionsNow: RunLogVersions(app: "SwiftRestic 0.1.0 (1)", macOS: "macOS 26.6.2 (Build 25G83)", restic: "restic 0.20.0")
        )
        let lines = text.components(separatedBy: "\n")
        #expect(lines.first == "Backup of “Documents” — Some files skipped")
        #expect(lines.contains("Location: Home NAS"))
        #expect(lines.contains("Backup: \(snapshotID)"))
        // The drawer's words for the numbers, the notification's "new data".
        #expect(lines.contains("Files: 2 new · 1 changed · 13 unchanged"))
        #expect(lines.contains("Size: Checked \(Format.bytes(3_400_000_000)) · \(Format.bytes(120_000_000)) of new data"))
        #expect(lines.contains("restic exit: 3"))
        #expect(lines.contains("Unreadable items (1):"))
        #expect(lines.contains("  open /Users/me/Documents/Taxes/2025/locked.pdf: permission denied"))
        #expect(lines.contains("restic 0.19.1 compiled with go1.26.5 on darwin/arm64"))
        #expect(lines.last == "Copied from SwiftRestic 0.1.0 (1) on macOS 26.6.2 (Build 25G83)")
    }

    @Test("a copied Activity row for freeing space says what it freed")
    func copyDetailsForFreedSpace() {
        var record = RunRecord(kind: .prune, planName: "Home NAS")
        record.outcome = .succeeded
        record.detailText = "Freed 3 MB."
        let lines = RunRecordPresentation.detailsText(
            for: record,
            repositoryName: "Home NAS",
            versionsNow: RunLogVersions(app: "SwiftRestic 0.1.0 (1)", macOS: "macOS 26.6.2", restic: "restic 0.19.1")
        ).components(separatedBy: "\n")
        #expect(lines.contains("Result: Freed 3 MB."), "details were \(lines)")
    }

    @Test("a copied Activity row for a restore names the backup, the item and where it landed")
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
        #expect(lines.contains("Location: No longer set up in SwiftRestic"))
        #expect(lines.contains("Backup: abf728998814d029"))
        #expect(lines.contains("Item: /src/Documents/Budget.numbers"))
        #expect(lines.contains("Restored to: /tmp/restored/Budget.numbers"))
        #expect(lines.contains("Files: 1 restored · 2 kept as they were · \(Format.bytes(14))"))
    }

    @Test("a copied Activity row for a whole-snapshot restore says so in the drawer's vocabulary")
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
        #expect(lines.contains("Item: Entire backup"), "details were \(lines)")
        #expect(lines.contains("Restored to: /tmp/restored"))
    }

    @Test("restic's own sentence stays out of the message and in a copied Activity row")
    func resticDetailReachesCopyDetailsOnly() throws {
        var run = RunRecord(kind: .backup, planName: "Documents")
        run.setOutcome(
            from: ResticError.commandFailed(exitCode: 12, message: "Fatal: wrong password or no key found"),
            cancellationMessage: "Stopped",
            location: ("Home NAS", .sftp)
        )
        #expect(run.failureMessage == "The password doesn’t open “Home NAS”.")
        #expect(run.resticDetail == "Fatal: wrong password or no key found")
        let lines = RunRecordPresentation.detailsText(
            for: run, repositoryName: "Home NAS",
            versionsNow: RunLogVersions(app: "1", macOS: "26", restic: "0.19.1")
        ).components(separatedBy: "\n")
        #expect(lines.contains("restic: Fatal: wrong password or no key found"))

        let decoded = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(run))
        #expect(decoded.resticDetail == run.resticDetail)
    }

    @Test("a stopped run's copied Activity row says Stopped in its first line, with no Error line repeating it")
    func copyDetailsOfAStop() {
        var run = RunRecord(kind: .backup, planName: "Documents")
        run.setOutcome(from: CancellationError(), cancellationMessage: "Stopped", location: nil)
        let lines = RunRecordPresentation.detailsText(
            for: run, repositoryName: "Home NAS",
            versionsNow: RunLogVersions(app: "1", macOS: "26", restic: "0.19.1")
        ).components(separatedBy: "\n")
        #expect(lines.first == "Backup of “Documents” — Stopped")
        #expect(!lines.contains { $0.hasPrefix("Error:") }, "details were \(lines)")
    }

    @Test("a stop stored in the old word still reads as the outcome, not as a second message")
    func oldCancelledMessageIsTheOutcome() throws {
        let stored = #"{"kind":"backup","outcome":"cancelled","failureMessage":"Cancelled"}"#
        let run = try JSONDecoder().decode(RunRecord.self, from: Data(stored.utf8))
        #expect(run.outcomeName == "Stopped")
        #expect(run.failureMessage == run.outcomeName)
    }

    @Test("a copied Activity row for a failed multi-item restore names the items, the destination, the error and the count past the sample")
    func copyDetailsForAFailedMultiItemRestore() {
        let record = restore {
            $0.outcome = .failed
            $0.failureMessage =
                "A file or alias is already at /tmp/there/Report.pdf, where a restored folder would go, so nothing was restored. Move it aside, or restore somewhere else."
            $0.sourcePaths = ["/src/Documents/a.pdf", "/src/Documents/b.pdf"]
            $0.destinationPath = "/tmp/there"
            // The sample keeps one line; the count says how many there were.
            $0.itemErrorCount = 3
            $0.itemErrors = ["/src/Documents/a.pdf: open /src/Documents/a.pdf: permission denied"]
        }
        let text = RunRecordPresentation.detailsText(
            for: record,
            repositoryName: nil,
            versionsNow: RunLogVersions(app: "SwiftRestic 0.1.0 (1)", macOS: "macOS 26.6.2", restic: "restic 0.19.1")
        )
        let lines = text.components(separatedBy: "\n")
        #expect(lines.first == "Restore of “Budget.numbers” — Failed")
        #expect(lines.contains(
            "Error: A file or alias is already at /tmp/there/Report.pdf, where a restored folder would go, so nothing was restored. Move it aside, or restore somewhere else."
        ))
        #expect(lines.contains("Items: /src/Documents/a.pdf, /src/Documents/b.pdf"))
        #expect(lines.contains("Destination: /tmp/there"))
        #expect(lines.contains("Unreadable items (3):"))
        #expect(lines.contains("  … and 2 more"))
    }
}
