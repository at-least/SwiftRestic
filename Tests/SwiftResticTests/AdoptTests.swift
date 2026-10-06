import Foundation
import Testing

/// Adopting a plan-UUID group: the draft the sheet edits, every sentence the
/// sheet shows around it, and the write itself — one plan whose id is the
/// group's UUID, nothing else. Every collision case has its own pin, so its
/// classification and the sheet's words cannot drift apart.
@MainActor
@Suite("Adopt")
struct AdoptTests {
    private let suiteName = "SwiftResticAdoptTests"

    /// The host this Mac claims, so every "this Mac / another Mac" decision
    /// in the pins is spelled by the fixture, not the machine.
    private let localHost = "mac"

    private func makeModel() -> AppModel {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppModel(
            store: ConfigStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("SwiftResticAdopt-\(UUID().uuidString)")),
            secrets: .inMemory(),
            defaults: defaults,
            localHostname: localHost
        )
    }

    private func makeRepository(_ name: String = "Home Disk") -> Repository {
        var repository = Repository()
        repository.name = name
        repository.kind = .local
        repository.localPath = "/tmp/adopt-repo"
        return repository
    }

    private func snapshot(
        _ id: String,
        time: String,
        paths: [String] = ["/Data/Docs"],
        host: String = "mac",
        tags: [String] = [],
        excludes: [String]? = nil
    ) throws -> Snapshot {
        // Arrays through JSONEncoder: interpolating a Swift array writes its
        // debug description, whose escaped quotes end up inside the strings.
        let array = { (strings: [String]) in String(decoding: try JSONEncoder().encode(strings), as: UTF8.self) }
        let excludesJSON = try excludes.map { ",\"excludes\":\(try array($0))" } ?? ""
        let json = """
        {"id":"\(id)","short_id":"\(id.prefix(8))","time":"\(time)","paths":\(try array(paths)),\
        "hostname":"\(host)","tags":\(try array(tags))\(excludesJSON)}
        """
        return try ResticMessageDecoder.jsonDecoder.decode(Snapshot.self, from: Data(json.utf8))
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    /// A folder that exists, for the schedule rule's "every prefilled folder
    /// is here" half.
    private func existingFolder() -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticAdopt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// The model with `repository` configured and `listing` as its read, so
    /// the shelves hold the groups the fixtures describe.
    private func loadModel(_ model: AppModel, repository: Repository, listing: [Snapshot]) {
        model.configuration.repositories = [repository]
        model.snapshots[repository.id] = listing
    }

    // MARK: - The draft

    @Test("the draft prefills from the newest backup this Mac made, and adopts one plan either way")
    func prefillPrefersThisMac() throws {
        let planID = UUID()
        let tag = ResticService.planTag(planID)
        // The newest backup overall is another Mac's; this Mac's is older and
        // backed up different folders with different patterns and tags.
        let foreign = try snapshot(
            "newest", time: "2026-10-02T11:45:00Z", paths: ["/Data/Movies"], host: "other-mac",
            tags: [tag], excludes: ["*.iso"]
        )
        let local = try snapshot(
            "local", time: "2026-09-28T10:00:00Z", paths: ["/Data/Docs", "/Data/Photos"],
            tags: [tag, "travel"], excludes: ["node_modules", ".env"]
        )
        let model = makeModel()
        let repository = makeRepository()
        loadModel(model, repository: repository, listing: [foreign, local])

        let draft = try #require(model.adoptDraft(repositoryID: repository.id, planID: planID))
        #expect(draft.id == planID)
        #expect(draft.repositoryID == repository.id)
        // The group's label names the draft: the row, the page and the
        // sheet's title are one word.
        #expect(draft.name == "Movies")
        #expect(draft.sources == ["/Data/Docs", "/Data/Photos"])
        #expect(draft.excludePatterns == ["node_modules", ".env"])
        #expect(draft.tags == ["travel"])
        // The editor's own defaults keep what restic does not record.
        #expect(draft.excludeCaches == BackupPlan().excludeCaches)
        #expect(draft.oneFileSystem == BackupPlan().oneFileSystem)
        #expect(draft.hooks.isEmpty)
        // The app has never run this plan; its stamps say so.
        #expect(draft.lastRunAt == nil && draft.lastSuccessAt == nil)
    }

    @Test("the schedule follows the folders: Daily when every one is here, Manual otherwise")
    func scheduleFollowsTheFolders() throws {
        let here = existingFolder()
        let planID = UUID()
        let tag = ResticService.planTag(planID)
        let model = makeModel()
        let repository = makeRepository()

        let present = try snapshot("a", time: "2026-10-02T11:45:00Z", paths: [here], tags: [tag])
        loadModel(model, repository: repository, listing: [present])
        #expect(model.adoptDraft(repositoryID: repository.id, planID: planID)?.schedule.frequency == .daily)

        let missing = try snapshot("b", time: "2026-10-02T11:45:00Z", paths: [here, "/Data/Gone"], tags: [tag])
        loadModel(model, repository: repository, listing: [missing])
        #expect(model.adoptDraft(repositoryID: repository.id, planID: planID)?.schedule.frequency == .manual)
    }

    @Test("retention starts off — the history is the point of adopting")
    func retentionStartsOff() throws {
        let planID = UUID()
        let snapshot = try snapshot("a", time: "2026-10-02T11:45:00Z", tags: [ResticService.planTag(planID)])
        let model = makeModel()
        let repository = makeRepository()
        loadModel(model, repository: repository, listing: [snapshot])

        let draft = try #require(model.adoptDraft(repositoryID: repository.id, planID: planID))
        #expect(!draft.retention.isEnabled)
        #expect(draft.retention.summary == "Keep everything")
    }

    // MARK: - Collision rows

    @Test("a UUID that names a configured plan is its moved history, never adoptable")
    func movedGroupNeverAdopts() throws {
        let offsite = makeRepository("Offsite")
        var music = BackupPlan()
        music.name = "Music"
        music.repositoryID = offsite.id
        let snapshot = try snapshot("m1", time: "2026-10-02T11:45:00Z", tags: [ResticService.planTag(music.id)])
        let model = makeModel()
        let home = makeRepository()
        model.configuration.repositories = [home, offsite]
        model.configuration.plans = [music]
        model.snapshots[home.id] = [snapshot]

        #expect(model.adoptDraft(repositoryID: home.id, planID: music.id) == nil)
        // The page agrees on which variant it is.
        #expect(model.shelves(for: home.id).otherGroupPage(.plan(music.id), repositories: model.configuration.repositories, localHost: localHost)?.formerPlan == music)
    }

    @Test("an untagged group has no UUID to adopt")
    func untaggedGroupHasNoUUID() throws {
        let console = try snapshot("c1", time: "2026-10-02T11:45:00Z", tags: [])
        let model = makeModel()
        let repository = makeRepository()
        loadModel(model, repository: repository, listing: [console])

        let shelves = model.shelves(for: repository.id)
        // Every group the listing built is a lineage — none carries a plan
        // UUID, so no adopt verb anywhere can name one.
        #expect(shelves.others.allSatisfy {
            if case .lineage = $0 { return true } else { return false }
        })
        #expect(model.adoptDraft(repositoryID: repository.id, planID: UUID()) == nil)
    }

    @Test("a group from another Mac warns in order and asks before adopting")
    func foreignGroupWarnsAndConfirms() throws {
        let planID = UUID()
        let newest = try snapshot(
            "movies", time: "2026-10-02T11:45:00Z", paths: ["/Data/Movies"], host: "other-mac",
            tags: [ResticService.planTag(planID)]
        )
        let model = makeModel()
        let repository = makeRepository()
        loadModel(model, repository: repository, listing: [newest])
        var draft = try #require(model.adoptDraft(repositoryID: repository.id, planID: planID))
        draft.name = "Movies"

        let briefing = try #require(model.adoptBriefing(for: draft, now: date("2026-10-03T12:00:00Z")))
        #expect(briefing.historyLine == "This backup becomes this plan's history.")
        #expect(briefing.madeLine
            == "Made \(Format.historySpan(oldest: newest.time, newest: newest.time)) from other-mac."
                + " Nothing in “Home Disk” changes.")
        #expect(briefing.repositoryLine == "Home Disk — the backups live here")
        #expect(briefing.warnings == [
            "The newest backup was made on “other-mac” on \(Format.timestamp(newest.time)).",
            "The folders come from another Mac and may not exist here.",
            "These backups are recent — a plan on another Mac may still be writing them.",
        ])
        #expect(briefing.needsConfirmation)
        #expect(briefing.confirmation.title == "Adopt “Movies”?")
        #expect(briefing.confirmation.message
            == "This backup becomes the plan's history. Nothing is written to “Home Disk”."
                + " If another Mac still runs this plan, both Macs share one history and one retention policy"
                + " — adopt only backups no other Mac is still making.")
    }

    @Test("the folders warnings speak about the folders the sheet shows, not the prefill alone")
    func foldersWarningsFollowTheDraft() throws {
        let planID = UUID()
        let tag = ResticService.planTag(planID)
        let here = existingFolder()
        let foreign = try snapshot(
            "f", time: "2026-09-20T11:00:00Z", paths: ["/Data/Movies"], host: "other-mac", tags: [tag]
        )
        let model = makeModel()
        let repository = makeRepository()
        loadModel(model, repository: repository, listing: [foreign])
        var draft = try #require(model.adoptDraft(repositoryID: repository.id, planID: planID))

        // Replacing the other Mac's folders with this Mac's own takes the
        // another-Mac warning away — it spoke about folders no longer shown.
        draft.sources = [here]
        #expect(model.adoptBriefing(for: draft, now: date("2026-10-03T12:00:00Z"))?.warnings
            == ["The newest backup was made on “other-mac” on \(Format.timestamp(foreign.time))."])

        // A missing folder the user themselves set is a missing folder,
        // never another Mac's prefill.
        draft.sources = [here, "/Data/Gone"]
        #expect(model.adoptBriefing(for: draft, now: date("2026-10-03T12:00:00Z"))?.warnings.last
            == "Not all of these folders still exist on this Mac.")

        // This Mac's own prefill with a missing folder says the same
        // existence fact — whichever Mac the prefill came from.
        let local = try snapshot("l", time: "2026-09-28T10:00:00Z", paths: ["/Data/Gone"], tags: [tag])
        loadModel(model, repository: repository, listing: [local])
        let localDraft = try #require(model.adoptDraft(repositoryID: repository.id, planID: planID))
        #expect(model.adoptBriefing(for: localDraft, now: date("2026-10-03T12:00:00Z"))?.warnings
            == ["Not all of these folders still exist on this Mac."])
    }

    @Test("a clean old local group adopts in one click, once its folders are here")
    func cleanLocalGroupNeedsNoDialog() throws {
        let planID = UUID()
        let here = existingFolder()
        // Three days old, this Mac's own — no foreign writer, nothing recent.
        let old = try snapshot(
            "projects", time: "2026-09-30T11:45:00Z", paths: [here], tags: [ResticService.planTag(planID)]
        )
        let model = makeModel()
        let repository = makeRepository()
        loadModel(model, repository: repository, listing: [old])
        let draft = try #require(model.adoptDraft(repositoryID: repository.id, planID: planID))

        let briefing = try #require(model.adoptBriefing(for: draft, now: date("2026-10-03T12:00:00Z")))
        #expect(briefing.warnings.isEmpty)
        #expect(!briefing.needsConfirmation)
        #expect(briefing.historyLine == "This backup becomes this plan's history.")
    }

    @Test("a fresh backup this Mac itself made still asks once")
    func recentLocalGroupStillConfirms() throws {
        let planID = UUID()
        let here = existingFolder()
        let fresh = try snapshot(
            "just-now", time: "2026-10-03T11:00:00Z", paths: [here], tags: [ResticService.planTag(planID)]
        )
        let model = makeModel()
        let repository = makeRepository()
        loadModel(model, repository: repository, listing: [fresh])
        let draft = try #require(model.adoptDraft(repositoryID: repository.id, planID: planID))

        let briefing = try #require(model.adoptBriefing(for: draft, now: date("2026-10-03T12:00:00Z")))
        // No warning line — the recent warning is host-aware, so this Mac's
        // own fresh backup is not called another Mac's work — but the dialog
        // still asks, because freshness alone is worth one deliberate look.
        #expect(briefing.warnings.isEmpty)
        #expect(briefing.needsConfirmation)
    }

    @Test("an older foreign backup is named precisely, never as the newest")
    func olderForeignBackupNamedPrecisely() throws {
        let planID = UUID()
        let tag = ResticService.planTag(planID)
        let local = try snapshot("newest", time: "2026-10-01T11:45:00Z", paths: [existingFolder()], tags: [tag])
        let foreign = try snapshot(
            "older", time: "2026-09-28T10:00:00Z", paths: ["/Data/Old"], host: "laptop", tags: [tag]
        )
        let model = makeModel()
        let repository = makeRepository()
        loadModel(model, repository: repository, listing: [local, foreign])
        let draft = try #require(model.adoptDraft(repositoryID: repository.id, planID: planID))

        let briefing = try #require(model.adoptBriefing(for: draft, now: date("2026-10-03T12:00:00Z")))
        #expect(briefing.warnings.first
            == "The newest backup from another Mac was made on “laptop” on \(Format.timestamp(foreign.time)).")
        // Two Macs made the history; the header counts them.
        #expect(briefing.madeLine.hasPrefix("Made \(Format.historySpan(oldest: foreign.time, newest: local.time)) from 2 Macs."))
        // A foreign writer is the dialog's rule on its own — no recency needed.
        #expect(briefing.needsConfirmation)
    }

    @Test("a backup carrying another plan's tag too says where it stays")
    func dualTaggedBackupNote() throws {
        // The snapshot's one home is its lexicographically first plan tag, so
        // the fixture orders them: this group's UUID sorts first and the
        // dual-tagged backup sits in it.
        let planID = try #require(UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"))
        let other = ResticService.planTag(
            try #require(UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"))
        )
        let snapshots = try [
            snapshot("a", time: "2026-09-28T10:00:00Z", paths: [existingFolder()],
                     tags: [ResticService.planTag(planID), other]),
            snapshot("b", time: "2026-09-27T10:00:00Z", paths: [existingFolder()],
                     tags: [ResticService.planTag(planID)]),
        ]
        let model = makeModel()
        let repository = makeRepository()
        loadModel(model, repository: repository, listing: snapshots)
        let draft = try #require(model.adoptDraft(repositoryID: repository.id, planID: planID))

        let briefing = try #require(model.adoptBriefing(for: draft, now: date("2026-10-03T12:00:00Z")))
        #expect(briefing.warnings.last == "1 backup also carries another plan's tag and stays with that plan.")
    }

    // MARK: - The write

    @Test("adopt appends one plan with the group's UUID, moves the records and writes no run record")
    func adoptAppendsAndReshelves() throws {
        let planID = UUID()
        let tag = ResticService.planTag(planID)
        let listing = try [
            snapshot("g2", time: "2026-10-02T02:00:00Z", paths: ["/Data/Projects"], tags: [tag]),
            snapshot("g1", time: "2026-09-28T02:00:00Z", paths: ["/Data/Old"], tags: [tag]),
        ]
        let model = makeModel()
        let repository = makeRepository()
        loadModel(model, repository: repository, listing: listing)
        var draft = try #require(model.adoptDraft(repositoryID: repository.id, planID: planID))
        draft.sources = [existingFolder()]

        model.adopt(draft: draft)

        // One plan, appended, carrying the group's UUID.
        #expect(model.configuration.plans.map(\.id) == [planID])
        #expect(model.configuration.plans[0].lastRunAt == nil && model.configuration.plans[0].lastSuccessAt == nil)
        // No run record, no activity — adopting is not a run.
        #expect(model.configuration.runs.isEmpty)
        #expect(model.activity.isEmpty)
        // Reshelve is tag-driven: the records moved under the new plan, the
        // group is gone.
        let shelves = model.shelves(for: repository.id)
        #expect(shelves.byPlan[planID]?.map(\.id) == ["g2", "g1"])
        #expect(shelves.others.isEmpty)
        // The banner says what happened, in the count's own number.
        #expect(model.banners.first?.title == "Adopted “Projects”")
        #expect(model.banners.first?.message == "Its 2 existing backups are now its history.")
        #expect(model.banners.first?.isError == false)
    }

    @Test("the banner's singular variant")
    func bannerSingular() throws {
        let planID = UUID()
        let listing = try [snapshot("only", time: "2026-09-28T02:00:00Z", tags: [ResticService.planTag(planID)])]
        let model = makeModel()
        let repository = makeRepository()
        loadModel(model, repository: repository, listing: listing)
        var draft = try #require(model.adoptDraft(repositoryID: repository.id, planID: planID))
        draft.sources = [existingFolder()]

        model.adopt(draft: draft)

        #expect(model.banners.first?.message == "Its 1 existing backup is now its history.")
    }

    @Test("a group that left while the sheet was open adopts with honest words, not a count of zero")
    func vanishedGroupSaysSo() throws {
        let planID = UUID()
        let listing = try [snapshot("g1", time: "2026-09-28T02:00:00Z", tags: [ResticService.planTag(planID)])]
        let model = makeModel()
        let repository = makeRepository()
        loadModel(model, repository: repository, listing: listing)
        var draft = try #require(model.adoptDraft(repositoryID: repository.id, planID: planID))
        draft.sources = [existingFolder()]

        // A listing refresh drops the group while the sheet is open: the
        // briefing is gone (the sheet's words already left with it), and
        // the banner must not count a history of zero backups.
        model.snapshots[repository.id] = []
        #expect(model.adoptBriefing(for: draft) == nil)

        model.adopt(draft: draft)

        #expect(model.banners.first?.message == "Its backups are no longer in the repository.")
    }

    // MARK: - The words around deleting and moving

    @Test("deleting a plan says where its snapshots land, and that they can come back")
    func deleteCopyNamesTheLanding() throws {
        let model = makeModel()
        let repository = makeRepository()
        var plan = BackupPlan()
        plan.name = "Docs"
        plan.repositoryID = repository.id
        model.configuration.repositories = [repository]
        model.configuration.plans = [plan]

        // Nothing backed up: today's sentence.
        #expect(model.confirmationCopy(for: .deletePlan(plan.id))?.message
            == "The plan and its schedule are removed. Snapshots already written to the repository are not deleted.")

        // Two backups under it: the landing is named, with the way back. Docs
        // is the repository's only plan, so the shelf the snapshots move to
        // reads "Backups" once it is gone.
        let listing = try [
            snapshot("d1", time: "2026-10-02T02:00:00Z", tags: [ResticService.planTag(plan.id)]),
            snapshot("d2", time: "2026-09-28T02:00:00Z", tags: [ResticService.planTag(plan.id)]),
        ]
        model.snapshots[repository.id] = listing
        #expect(model.confirmationCopy(for: .deletePlan(plan.id))?.message
            == "The plan and its schedule are removed. Its 2 snapshots stay in “Home Disk”,"
                + " under Backups, and can be adopted back.")

        // Another plan survives the deletion: the shelf keeps its "Other"
        // title, and the dialog says that one.
        var sibling = BackupPlan()
        sibling.name = "Photos"
        sibling.repositoryID = repository.id
        model.configuration.plans = [plan, sibling]
        #expect(model.confirmationCopy(for: .deletePlan(plan.id))?.message
            == "The plan and its schedule are removed. Its 2 snapshots stay in “Home Disk”,"
                + " under Other backups, and can be adopted back.")
        model.configuration.plans = [plan]

        // The running variant keeps its own first sentence.
        model.activity[plan.id] = PlanActivity()
        #expect(model.confirmationCopy(for: .deletePlan(plan.id))?.message
            == "The running backup will be stopped and recorded as cancelled. Its 2 snapshots stay in “Home Disk”,"
                + " under Backups, and can be adopted back.")

        // One backup agrees in number.
        model.activity[plan.id] = nil
        model.snapshots[repository.id] = [listing[0]]
        #expect(model.confirmationCopy(for: .deletePlan(plan.id))?.message
            == "The plan and its schedule are removed. Its 1 snapshot stays in “Home Disk”,"
                + " under Backups, and can be adopted back.")
    }

    @Test("moving a plan says what stays behind, and only when something does")
    func moveConsequenceCountsWhatStays() throws {
        let model = makeModel()
        let home = makeRepository()
        let offsite = makeRepository("Offsite")
        var plan = BackupPlan()
        plan.name = "Music"
        plan.repositoryID = home.id
        model.configuration.repositories = [home, offsite]
        model.configuration.plans = [plan]

        // Nothing stays behind: the line stays silent.
        var moved = plan
        moved.repositoryID = offsite.id
        #expect(model.moveConsequence(for: moved) == nil)
        // The draft keeping its saved repository says nothing either.
        #expect(model.moveConsequence(for: plan) == nil)
        // A plan that is not saved yet — a new plan's draft — cannot move.
        var fresh = BackupPlan()
        fresh.repositoryID = offsite.id
        #expect(model.moveConsequence(for: fresh) == nil)

        let listing = try [
            snapshot("m1", time: "2026-10-02T02:00:00Z", tags: [ResticService.planTag(plan.id)]),
            snapshot("m2", time: "2026-09-28T02:00:00Z", tags: [ResticService.planTag(plan.id)]),
        ]
        model.snapshots[home.id] = listing
        // Music is Home Disk's only plan, so the shelf its backups stay on
        // reads "Backups" once it has left.
        #expect(model.moveConsequence(for: moved)
            == "Moving this plan leaves its 2 backups in “Home Disk” under Backups"
                + " — they are never thinned; retention runs against the plan's current repository only.")

        // A plan that stays behind keeps the shelf's "Other" title.
        var sibling = BackupPlan()
        sibling.name = "Documents"
        sibling.repositoryID = home.id
        model.configuration.plans = [plan, sibling]
        #expect(model.moveConsequence(for: moved)
            == "Moving this plan leaves its 2 backups in “Home Disk” under Other backups"
                + " — they are never thinned; retention runs against the plan's current repository only.")
    }
}

