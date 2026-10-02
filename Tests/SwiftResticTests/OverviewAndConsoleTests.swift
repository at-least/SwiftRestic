import Foundation
import Testing

@Suite("Overview metrics")
struct OverviewMetricsTests {
    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: string)!
    }

    private func run(plan: String, at day: String, added: Int64) -> RunRecord {
        var record = RunRecord(kind: .backup, planName: plan, startedAt: date(day))
        record.dataAdded = added
        return record
    }

    // MARK: - Protection rows

    private func plan(_ name: String, repository: UUID?) -> BackupPlan {
        var plan = BackupPlan()
        plan.name = name
        plan.repositoryID = repository
        return plan
    }

    private func snapshot(_ id: String, at time: Date) -> Snapshot {
        let document: [String: Any] = [
            "id": id,
            "short_id": String(id.prefix(8)),
            "time": time.timeIntervalSince1970,
            "paths": ["/data"],
            "tags": [],
        ]
        let data = try! JSONSerialization.data(withJSONObject: document)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try! decoder.decode(Snapshot.self, from: data)
    }

    @Test("protection rows sort by severity and spell each state")
    func protectionRowsOrderAndSpelling() {
        let failed = UUID() // listing failed
        let healthy = UUID() // loaded, and the plan has a snapshot in it
        let checking = UUID() // idle, refresh in flight
        let empty = UUID() // loaded, but the repository holds nothing
        let adopted = UUID() // loaded, snapshots exist, none from this plan
        let plans = [
            plan("Fine", repository: healthy),
            plan("NoRepo", repository: nil),
            plan("Checking", repository: checking),
            plan("Failed", repository: failed),
            plan("Empty", repository: empty),
            plan("Adopted", repository: adopted),
        ]
        let latest = snapshot("snapHealthy", at: date("2026-09-05 10:00:00"))
        let rows = OverviewMetrics.protectionRows(
            plans: plans,
            latestSnapshot: { repository, _ in repository == healthy ? latest : nil },
            repositoryHasSnapshots: { $0 == healthy || $0 == adopted },
            listingOutcome: { repository in
                switch repository {
                case failed: .failed("Repository /nas is not reachable. Check the host and try again.")
                case checking: .idle
                default: .loaded
                }
            },
            isChecking: { $0 == checking },
            activity: { _ in nil },
            standingProblem: { _ in nil }
        )

        // Unreadable first, then exposed, then pending, protected last; ties
        // inside a rank keep the plan order.
        #expect(rows.map(\.planName) == ["Failed", "NoRepo", "Empty", "Adopted", "Checking", "Fine"])
        // The protected line is relative-spelled and locale-owned, so it is
        // pinned by prefix below, not by literal.
        #expect(Array(rows.map(\.stateText).prefix(5)) == [
            "Can't read snapshots — Repository /nas is not reachable",
            "No repository set",
            "No snapshots yet",
            "The repository has snapshots, but none from this plan yet.",
            "Checking…",
        ])
        #expect(rows.last?.stateText.hasPrefix("Last backup ") == true)
        #expect(rows.last?.isProtected == true)
        // The failure row is the only unknown-and-failing one.
        #expect(rows.filter(\.didFail).map(\.planName) == ["Failed"])
    }

    @Test("a protected row says when in the sidebar's words, from the same formatter")
    func protectedRowMatchesTheSidebar() {
        // 1 h 43 min ago: Date.RelativeFormatStyle rounds this to "2 hours
        // ago" while the sidebar's Format.relative (RelativeDateTimeFormatter)
        // says "1 hour ago" — the dashboard's Protection card (now a
        // repository page's Plans card) and the sidebar disagreed about the
        // same backup, side by side (captured 2026-10-02).
        let repository = UUID()
        let time = Date.now.addingTimeInterval(-103 * 60)
        let rows = OverviewMetrics.protectionRows(
            plans: [plan("Docs", repository: repository)],
            latestSnapshot: { _, _ in snapshot("snapDocs", at: time) },
            repositoryHasSnapshots: { _ in true },
            listingOutcome: { _ in .loaded },
            isChecking: { _ in false },
            activity: { _ in nil },
            standingProblem: { _ in nil }
        )
        #expect(rows.map(\.stateText) == ["Last backup \(Format.relative(time))"])
    }

    @Test("a protected row counts from the moment the sidebar counts from")
    func protectedRowCountsFromTheRun() {
        // Photos waits 45 s in a before-backup hook, and restic stamps its
        // snapshot after it: the sidebar read "Last backup 3 minutes ago"
        // (the run's start, lastSuccessAt) beside the card's "2 minutes ago"
        // (the snapshot's time), same backup, same tick (captured 2026-10-02).
        let repository = UUID()
        var photos = plan("Photos", repository: repository)
        photos.lastSuccessAt = Date.now.addingTimeInterval(-207)
        let rows = OverviewMetrics.protectionRows(
            plans: [photos],
            latestSnapshot: { _, _ in snapshot("snapPhotos", at: Date.now.addingTimeInterval(-162)) },
            repositoryHasSnapshots: { _ in true },
            listingOutcome: { _ in .loaded },
            isChecking: { _ in false },
            activity: { _ in nil },
            standingProblem: { _ in nil }
        )
        let sidebar = PlanStatus.sidebarCaption(
            for: photos, activity: nil, problem: nil, existingRepositoryIDs: [repository]
        )
        #expect(rows.map(\.stateText) == [sidebar.text])
        #expect(rows.first?.isProtected == true)
    }

    @Test("an idle repository that is not refreshing says so, not Checking…")
    func idleNotChecking() {
        let idle = UUID()
        let rows = OverviewMetrics.protectionRows(
            plans: [plan("Waiting", repository: idle)],
            latestSnapshot: { _, _ in nil },
            repositoryHasSnapshots: { _ in false },
            listingOutcome: { _ in .idle },
            isChecking: { _ in false },
            activity: { _ in nil },
            standingProblem: { _ in nil }
        )
        #expect(rows.map(\.stateText) == ["Snapshot list not loaded yet"])
        #expect(rows.first?.isKnown == false)
    }

    @Test("a run in flight says its phase and sorts calm, between pending and protected")
    func runInFlight() {
        let empty = UUID() // loaded, nothing in it yet: the first backup is running
        let idle = UUID()
        let healthy = UUID()
        let first = plan("First", repository: empty)
        let rows = OverviewMetrics.protectionRows(
            plans: [plan("Fine", repository: healthy), first, plan("Waiting", repository: idle)],
            latestSnapshot: { repository, _ in
                repository == healthy ? snapshot("snapFine", at: date("2026-09-05 10:00:00")) : nil
            },
            repositoryHasSnapshots: { $0 == healthy },
            listingOutcome: { $0 == idle ? .idle : .loaded },
            isChecking: { _ in false },
            activity: { $0 == first.id ? PlanActivity(phase: .backingUp) : nil },
            standingProblem: { _ in nil }
        )
        #expect(rows.map(\.planName) == ["Waiting", "First", "Fine"])
        let running = rows.first { $0.planName == "First" }
        // The sidebar caption's words for the same activity.
        #expect(running?.stateText == "Backing up")
        #expect(running?.isRunning == true)
        // The listing still decides the count: no snapshot yet is not
        // protected, and a run in flight is no alarm either.
        #expect(running?.isProtected == false)
        #expect(running?.didFail == false)
    }

    @Test("a standing failure says the sidebar's words and leaves the plan unprotected")
    func standingFailure() {
        let repository = UUID()
        let docs = plan("Docs", repository: repository)
        var failed = RunRecord(kind: .backup, planName: "Docs", startedAt: .now.addingTimeInterval(-300))
        failed.planID = docs.id
        failed.outcome = .failed
        failed.finishedAt = .now.addingTimeInterval(-240)
        let rows = OverviewMetrics.protectionRows(
            plans: [docs],
            latestSnapshot: { _, _ in snapshot("snapDocs", at: .now.addingTimeInterval(-4 * 3600)) },
            repositoryHasSnapshots: { _ in true },
            listingOutcome: { _ in .loaded },
            isChecking: { _ in false },
            activity: { _ in nil },
            standingProblem: { $0 == docs.id ? failed : nil }
        )
        // One derivation of the words: the dashboard (now a repository
        // page's Plans card) printed "Last backup 4 hours ago" beside the
        // sidebar's "Failed — Just now" (captured 2026-10-02), and "2 of 2
        // protected" above it.
        let sidebar = PlanStatus.sidebarCaption(
            for: docs, activity: nil, problem: failed, existingRepositoryIDs: [repository]
        )
        #expect(rows.map(\.stateText) == [sidebar.text])
        #expect(rows.first?.problemOutcome == .failed)
        #expect(rows.first?.isKnown == true)
        #expect(rows.first?.isProtected == false)
    }

    @Test("a run that completed with errors still wrote a snapshot, so the plan stays protected")
    func standingWarning() {
        let repository = UUID()
        let docs = plan("Docs", repository: repository)
        var warned = RunRecord(kind: .backup, planName: "Docs", startedAt: .now.addingTimeInterval(-600))
        warned.planID = docs.id
        warned.outcome = .completedWithErrors
        warned.finishedAt = .now.addingTimeInterval(-540)
        let rows = OverviewMetrics.protectionRows(
            plans: [docs],
            latestSnapshot: { _, _ in snapshot("snapDocs", at: .now.addingTimeInterval(-540)) },
            repositoryHasSnapshots: { _ in true },
            listingOutcome: { _ in .loaded },
            isChecking: { _ in false },
            activity: { _ in nil },
            standingProblem: { _ in warned }
        )
        #expect(rows.first?.stateText.hasPrefix("\(RunRecord.Outcome.completedWithErrors.displayName) — ") == true)
        #expect(rows.first?.problemOutcome == .completedWithErrors)
        #expect(rows.first?.isProtected == true)
    }

    @Test("an unreadable listing outranks a standing problem: its row owns the Retry")
    func listingFailureWins() {
        let repository = UUID()
        let docs = plan("Docs", repository: repository)
        var failed = RunRecord(kind: .backup, planName: "Docs")
        failed.planID = docs.id
        failed.outcome = .failed
        let rows = OverviewMetrics.protectionRows(
            plans: [docs],
            latestSnapshot: { _, _ in nil },
            repositoryHasSnapshots: { _ in false },
            listingOutcome: { _ in .failed("Repository /nas is not reachable. Check the host.") },
            isChecking: { _ in false },
            activity: { _ in nil },
            standingProblem: { _ in failed }
        )
        #expect(rows.map(\.stateText) == ["Can't read snapshots — Repository /nas is not reachable"])
        #expect(rows.first?.didFail == true)
        #expect(rows.first?.problemOutcome == nil)
    }

    @Test("problem figures")
    func headlineFigures() {
        var failed = run(plan: "Docs", at: "2026-09-05 01:00:00", added: 0)
        failed.outcome = .failed
        var warned = run(plan: "Docs", at: "2026-09-06 01:00:00", added: 0)
        warned.outcome = .completedWithErrors
        var old = run(plan: "Docs", at: "2026-08-01 01:00:00", added: 0)
        old.outcome = .failed
        #expect(OverviewMetrics.problemCount(
            runs: [failed, warned, old],
            since: date("2026-09-01 00:00:00")
        ) == 2)
    }

    @Test("a repository's problems are the week's problems that ran against it, of every kind")
    func problemsOfOneRepository() {
        let nas = UUID()
        let since = date("2026-09-01 00:00:00")
        func problem(_ kind: RunRecord.Kind, in repository: UUID?, at day: String) -> RunRecord {
            var record = RunRecord(kind: kind, planName: "Docs", repositoryID: repository, startedAt: date(day))
            record.outcome = .failed
            return record
        }
        // A check or prune has no plan, so the repository's page is the only
        // place near the repository its failure can be read.
        let backup = problem(.backup, in: nas, at: "2026-09-05 01:00:00")
        let check = problem(.check, in: nas, at: "2026-09-05 02:00:00")
        let prune = problem(.prune, in: nas, at: "2026-09-05 03:00:00")
        let elsewhere = problem(.backup, in: UUID(), at: "2026-09-05 04:00:00")
        let old = problem(.backup, in: nas, at: "2026-08-01 01:00:00")
        var fine = problem(.backup, in: nas, at: "2026-09-06 01:00:00")
        fine.outcome = .succeeded

        let runs = [backup, check, prune, elsewhere, old, fine]
        #expect(OverviewMetrics.problems(in: runs, since: since, repositoryID: nas).map(\.id)
            == [backup.id, check.id, prune.id])
        // The same week as the app-wide set, which still counts every one.
        #expect(OverviewMetrics.problems(in: runs, since: since).count == 4)
    }

    @Test("recency counts from when the run finished, matching the tray's line")
    func problemsCountFromFinishedAt() {
        var overnight = run(plan: "Docs", at: "2026-09-04 23:00:00", added: 0)
        overnight.outcome = .failed
        overnight.finishedAt = date("2026-09-05 06:00:00")

        let since = date("2026-09-05 00:00:00")
        // Started before the window, failed inside it: this morning's news,
        // not eight days old. A start-time basis would have dropped it — the
        // old tile disagreed with the tray's line exactly here, on an
        // overnight run that failed at dawn.
        #expect(OverviewMetrics.problemCount(runs: [overnight], since: since) == 1)
    }
}

