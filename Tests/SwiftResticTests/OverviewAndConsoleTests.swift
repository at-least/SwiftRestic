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

    @Test("Recent problems reads a standing cause as one row with its count, newest first, the newest run its own")
    func problemGroups() {
        let documents = UUID()
        let code = UUID()
        let repository = UUID()
        func problem(_ planID: UUID?, _ kind: RunRecord.Kind, _ outcome: RunRecord.Outcome, hour: Int) -> RunRecord {
            var record = RunRecord(kind: kind, planID: planID, repositoryID: repository, startedAt: date("2026-10-01 00:00:00").addingTimeInterval(Double(hour) * 3600))
            record.outcome = outcome
            return record
        }
        // One unreadable file warns every daily run; one failure elsewhere.
        let warnings = (0 ..< 7).map { problem(documents, .backup, .completedWithErrors, hour: $0 * 24) }
        let failure = problem(code, .backup, .failed, hour: 30)
        let documentsFailed = problem(documents, .backup, .failed, hour: 20)
        let check = problem(nil, .check, .completedWithErrors, hour: 10)
        let groups = OverviewMetrics.problemGroups(warnings.shuffled() + [failure, documentsFailed, check])
        #expect(groups.map(\.count) == [7, 1, 1, 1])
        #expect(groups.map(\.newest.id) == [warnings[6].id, failure.id, documentsFailed.id, check.id])
        // The same plan failing is its own row, not folded into its warnings.
        #expect(Set(groups.map(\.newest.outcome)) == [.completedWithErrors, .failed])
        #expect(OverviewMetrics.problemGroups([]).isEmpty)

        // The plan page's count is the row's: the week's runs that ended
        // like the standing problem; one for a problem older than the week.
        let runs = warnings + [failure, documentsFailed, check]
        let now = date("2026-10-07 12:00:00")
        #expect(OverviewMetrics.recurrences(of: warnings[6], in: runs, now: now) == 7)
        #expect(OverviewMetrics.recurrences(of: failure, in: runs, now: now) == 1)
        #expect(OverviewMetrics.recurrences(of: warnings[6], in: runs, now: date("2026-10-20 12:00:00")) == 1)
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
        // The failure row is the only unknown-and-failing one, and the only
        // loaded one with no lastBackupAt to count.
        #expect(rows.filter(\.didFail).map(\.planName) == ["Failed"])
        #expect(rows.first { $0.planName == "Failed" }?.lastBackupAt == nil)
    }

    @Test("a protected row says when in the sidebar's words, from the same formatter")
    func protectedRowMatchesTheSidebar() {
        // 1 h 43 min ago: Date.RelativeFormatStyle rounds this to "2 hours
        // ago" while the sidebar's Format.relative (RelativeDateTimeFormatter)
        // says "1 hour ago" — the dashboard's Protection card and the
        // sidebar sit side by side and must agree.
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
        // Photos waits in a before-backup hook and restic stamps its snapshot
        // after it, so the sidebar (the run's start, lastSuccessAt) and the
        // card (the snapshot's time) must count the same backup from the same
        // moment.
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
        // The caption is the bare last-backup line — the sidebar carries
        // no next run — so the shared derivation shows directly: the
        // "Last backup" moment itself, spelled identically, and the row's
        // lastBackupAt is that same moment (the run's stamp, not the
        // snapshot's own time).
        #expect(sidebar.text == rows[0].stateText)
        #expect(rows.first?.lastBackupAt == photos.lastSuccessAt)
        #expect(rows.first?.isProtected == true)
    }

    @Test("one Last backup: the caption, the Protection line and the plan page's value say the same moment")
    func lastBackupSaidOneWay() {
        // The surfaces that say when a plan last backed up — the sidebar
        // caption, the repository page's Protection line, the plan page's
        // Last backup value — all read PlanStatus.lastBackupAt, spelled by
        // one formatter as of one tick. The tray and Settings say no last
        // backup at all.
        let repository = UUID()
        let tick = Date.now
        let ago = { Format.ago($0, now: tick) }

        // The same plan/snapshot state through each surface's derivation.
        func surfaces(_ plan: BackupPlan, newest: Snapshot?) -> (caption: String, row: String, line: String?, page: String) {
            let rows = OverviewMetrics.protectionRows(
                plans: [plan],
                latestSnapshot: { _, _ in newest },
                repositoryHasSnapshots: { _ in newest != nil },
                listingOutcome: { _ in .loaded },
                isChecking: { _ in false },
                activity: { _ in nil },
                standingProblem: { _ in nil },
                relative: ago
            )
            let summary = OverviewMetrics.protectionSummary(
                rows: rows, listingLoaded: true, otherBackupsCount: 0,
                willNotRun: { _ in nil }, hold: nil, now: tick, relative: ago
            )
            let caption = PlanStatus.sidebarCaption(
                for: plan, activity: nil, problem: nil, latestSnapshot: newest,
                existingRepositoryIDs: [repository], now: tick, relative: ago
            )
            // The plan page's value is this moment through the same
            // formatter (PlanDetailView.lastBackupValue).
            let page = ago(PlanStatus.lastBackupAt(plan: plan, latestSnapshot: newest))
            return (caption.text, rows[0].stateText, summary?.text, page)
        }

        // History that arrived with the repository: no run of the plan's
        // own, the newest snapshot two days old — that snapshot is the
        // moment everywhere, never "Never" or the schedule beside it. An
        // hour past the day boundary: `RelativeDateTimeFormatter` reads
        // 48 h flat as "2 days ago" but a hair under it as "1 day ago",
        // and `snapshot(_:, at:)`'s JSON round-trip can land that hair
        // under an exact two-day delta — every surface must spell the same
        // moment, or a tick flips one of them.
        var adopted = plan("Docs", repository: repository)
        adopted.sources = ["/Users/someone/Documents"]
        adopted.schedule.frequency = .daily
        let adoptedSnapshotTime = tick.addingTimeInterval(-2 * 86_400 - 3_600)
        let adoptedWords = ago(adoptedSnapshotTime)
        let adoptedSurfaces = surfaces(adopted, newest: snapshot("snapDocs", at: adoptedSnapshotTime))
        #expect(adoptedSurfaces.caption == "Last backup \(adoptedWords)")
        #expect(adoptedSurfaces.row == "Last backup \(adoptedWords)")
        #expect(adoptedSurfaces.page == adoptedWords)
        #expect(adoptedSurfaces.line == "1 of 1 plan protected · Last backup \(adoptedWords)")

        // A run of the plan's own: the run's start is the moment even while
        // restic stamped the snapshot later (the before-backup hooks), so
        // the same backup cannot straddle a minute between surfaces.
        var ranHere = plan("Photos", repository: repository)
        ranHere.lastSuccessAt = tick.addingTimeInterval(-207)
        let ranWords = ago(tick.addingTimeInterval(-207))
        let ranSurfaces = surfaces(ranHere, newest: snapshot("snapPhotos", at: tick.addingTimeInterval(-162)))
        #expect(ranSurfaces.caption == "Last backup \(ranWords)")
        #expect(ranSurfaces.row == "Last backup \(ranWords)")
        #expect(ranSurfaces.page == ranWords)
        #expect(ranSurfaces.line == "1 of 1 plan protected · Last backup \(ranWords)")

        // "Never" only when there is truly nothing: no run, no snapshot.
        #expect(PlanStatus.lastBackupAt(plan: plan("Empty", repository: repository), latestSnapshot: nil) == nil)
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
        // One derivation of the words: the dashboard's row must say the
        // sidebar's caption, not a "Last backup" beside a standing failure.
        let sidebar = PlanStatus.sidebarCaption(
            for: docs, activity: nil, problem: failed, existingRepositoryIDs: [repository]
        )
        #expect(rows.map(\.stateText) == [sidebar.text])
        #expect(rows.first?.isKnown == true)
        #expect(rows.first?.isProtected == false)
    }

    @Test("a run that completed with errors still wrote a snapshot, so the plan stays protected")
    func standingWarning() {
        let repository = UUID()
        let docs = plan("Docs", repository: repository)
        let warnedAt = Date.now.addingTimeInterval(-540)
        var warned = RunRecord(kind: .backup, planName: "Docs", startedAt: .now.addingTimeInterval(-600))
        warned.planID = docs.id
        warned.outcome = .completedWithErrors
        warned.finishedAt = warnedAt
        // The listing's moment is the decoded snapshot's own time: a Date's
        // trip through the helper's JSON number moves its last bits.
        let written = snapshot("snapDocs", at: warnedAt)
        let rows = OverviewMetrics.protectionRows(
            plans: [docs],
            latestSnapshot: { _, _ in written },
            repositoryHasSnapshots: { _ in true },
            listingOutcome: { _ in .loaded },
            isChecking: { _ in false },
            activity: { _ in nil },
            standingProblem: { _ in warned }
        )
        #expect(rows.first?.stateText.hasPrefix("\(RunRecord.Outcome.completedWithErrors.displayName) — ") == true)
        #expect(rows.first?.isProtected == true)
        // The problem override keeps the listing's moment for the line.
        #expect(rows.first?.lastBackupAt == written.time)
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
    }

    private func protectionRow(
        _ name: String,
        isKnown: Bool,
        isProtected: Bool,
        lastBackupAt: Date? = nil
    ) -> ProtectionRow {
        ProtectionRow(
            plan: plan(name, repository: UUID()),
            stateText: name,
            isKnown: isKnown,
            isProtected: isProtected,
            didFail: false,
            lastBackupAt: lastBackupAt
        )
    }

    @Test("the Protection line counts known rows, names the newest last backup, and carries the hold")
    func protectionLine() {
        let rows = [
            protectionRow("Protected", isKnown: true, isProtected: true, lastBackupAt: date("2026-09-05 09:00:00")),
            protectionRow("Exposed", isKnown: true, isProtected: false, lastBackupAt: date("2026-09-05 10:00:00")),
            protectionRow("Reading", isKnown: false, isProtected: false),
        ]
        // The still-reading plan is in neither number, and the last backup
        // is the newer of the two moments that have one.
        let plain = OverviewMetrics.protectionSummary(
            rows: rows, listingLoaded: true, otherBackupsCount: 3,
            willNotRun: { _ in nil }, hold: nil, now: date("2026-09-05 11:00:00"),
            relative: { _ in "1 hour ago" }
        )
        #expect(plain?.text == "1 of 2 plans protected · Last backup 1 hour ago")
        #expect(plain?.showsResume == false)

        // The hold's words are the hold's own summary, joined on.
        let end = date("2026-09-05 14:00:00")
        let paused = OverviewMetrics.protectionSummary(
            rows: rows, listingLoaded: true, otherBackupsCount: 0,
            willNotRun: { _ in nil }, hold: .paused(until: end), now: date("2026-09-05 11:00:00"),
            relative: { _ in "1 hour ago" }
        )
        #expect(paused?.text == "1 of 2 plans protected · Last backup 1 hour ago · "
            + ScheduleHold.paused(until: end).summary(now: date("2026-09-05 11:00:00")))
        #expect(paused?.showsResume == true)

        // Only the user's own pause gets the button; the battery's ends by
        // plugging in.
        let onBattery = OverviewMetrics.protectionSummary(
            rows: rows, listingLoaded: true, otherBackupsCount: 0,
            willNotRun: { _ in nil }, hold: .onBattery, now: date("2026-09-05 11:00:00"),
            relative: { _ in "1 hour ago" }
        )
        #expect(onBattery?.text == "1 of 2 plans protected · Last backup 1 hour ago · Backups wait for power — this Mac is on battery")
        #expect(onBattery?.showsResume == false)

        // One plan spells its own noun; no plan with a backup yet omits the
        // moment entirely rather than promising "Never".
        let single = OverviewMetrics.protectionSummary(
            rows: [protectionRow("Only", isKnown: true, isProtected: true, lastBackupAt: nil)],
            listingLoaded: true, otherBackupsCount: 0, willNotRun: { _ in nil }, hold: nil,
            now: date("2026-09-05 11:00:00"), relative: { _ in "1 hour ago" }
        )
        #expect(single?.text == "1 of 1 plan protected")
        let neverRan = OverviewMetrics.protectionSummary(
            rows: [
                protectionRow("Empty", isKnown: true, isProtected: false),
                protectionRow("Adopted", isKnown: true, isProtected: false),
            ],
            listingLoaded: true, otherBackupsCount: 0, willNotRun: { _ in nil }, hold: nil,
            now: date("2026-09-05 11:00:00"), relative: { _ in "1 hour ago" }
        )
        #expect(neverRan?.text == "0 of 2 plans protected")
    }

    @Test("the Protection card names each protected plan that will not run by itself, in the sidebar's words")
    func protectionNamesPlansThatWillNotRun() {
        let repository = UUID()
        let now = date("2026-09-05 11:00:00")
        var photos = plan("Photos", repository: repository)
        photos.sources = ["/Users/someone/Pictures"]
        photos.schedule.frequency = .weekly
        photos.isEnabled = false
        var documents = plan("Documents", repository: repository)
        documents.sources = ["/Users/someone/Documents"]
        documents.schedule.frequency = .daily
        documents.pausedUntil = date("2026-09-05 13:00:00")
        var code = plan("Code", repository: repository)
        code.schedule.frequency = .hourly
        var manual = plan("Archive", repository: repository)
        manual.sources = ["/Users/someone/Archive"]
        manual.schedule.frequency = .manual
        manual.isEnabled = false
        var running = plan("Music", repository: repository)
        running.sources = ["/Users/someone/Music"]
        running.schedule.frequency = .daily
        let plans = [photos, documents, code, manual, running]

        // The sidebar's pause words, "Not scheduled" for a plan the
        // scheduler skips; a manual plan never runs by itself, paused or not.
        func caption(_ plan: BackupPlan) -> String? {
            PlanStatus.willNotRunCaption(for: plan, existingRepositoryIDs: [repository], now: now)
        }
        #expect(caption(photos) == PlanStatus.pauseCaption(for: photos, now: now))
        #expect(caption(photos) == "Paused — \(photos.schedule.summary)")
        #expect(caption(documents) == PlanStatus.pauseCaption(for: documents, now: now))
        #expect(caption(code) == "Not scheduled")
        #expect(caption(manual) == nil)
        #expect(caption(running) == nil)

        let rows = plans.map {
            ProtectionRow(
                plan: $0, stateText: "Last backup 1 hour ago",
                isKnown: true, isProtected: true, didFail: false, lastBackupAt: date("2026-09-05 10:00:00")
            )
        }
        let byID = Dictionary(uniqueKeysWithValues: plans.map { ($0.id, $0) })
        let skipReason = "“Archive SSD” is not connected; the other folders were backed up."
        let summary = OverviewMetrics.protectionSummary(
            rows: rows, listingLoaded: true, otherBackupsCount: 0,
            willNotRun: { byID[$0].flatMap(caption) },
            partialSkip: { $0 == code.id ? skipReason : nil },
            hold: nil, now: now, relative: { _ in "1 hour ago" }
        )
        #expect(summary?.text == "5 of 5 plans protected · Last backup 1 hour ago")
        #expect(summary?.attentionLines == [])
        // A protected plan backing up around an away drive is named in the
        // record's words, beside its held line if it has one.
        #expect(summary?.skippedLines == ["Code: \(skipReason)"])
        #expect(summary?.heldLines == [
            "Photos: Paused — \(photos.schedule.summary)",
            "Documents: \(PlanStatus.pauseCaption(for: documents, now: now) ?? "")",
            "Code: Not scheduled",
        ])

        // An unprotected plan's line is its warning, never a second one.
        let exposed = ProtectionRow(plan: photos, stateText: "No snapshots yet", isKnown: true, isProtected: false, didFail: false)
        let warned = OverviewMetrics.protectionSummary(
            rows: [exposed], listingLoaded: true, otherBackupsCount: 0,
            willNotRun: { byID[$0].flatMap(caption) },
            hold: nil, now: now, relative: { _ in "1 hour ago" }
        )
        #expect(warned?.attentionLines == ["Photos: No snapshots yet"])
        #expect(warned?.heldLines == [])
    }

    @Test("the Protection card names each plan that is not protected in the sidebar warning's words, and a run in flight")
    func protectionNamesItsSubjects() {
        let repository = UUID()
        let now = date("2026-09-05 11:00:00")
        let documents = ProtectionRow(
            plan: plan("Documents", repository: repository), stateText: "Last backup 1 hour ago",
            isKnown: true, isProtected: true, didFail: false, lastBackupAt: date("2026-09-05 10:00:00")
        )
        let code = ProtectionRow(
            plan: plan("Code", repository: repository), stateText: "Failed — 3 hours ago",
            isKnown: true, isProtected: false, didFail: false
        )
        let summary = OverviewMetrics.protectionSummary(
            rows: [code, documents], listingLoaded: true, otherBackupsCount: 0,
            willNotRun: { _ in nil }, hold: nil, now: now, relative: { _ in "1 hour ago" }
        )
        // The count line stays as it was; the lines under it name the subject.
        #expect(summary?.text == "1 of 2 plans protected · Last backup 1 hour ago")
        #expect(summary?.attentionLines == ["Code: Failed — 3 hours ago"])
        // All protected: nothing to name.
        #expect(OverviewMetrics.protectionSummary(
            rows: [documents], listingLoaded: true, otherBackupsCount: 0,
            willNotRun: { _ in nil }, hold: nil, now: now, relative: { _ in "1 hour ago" }
        )?.attentionLines == [])

        // A first backup in flight is news, not an alarm: the line says the
        // run in the sidebar's words, and names no exposed plan.
        let photos = ProtectionRow(
            plan: plan("Photos", repository: repository), stateText: "Backing up",
            isKnown: true, isProtected: false, didFail: false, isRunning: true
        )
        let running = OverviewMetrics.protectionSummary(
            rows: [photos], listingLoaded: true, otherBackupsCount: 0,
            willNotRun: { _ in nil }, hold: nil, now: now, relative: { _ in "1 hour ago" }
        )
        #expect(running?.text == "0 of 1 plan protected · Photos — Backing up")
        #expect(running?.attentionLines == [])
        // Beside a last backup, the run comes before it.
        let both = OverviewMetrics.protectionSummary(
            rows: [photos, documents], listingLoaded: true, otherBackupsCount: 0,
            willNotRun: { _ in nil }, hold: nil, now: now, relative: { _ in "1 hour ago" }
        )
        #expect(both?.text == "1 of 2 plans protected · Photos — Backing up · Last backup 1 hour ago")
    }

    @Test("an unreadable listing is said in one sentence by the rows and the caveat alike")
    func listingFailureHasOneSentence() {
        #expect(OverviewMetrics.listingFailureText("Repository /nas is not reachable. More detail.")
            == "Can't read snapshots — Repository /nas is not reachable")
    }

    @Test("the Protection line waits for a succeeded listing")
    func protectionLineWaitsForTheListing() {
        let rows = [protectionRow("Fine", isKnown: true, isProtected: true, lastBackupAt: date("2026-09-05 10:00:00"))]
        // Still reading, or unreadable: the caveat under Details speaks,
        // and the line hides — with plans and without.
        #expect(OverviewMetrics.protectionSummary(
            rows: rows, listingLoaded: false, otherBackupsCount: 2,
            willNotRun: { _ in nil }, hold: .paused(until: nil), now: date("2026-09-05 11:00:00"), relative: { _ in "1 hour ago" }
        ) == nil)
        #expect(OverviewMetrics.protectionSummary(
            rows: [], listingLoaded: false, otherBackupsCount: 2,
            willNotRun: { _ in nil }, hold: nil, now: date("2026-09-05 11:00:00")
        ) == nil)
    }

    @Test("with no plans, the line names the adoptable side — or nothing to name")
    func protectionLineWithNoPlans() {
        let now = date("2026-09-05 11:00:00")
        let withHistory = OverviewMetrics.protectionSummary(
            rows: [], listingLoaded: true, otherBackupsCount: 6, willNotRun: { _ in nil }, hold: nil, now: now
        )
        #expect(withHistory?.text == "No plans yet · 6 backups from no plan here")
        #expect(withHistory?.showsResume == false)

        let empty = OverviewMetrics.protectionSummary(
            rows: [], listingLoaded: true, otherBackupsCount: 0, willNotRun: { _ in nil }, hold: nil, now: now
        )
        #expect(empty?.text == "No plans yet")

        // The hold joins here too: it holds this repository's checks and
        // prunes, plans or no plans.
        let held = OverviewMetrics.protectionSummary(
            rows: [], listingLoaded: true, otherBackupsCount: 0, willNotRun: { _ in nil }, hold: .paused(until: nil), now: now
        )
        #expect(held?.text == "No plans yet · Backups paused until you resume")
        #expect(held?.showsResume == true)
    }

    @Test("the Snapshots value splits the count no plan of the repository made")
    func snapshotsValueSplit() {
        #expect(OverviewMetrics.snapshotsLine(total: 11, otherBackups: 6) == "11 · 6 from no plan here")
        #expect(OverviewMetrics.snapshotsLine(total: 11, otherBackups: 0) == "11")
        // A plan-less repository's: none of its backups is a plan's.
        #expect(OverviewMetrics.snapshotsLine(total: 11, otherBackups: 11) == "11 · all from no plan here")
        // How far back the history reaches, after the split; a single
        // backup reaches no further than itself.
        let oldest = Date(timeIntervalSince1970: 1_748_782_800)
        #expect(OverviewMetrics.snapshotsLine(total: 495, otherBackups: 0, since: oldest) == "495 · since \(Format.day(oldest))")
        #expect(OverviewMetrics.snapshotsLine(total: 11, otherBackups: 6, since: oldest)
            == "11 · 6 from no plan here · since \(Format.day(oldest))")
        #expect(OverviewMetrics.snapshotsLine(total: 1, otherBackups: 0, since: oldest) == "1")
        #expect(OverviewMetrics.snapshotsLine(total: 0, otherBackups: 0, since: nil) == "0")
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
        // not eight days old. A start-time basis would drop it, and the
        // tray's line counts it — the two must agree on an overnight run
        // that failed at dawn.
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

        // What may change the backups the app lists: those, and `tag` and
        // `copy`, which confirm nothing but write snapshots.
        #expect(CommandLineTokenizer.mayChangeSnapshots(["-r", "/repo", "forget", "--keep-last", "1"]))
        #expect(CommandLineTokenizer.mayChangeSnapshots(["tag", "--add", "x", "latest"]))
        #expect(CommandLineTokenizer.mayChangeSnapshots(["copy", "--from-repo", "/other"]))
        #expect(!CommandLineTokenizer.mayChangeSnapshots(["snapshots"]))
        #expect(!CommandLineTokenizer.mayChangeSnapshots(["ls", "latest"]))
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