/// The adopt header's date span, pinned on a fixed calendar so the pins read
/// as words, not as this machine's locale.
@Suite("Adopt history span")
struct AdoptHistorySpanTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // A calendar with no locale spells its own month symbols as
        // placeholders ("M09"); the pins read as words.
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    @Test("a shared year is said once, one day says itself, other years say both")
    func spanShapes() {
        #expect(Format.historySpan(
            oldest: date("2026-09-28T10:00:00Z"), newest: date("2026-10-02T11:45:00Z"), calendar: calendar
        ) == "Sep 28 – Oct 2, 2026")
        #expect(Format.historySpan(
            oldest: date("2026-10-02T10:00:00Z"), newest: date("2026-10-02T11:45:00Z"), calendar: calendar
        ) == "Oct 2, 2026")
        #expect(Format.historySpan(
            oldest: date("2025-12-30T10:00:00Z"), newest: date("2026-01-02T11:45:00Z"), calendar: calendar
        ) == "Dec 30, 2025 – Jan 2, 2026")
    }
}

/// The adopt sheet's dry-run line: what the rules would leave, never how
/// many they would remove — nothing follows from the sheet.
@Suite("Adoption preview line")
struct AdoptionPreviewLineTests {
    private func snapshot(_ id: String) -> Snapshot {
        try! ResticMessageDecoder.jsonDecoder.decode(
            Snapshot.self,
            from: Data(#"{"id":"\#(id)","time":"2026-10-02T02:00:00Z","paths":["/Data"]}"#.utf8)
        )
    }

    @Test("a thinning policy says what the history becomes; a keeping one says it all stays")
    func lineShapes() {
        #expect(RetentionPreview(kept: [snapshot("b")], removed: [snapshot("a")]).adoptionLine
            == "With this policy, 2 backups would become 1.")
        #expect(RetentionPreview(kept: [snapshot("c"), snapshot("b")], removed: [snapshot("a")]).adoptionLine
            == "With this policy, 3 backups would become 2.")
        #expect(RetentionPreview(kept: [snapshot("b"), snapshot("a")], removed: []).adoptionLine
            == "All 2 backups would stay.")
        #expect(RetentionPreview(kept: [snapshot("a")], removed: []).adoptionLine
            == "All 1 backup would stay.")
        // Nothing to judge: the honest empty, not a claim of survival.
        #expect(RetentionPreview(kept: [], removed: []).adoptionLine
            == "This plan has no snapshots in the repository yet.")
    }
}