@Suite("Run record")
struct RunRecordTests {
    @Test("duration never goes negative")
    func durationClamp() {
        var record = RunRecord(kind: .backup, planName: "Docs")
        record.finishedAt = record.startedAt.addingTimeInterval(90)
        #expect(record.duration == 90)

        // A clock adjusted backwards mid-run must not produce a negative
        // duration for the history list.
        record.finishedAt = record.startedAt.addingTimeInterval(-10)
        #expect(record.duration == 0)
    }
}

@Suite("Console command parsing")
struct CommandLineTokenizerTests {
    @Test("arguments split on whitespace")
    func simple() {
        #expect(CommandLineTokenizer.tokenize("snapshots --compact") == ["snapshots", "--compact"])
        #expect(CommandLineTokenizer.tokenize("   ") == [])
    }

    @Test("quotes hold a path with spaces together")
    func quoting() {
        // restic is launched directly, so nothing else would put this back together.
        #expect(CommandLineTokenizer.tokenize(#"ls latest "/Users/me/My Documents""#)
            == ["ls", "latest", "/Users/me/My Documents"])
        #expect(CommandLineTokenizer.tokenize("backup '/tmp/a b'") == ["backup", "/tmp/a b"])
        #expect(CommandLineTokenizer.tokenize(#"--tag "a b" --tag c"#) == ["--tag", "a b", "--tag", "c"])
    }

    @Test("escapes and empty quoted arguments")
    func escapes() {
        #expect(CommandLineTokenizer.tokenize(#"ls /tmp/a\ b"#) == ["ls", "/tmp/a b"])
        // An explicitly empty argument must survive as one.
        #expect(CommandLineTokenizer.tokenize(#"--tag """#) == ["--tag", ""])
        // A backslash is literal inside single quotes.
        #expect(CommandLineTokenizer.tokenize(#"'a\b'"#) == [#"a\b"#])
        // POSIX keeps a double-quoted backslash literal except before the
        // characters it reserves — a Windows path must not lose its slashes.
        #expect(CommandLineTokenizer.tokenize(#"ls "C:\Users\me""#) == ["ls", #"C:\Users\me"#])
        #expect(CommandLineTokenizer.tokenize(#"echo "a\$b""#) == ["echo", "a$b"])
        // And outside quotes it still escapes whatever follows.
        #expect(CommandLineTokenizer.tokenize(#"ls "a\\b""#) == ["ls", #"a\b"#])
    }

    @Test("a line ending inside an open quote is refused, not silently closed")
    func unterminatedQuotes() {
        #expect(CommandLineTokenizer.hasUnterminatedQuote(#"forget --keep-daily "7"#))
        #expect(CommandLineTokenizer.hasUnterminatedQuote("snapshots --tag 'weekly"))
        // A backslash can hide the closing quote, and the walk must know it.
        #expect(!CommandLineTokenizer.hasUnterminatedQuote(#"ls "/tmp/a\"b""#))
        #expect(!CommandLineTokenizer.hasUnterminatedQuote("snapshots --compact"))
        #expect(!CommandLineTokenizer.hasUnterminatedQuote(""))
    }

    @Test("commands that change the repository are flagged for confirmation")
    func destructiveDetection() {
        #expect(CommandLineTokenizer.isDestructive(["forget", "--keep-last", "1"]))
        #expect(CommandLineTokenizer.isDestructive(["prune"]))
        #expect(CommandLineTokenizer.isDestructive(["unlock"]))
        // `restore` leaves the repository alone but overwrites whatever sits
        // at the destination, so it confirms too.
        #expect(CommandLineTokenizer.isDestructive(["restore", "latest", "--target", "/tmp/x"]))
        // Leading flags must not hide the subcommand.
        #expect(CommandLineTokenizer.isDestructive(["--verbose", "repair", "index"]))
        // Global flags that take a value: the value must not step in as the
        // "subcommand" and arm no confirmation for what follows it.
        #expect(CommandLineTokenizer.isDestructive(["-r", "/repo", "prune"]))
        #expect(CommandLineTokenizer.isDestructive(["--repo", "/x", "forget", "--keep-daily", "7"]))

        #expect(!CommandLineTokenizer.isDestructive(["snapshots"]))
        #expect(!CommandLineTokenizer.isDestructive(["ls", "latest"]))
        #expect(!CommandLineTokenizer.isDestructive([]))
    }
}

@Suite("Run outcome markers")
struct RunOutcomeMarkerTests {
    @Test("success wears nothing, cancelled stays quiet, trouble keeps its alarms")
    func markerPerOutcome() {
        // The unread-dot rule: a clean run is the quiet default, and only
        // trouble asks to be seen.
        #expect(RunRecord.Outcome.succeeded.symbolName == nil)
        // Cancelled must never scan as success, but it is not an alarm either:
        // a quiet monochrome outline, not a filled glyph.
        #expect(RunRecord.Outcome.cancelled.symbolName == "slash.circle")
        #expect(RunRecord.Outcome.completedWithErrors.symbolName?.contains("exclamationmark") == true)
        #expect(RunRecord.Outcome.failed.symbolName?.contains("xmark") == true)
    }
}
