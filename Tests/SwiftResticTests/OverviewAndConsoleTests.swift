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

    @Test("the worst problem in the window is failed over completed-with-errors")
    func worstProblemSeverity() {
        var warned = run(plan: "Docs", at: "2026-09-05 01:00:00", added: 0)
        warned.outcome = .completedWithErrors
        var failed = run(plan: "Docs", at: "2026-09-06 01:00:00", added: 0)
        failed.outcome = .failed
        var old = run(plan: "Docs", at: "2026-08-01 01:00:00", added: 0)
        old.outcome = .failed

        let since = date("2026-09-01 00:00:00")
        // A failure anywhere in the window outranks a warning, regardless of
        // which one is newer — the tile's colour must not soften just
        // because the warning happened to record last.
        #expect(OverviewMetrics.worstProblemOutcome(runs: [warned, failed], since: since) == .failed)
        #expect(OverviewMetrics.worstProblemOutcome(runs: [warned], since: since) == .completedWithErrors)
        #expect(OverviewMetrics.worstProblemOutcome(runs: [], since: since) == nil)
        // A failure outside the window does not color a clean window's tile.
        #expect(OverviewMetrics.worstProblemOutcome(runs: [old], since: since) == nil)
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
        #expect(OverviewMetrics.worstProblemOutcome(runs: [overnight], since: since) == .failed)
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
        // `restore` leaves the repository alone but overwrites whatever sits
        // at the destination, so it confirms too.
        #expect(CommandLineTokenizer.isDestructive(["restore", "latest", "--target", "/tmp/x"]))
        // Leading flags must not hide the subcommand.
        #expect(CommandLineTokenizer.isDestructive(["--verbose", "repair", "index"]))

        #expect(!CommandLineTokenizer.isDestructive(["snapshots"]))
        #expect(!CommandLineTokenizer.isDestructive(["ls", "latest"]))
        #expect(!CommandLineTokenizer.isDestructive([]))
    }
}

@Suite("Plan colour slots")
struct PlanColourSlotTests {
    private func plan(id: UUID, chartIndex: Int? = nil) -> BackupPlan {
        var plan = BackupPlan()
        plan.id = id
        plan.chartIndex = chartIndex
        return plan
    }

    @Test("the fallback slot is deterministic across processes")
    func deterministicFallback() {
        // Pinned to this literal on purpose: Swift's Hasher is seeded per
        // process, so if this derivation ever regresses to Hasher-based
        // hashing, legacy plans' colours would change on every launch — and
        // only this assertion would notice.
        let legacy = plan(id: UUID(uuidString: "340CA842-C653-4E2D-B61F-D7653D70A521")!)
        #expect(ChartPalette.slot(for: legacy) == 6)
    }

    @Test("a negative stored slot cannot become a negative subscript")
    func negativeIndexClamps() {
        let hostile = plan(id: UUID(), chartIndex: -3)
        #expect((0..<ChartPalette.categorical.count).contains(ChartPalette.slot(for: hostile)))
    }

    @Test("new plans avoid the slots legacy plans already render with")
    func nextSlotAvoidsEffectiveSlots() {
        // A legacy plan whose fallback slot is 0: a naive taken-set built
        // from stored chartIndexes alone would hand slot 0 to the new plan.
        let legacy = plan(id: UUID(uuidString: "340CA842-C653-4E2D-B61F-D7653D70A521")!)
        let taken = Set([legacy].map { ChartPalette.slot(for: $0) })
        #expect(ChartPalette.nextSlot(taken: taken) != ChartPalette.slot(for: legacy))
    }

    @Test("explicit slots survive the modulo only within range")
    func explicitSlotStable() {
        let assigned = plan(id: UUID(), chartIndex: 2)
        #expect(ChartPalette.slot(for: assigned) == 2)
    }
}
