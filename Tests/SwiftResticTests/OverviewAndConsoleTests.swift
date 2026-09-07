import Foundation
import Testing

@Suite("Overview metrics")
struct OverviewMetricsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: string)!
    }

    private func run(
        plan: String,
        at day: String,
        added: Int64,
        kind: RunRecord.Kind = .backup,
        outcome: RunRecord.Outcome = .succeeded
    ) -> RunRecord {
        var record = RunRecord(kind: kind, planName: plan, startedAt: date(day))
        record.dataAdded = added
        record.outcome = outcome
        return record
    }

    @Test("runs are summed per plan per day")
    func dailyTotals() {
        let runs = [
            run(plan: "Docs", at: "2026-09-05 01:00:00", added: 100),
            run(plan: "Docs", at: "2026-09-05 13:00:00", added: 50),
            run(plan: "Photos", at: "2026-09-05 02:00:00", added: 400),
            run(plan: "Docs", at: "2026-09-04 01:00:00", added: 7),
        ]
        let points = OverviewMetrics.dailyVolume(
            runs: runs,
            planOrder: ["Docs", "Photos"],
            days: 30,
            now: date("2026-09-05 23:00:00"),
            calendar: calendar
        )
        let docsOn5 = points.first { $0.series == "Docs" && calendar.isDate($0.day, inSameDayAs: date("2026-09-05 00:00:00")) }
        #expect(docsOn5?.dataAdded == 150)
        #expect(points.first { $0.series == "Photos" }?.dataAdded == 400)
        #expect(points.count == 3)
    }

    @Test("only backups that wrote something are plotted")
    func filtersNonBackups() {
        let runs = [
            run(plan: "Docs", at: "2026-09-05 01:00:00", added: 100),
            run(plan: "Docs", at: "2026-09-05 02:00:00", added: 0),
            run(plan: "Repo", at: "2026-09-05 03:00:00", added: 900, kind: .prune),
            run(plan: "Docs", at: "2026-09-05 04:00:00", added: 500, outcome: .cancelled),
        ]
        let points = OverviewMetrics.dailyVolume(
            runs: runs,
            planOrder: ["Docs"],
            now: date("2026-09-05 23:00:00"),
            calendar: calendar
        )
        #expect(points.count == 1)
        #expect(points.first?.dataAdded == 100)
    }

    @Test("runs older than the window are dropped")
    func windowing() {
        let runs = [
            run(plan: "Docs", at: "2026-09-05 01:00:00", added: 100),
            run(plan: "Docs", at: "2026-07-01 01:00:00", added: 999),
        ]
        let points = OverviewMetrics.dailyVolume(
            runs: runs,
            planOrder: ["Docs"],
            days: 30,
            now: date("2026-09-05 23:00:00"),
            calendar: calendar
        )
        #expect(points.count == 1)
    }

    @Test("series keep configuration order, so a plan's colour does not move")
    func stableSeriesOrder() {
        // "Photos" writes far more, but ordering follows the plan list — ranking
        // by volume would repaint the chart whenever the data shifted.
        let runs = [
            run(plan: "Docs", at: "2026-09-05 01:00:00", added: 1),
            run(plan: "Photos", at: "2026-09-05 01:00:00", added: 10_000),
        ]
        let points = OverviewMetrics.dailyVolume(
            runs: runs,
            planOrder: ["Docs", "Photos"],
            now: date("2026-09-05 23:00:00"),
            calendar: calendar
        )
        #expect(OverviewMetrics.domain(for: points, planOrder: ["Docs", "Photos"]) == ["Docs", "Photos"])
    }

    @Test("past the colour cap the smallest plans fold into Other")
    func foldsPastTheCap() {
        // A ninth series is never a generated hue.
        var runs: [RunRecord] = []
        for index in 0 ..< 10 {
            runs.append(run(plan: "Plan\(index)", at: "2026-09-05 01:00:00", added: Int64(10 - index)))
        }
        let order = (0 ..< 10).map { "Plan\($0)" }
        let points = OverviewMetrics.dailyVolume(
            runs: runs,
            planOrder: order,
            now: date("2026-09-05 23:00:00"),
            calendar: calendar
        )
        let domain = OverviewMetrics.domain(for: points, planOrder: order)
        #expect(domain.count == OverviewMetrics.seriesCap + 1)
        #expect(domain.last == OverviewMetrics.otherSeriesName)
        #expect(!domain.contains("Plan9"))
        // The folded plans are summed, not dropped.
        let other = points.first { $0.series == OverviewMetrics.otherSeriesName }
        #expect(other?.dataAdded == 6) // Plan7 (3) + Plan8 (2) + Plan9 (1)
    }

    @Test("headline figures")
    func headlineFigures() {
        var failed = run(plan: "Docs", at: "2026-09-05 01:00:00", added: 0)
        failed.outcome = .failed
        var old = run(plan: "Docs", at: "2026-08-01 01:00:00", added: 0)
        old.outcome = .failed
        #expect(OverviewMetrics.failureCount(
            runs: [failed, old],
            since: date("2026-09-01 00:00:00")
        ) == 1)
    }

    @Test("a run with no plan name folds into Other rather than disappearing")
    func unnamedRunsFoldIntoOther() {
        // Console and restore runs record no plan; their bytes still count.
        let runs = [
            run(plan: "", at: "2026-09-05 01:00:00", added: 300),
            run(plan: "Docs", at: "2026-09-05 02:00:00", added: 100),
        ]
        let points = OverviewMetrics.dailyVolume(
            runs: runs,
            planOrder: ["Docs"],
            now: date("2026-09-05 23:00:00"),
            calendar: calendar
        )
        let other = points.first { $0.series == OverviewMetrics.otherSeriesName }
        #expect(other?.dataAdded == 300, "the unnamed run's 300 bytes must survive the fold")
        #expect(OverviewMetrics.domain(for: points, planOrder: ["Docs"]).last == OverviewMetrics.otherSeriesName)
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
    }

    @Test("commands that change the repository are flagged for confirmation")
    func destructiveDetection() {
        #expect(CommandLineTokenizer.isDestructive(["forget", "--keep-last", "1"]))
        #expect(CommandLineTokenizer.isDestructive(["prune"]))
        #expect(CommandLineTokenizer.isDestructive(["unlock"]))
        // Leading flags must not hide the subcommand.
        #expect(CommandLineTokenizer.isDestructive(["--verbose", "repair", "index"]))

        #expect(!CommandLineTokenizer.isDestructive(["snapshots"]))
        #expect(!CommandLineTokenizer.isDestructive(["ls", "latest"]))
        #expect(!CommandLineTokenizer.isDestructive([]))
    }
}
