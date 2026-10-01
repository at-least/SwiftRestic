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
            isChecking: { $0 == checking }
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
        #expect(rows.last?.stateText.hasPrefix("Latest backup ") == true)
        #expect(rows.last?.isProtected == true)
        // The failure row is the only unknown-and-failing one.
        #expect(rows.filter(\.didFail).map(\.planName) == ["Failed"])
    }

    @Test("an idle repository that is not refreshing says so, not Checking…")
    func idleNotChecking() {
        let idle = UUID()
        let rows = OverviewMetrics.protectionRows(
            plans: [plan("Waiting", repository: idle)],
            latestSnapshot: { _, _ in nil },
            repositoryHasSnapshots: { _ in false },
            listingOutcome: { _ in .idle },
            isChecking: { _ in false }
        )
        #expect(rows.map(\.stateText) == ["Snapshot list not loaded yet"])
        #expect(rows.first?.isKnown == false)
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
