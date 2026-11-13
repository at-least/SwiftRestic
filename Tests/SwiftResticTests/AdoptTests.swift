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
        namedRepository(name)
    }

    private func snapshot(
        _ id: String,
        time: String,
        paths: [String] = ["/Data/Docs"],
        host: String = "mac",
        tags: [String] = [],
        excludes: [String]? = nil
    ) throws -> Snapshot {
        try snapshotFixture(
            id: id, time: time, paths: paths, includeShortID: true, hostname: host, tags: tags, excludes: excludes
        )
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

    private func loadModel(_ model: AppModel, repository: Repository, listing: [Snapshot]) {
        model.configuration.repositories = [repository]
        model.snapshots[repository.id] = listing
    }

    @Test("a history whose backup holds several folders is not offered for adoption — a plan backs up one")
    func severalFoldersAreNotAdoptable() async throws {
        let planID = UUID()
        let tag = ResticService.planTag(planID)
        let both = try snapshot("both", time: "2026-09-28T10:00:00Z", paths: ["/Data/Docs", "/Data/Photos"], tags: [tag])
        let model = makeModel()
        let repository = makeRepository()
        loadModel(model, repository: repository, listing: [both])

        #expect(await model.adoptDraft(repositoryID: repository.id, planID: planID) == nil)
        let shelves = model.shelves(for: repository.id)
        #expect(shelves.adoptableGroups(localHost: model.localHostname).isEmpty)
        let page = try #require(shelves.otherGroupPage(.plan(planID), repositories: [repository], localHost: model.localHostname))
        #expect(!page.isAdoptable)
        #expect(page.explanation == "From a backup of several folders. You can restore from it.")

        // A newer backup of one folder is the history a plan continues.
        let one = try snapshot("one", time: "2026-10-01T10:00:00Z", paths: ["/Data/Docs"], tags: [tag])
        loadModel(model, repository: repository, listing: [one, both])
        #expect(await model.adoptDraft(repositoryID: repository.id, planID: planID)?.path == "/Data/Docs")
        #expect(model.shelves(for: repository.id).adoptableGroups(localHost: model.localHostname).count == 1)
        #expect(model.shelves(for: repository.id).otherGroupPage(
            .plan(planID), repositories: [repository], localHost: model.localHostname
        )?.isAdoptable == true)
    }

    @Test("the draft prefills from the newest backup this Mac made, and adopts one plan either way")
    func prefillPrefersThisMac() async throws {
        let planID = UUID()
        let tag = ResticService.planTag(planID)
        // The newest backup overall is another Mac's; this Mac's is older and
        // backed up different folders with different patterns and tags.
        let foreign = try snapshot(
            "newest", time: "2026-10-02T11:45:00Z", paths: ["/Data/Movies"], host: "other-mac",
            tags: [tag], excludes: ["*.iso"]
        )
        let local = try snapshot(
            "local", time: "2026-09-28T10:00:00Z", paths: ["/Data/Docs"],
            tags: [tag, "travel"], excludes: ["node_modules", ".env"]
        )
        let model = makeModel()
        let repository = makeRepository()
        loadModel(model, repository: repository, listing: [foreign, local])

        let draft = try #require(await model.adoptDraft(repositoryID: repository.id, planID: planID))
        #expect(draft.id == planID)
        #expect(draft.repositoryID == repository.id)
        // A plan is called by its path — this Mac's folder, not the
        // newest backup the group's row is titled after.
        #expect(model.label(of: draft) == "Docs")
        #expect(draft.path == "/Data/Docs")
        #expect(draft.excludePatterns == ["node_modules", ".env"])
        #expect(draft.tags == ["travel"])
        // The app has never run this plan; its stamps say so.
        #expect(draft.lastRunAt == nil && draft.lastSuccessAt == nil)
    }

    @Test("a history made with the developer rules adopts with them left to the plan, the list keeping the user's own rows")
    func developerRulesAdoptAsApplied() async throws {
        let planID = UUID()
        let tag = ResticService.planTag(planID)
        let model = makeModel()
        let repository = makeRepository()
        // restic records each rule as the run passed it, tilde expanded, and
        // not the marker; the plan's own rows come first.
        let developer = ExcludeRule.developer.map(\.pattern)
        for path in ["/Data/Docs", NSHomeDirectory()] {
            let recorded = ["*.iso"] + developer.map { ResticService.expandTilde($0) }
            // Each its own ID: the listing keeps a snapshot it already holds.
            let made = try snapshot("on" + path, time: "2026-10-01T10:00:00Z", paths: [path], tags: [tag], excludes: recorded)
            loadModel(model, repository: repository, listing: [made])
            let draft = try #require(await model.adoptDraft(repositoryID: repository.id, planID: planID))
            // In the app's spelling, so each reads as its rule.
            #expect(draft.path == path)
            #expect(draft.excludePatterns == ["*.iso"], "path \(path)")
        }

        // A few developer rules recorded as the user's own rows: every plan
        // passes them anyway, so they leave the list.
        let partial = ["*.iso", "**/.venv", "**/__pycache__"]
        let made = try snapshot("off", time: "2026-10-01T10:00:00Z", tags: [tag], excludes: partial)
        loadModel(model, repository: repository, listing: [made])
        let draft = try #require(await model.adoptDraft(repositoryID: repository.id, planID: planID))
        #expect(draft.excludePatterns == ["*.iso"])
        #expect(draft.excludesToPass.contains("**/.venv"))
    }

    @Test("a default restic recorded with its tilde expanded reads as applied; other rows stay as recorded")
    func expandedDefaultsAdoptInTheirOwnSpelling() async throws {
        let planID = UUID()
        let tag = ResticService.planTag(planID)
        let model = makeModel()
        let repository = makeRepository()
        let caches = ResticService.expandTilde("~/Library/Caches")
        let made = try snapshot(
            "home", time: "2026-10-01T10:00:00Z", paths: [NSHomeDirectory()], tags: [tag],
            excludes: [".DS_Store", caches, "/Users/someone/elsewhere"]
        )
        loadModel(model, repository: repository, listing: [made])
        let draft = try #require(await model.adoptDraft(repositoryID: repository.id, planID: planID))
        #expect(draft.excludePatterns == ["/Users/someone/elsewhere"])
    }

    @Test("a file is here with a trailing or doubled slash, as the new-plan field holds it until Save")
    func sourceExistsTidiesTheSpelling() throws {
        let folder = existingFolder()
        let file = folder + "/report.pdf"
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        #expect(AppModel.sourceExists(file))
        #expect(AppModel.sourceExists(file + "/"))
        #expect(AppModel.sourceExists(file + "//"))
        #expect(AppModel.sourceExists(folder + "/"))
        #expect(!AppModel.sourceExists(folder + "/gone.pdf/"))
    }

    @Test("the schedule follows the folder: Daily when it is here, Manual otherwise")
    func scheduleFollowsTheFolders() async throws {
        let here = existingFolder()
        let planID = UUID()
        let tag = ResticService.planTag(planID)
        let model = makeModel()
        let repository = makeRepository()

        let present = try snapshot("a", time: "2026-10-02T11:45:00Z", paths: [here], tags: [tag])
        loadModel(model, repository: repository, listing: [present])
        #expect(await model.adoptDraft(repositoryID: repository.id, planID: planID)?.schedule.frequency == .daily)

        let missing = try snapshot("b", time: "2026-10-02T11:45:00Z", paths: ["/Data/Gone"], tags: [tag])
        loadModel(model, repository: repository, listing: [missing])
        #expect(await model.adoptDraft(repositoryID: repository.id, planID: planID)?.schedule.frequency == .manual)
    }

    @Test("an adopted plan removes old backups by a new plan's rules")
    func retentionIsANewPlans() async throws {
        let planID = UUID()
        let snapshot = try snapshot("a", time: "2026-10-02T11:45:00Z", tags: [ResticService.planTag(planID)])
        let model = makeModel()
        let repository = makeRepository()
        loadModel(model, repository: repository, listing: [snapshot])

        let draft = try #require(await model.adoptDraft(repositoryID: repository.id, planID: planID))
        #expect(draft.retention == BackupPlan().retention)
    }

    @Test("a UUID that names a configured plan is its moved history, never adoptable")
    func movedGroupNeverAdopts() async throws {
        let offsite = makeRepository("Offsite")
        var music = BackupPlan()
        music.repositoryID = offsite.id
        let snapshot = try snapshot("m1", time: "2026-10-02T11:45:00Z", tags: [ResticService.planTag(music.id)])
        let model = makeModel()
        let home = makeRepository()
        model.configuration.repositories = [home, offsite]
        model.configuration.plans = [music]
        model.snapshots[home.id] = [snapshot]

        #expect(await model.adoptDraft(repositoryID: home.id, planID: music.id) == nil)
        // The page agrees on which variant it is.
        #expect(model.shelves(for: home.id).otherGroupPage(.plan(music.id), repositories: model.configuration.repositories, localHost: localHost)?.isAdoptable == false)
    }

    @Test("an untagged group has no UUID to adopt")
    func untaggedGroupHasNoUUID() async throws {
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
        #expect(await model.adoptDraft(repositoryID: repository.id, planID: UUID()) == nil)
    }

    @Test("a group from another Mac warns in order")
    func foreignGroupWarnsAndConfirms() async throws {
        let planID = UUID()
        let newest = try snapshot(
            "movies", time: "2026-10-02T11:45:00Z", paths: ["/Data/Movies"], host: "other-mac",
            tags: [ResticService.planTag(planID)]
        )
        let model = makeModel()
        let repository = makeRepository()
        loadModel(model, repository: repository, listing: [newest])
        let draft = try #require(await model.adoptDraft(repositoryID: repository.id, planID: planID))

        let briefing = try #require(model.adoptBriefing(for: draft, sourceExists: AppModel.sourceExists(draft.path), now: date("2026-10-03T12:00:00Z")))
        #expect(briefing.historyLine == "This backup becomes this plan’s history.")
        #expect(briefing.madeLine
            == "Made \(Format.historySpan(oldest: newest.time, newest: newest.time)) from other-mac."
                + " Nothing in “Home Disk” changes.")
        #expect(briefing.repositoryLine == "Home Disk")
        #expect(briefing.warnings == [
            "The newest backup was made on “other-mac”, \(Format.timestamp(newest.time)).",
            "The folder comes from another Mac and may not exist here.",
            "These backups are recent — a plan on another Mac may still be writing them.",
        ])
    }

    @Test("the folder warning says where the folder came from, or that it isn't on this Mac")
    func folderWarningFollowsThePrefill() async throws {
        let planID = UUID()
        let tag = ResticService.planTag(planID)
        let foreign = try snapshot(
            "f", time: "2026-09-20T11:00:00Z", paths: ["/Data/Movies"], host: "other-mac", tags: [tag]
        )
        let model = makeModel()
        let repository = makeRepository()
        loadModel(model, repository: repository, listing: [foreign])
        let draft = try #require(await model.adoptDraft(repositoryID: repository.id, planID: planID))
        #expect(model.adoptBriefing(for: draft, sourceExists: AppModel.sourceExists(draft.path), now: date("2026-10-03T12:00:00Z"))?.warnings == [
            "The newest backup was made on “other-mac”, \(Format.timestamp(foreign.time)).",
            "The folder comes from another Mac and may not exist here.",
        ])

        // This Mac's own backup of a folder that is gone says the existence
        // fact instead.
        let local = try snapshot("l", time: "2026-09-28T10:00:00Z", paths: ["/Data/Gone"], tags: [tag])
        loadModel(model, repository: repository, listing: [local])
        let localDraft = try #require(await model.adoptDraft(repositoryID: repository.id, planID: planID))
        #expect(model.adoptBriefing(for: localDraft, sourceExists: AppModel.sourceExists(localDraft.path), now: date("2026-10-03T12:00:00Z"))?.warnings
            == ["This folder isn’t on this Mac."])
        // The sheet's own read decides, not a stat in the briefing: read as
        // here, the same gone folder warns of nothing.
        #expect(model.adoptBriefing(for: localDraft, sourceExists: true, now: date("2026-10-03T12:00:00Z"))?.warnings == [])
    }

    @Test("a clean old local group warns of nothing, once its folders are here")
    func cleanLocalGroupNeedsNoDialog() async throws {
        let planID = UUID()
        let here = existingFolder()
        // Three days old, this Mac's own — no foreign writer, nothing recent.
        let old = try snapshot(
            "projects", time: "2026-09-30T11:45:00Z", paths: [here], tags: [ResticService.planTag(planID)]
        )
        let model = makeModel()
        let repository = makeRepository()
        loadModel(model, repository: repository, listing: [old])
        let draft = try #require(await model.adoptDraft(repositoryID: repository.id, planID: planID))

        let briefing = try #require(model.adoptBriefing(for: draft, sourceExists: AppModel.sourceExists(draft.path), now: date("2026-10-03T12:00:00Z")))
        #expect(briefing.warnings.isEmpty)
        #expect(briefing.historyLine == "This backup becomes this plan’s history.")
    }

    @Test("an older foreign backup is named precisely, never as the newest")
    func olderForeignBackupNamedPrecisely() async throws {
        let planID = UUID()
        let tag = ResticService.planTag(planID)
        let local = try snapshot("newest", time: "2026-10-01T11:45:00Z", paths: [existingFolder()], tags: [tag])
        let foreign = try snapshot(
            "older", time: "2026-09-28T10:00:00Z", paths: ["/Data/Old"], host: "laptop", tags: [tag]
        )
        let model = makeModel()
        let repository = makeRepository()
        loadModel(model, repository: repository, listing: [local, foreign])
        let draft = try #require(await model.adoptDraft(repositoryID: repository.id, planID: planID))

        let briefing = try #require(model.adoptBriefing(for: draft, sourceExists: AppModel.sourceExists(draft.path), now: date("2026-10-03T12:00:00Z")))
        #expect(briefing.warnings.first
            == "The newest backup from another Mac was made on “laptop”, \(Format.timestamp(foreign.time)).")
        // Two Macs made the history; the header counts them.
        #expect(briefing.madeLine.hasPrefix("Made \(Format.historySpan(oldest: foreign.time, newest: local.time)) from 2 Macs."))
    }

    @Test("a backup that also belongs to another plan says where it stays")
    func dualTaggedBackupNote() async throws {
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
        let draft = try #require(await model.adoptDraft(repositoryID: repository.id, planID: planID))

        let briefing = try #require(model.adoptBriefing(for: draft, sourceExists: AppModel.sourceExists(draft.path), now: date("2026-10-03T12:00:00Z")))
        #expect(briefing.warnings.last == "1 backup also belongs to another plan and stays with it.")
    }

    @Test("adopt appends one plan with the group's UUID, moves the records and writes no run record")
    func adoptAppendsAndReshelves() async throws {
        let planID = UUID()
        let tag = ResticService.planTag(planID)
        let listing = try [
            snapshot("g2", time: "2026-10-02T02:00:00Z", paths: ["/Data/Projects"], tags: [tag]),
            snapshot("g1", time: "2026-09-28T02:00:00Z", paths: ["/Data/Old"], tags: [tag]),
        ]
        let model = makeModel()
        let repository = makeRepository()
        loadModel(model, repository: repository, listing: listing)
        let draft = try #require(await model.adoptDraft(repositoryID: repository.id, planID: planID))

        model.adopt(draft: draft)

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
        #expect(model.banners.first?.title == "Continuing “Projects”")
        #expect(model.banners.first?.message == "Its 2 existing backups are now its history.")
        #expect(model.banners.first?.isError == false)
    }

    @Test("Back Up a Folder… continues the folder's own history: a former plan's, this Mac's, exactly this folder")
    func firstPlanContinuesItsHistory() throws {
        let planID = UUID()
        let tag = ResticService.planTag(planID)
        let listing = try [
            snapshot("h2", time: "2026-10-02T02:00:00Z", paths: ["/Data/Docs"], tags: [tag, "work"]),
            snapshot("h1", time: "2026-09-28T02:00:00Z", paths: ["/Data/Docs"], tags: [tag]),
        ]
        let model = makeModel()
        let repository = makeRepository()
        loadModel(model, repository: repository, listing: listing)

        let created = model.createFirstPlan(source: "/Data/Docs", repositoryID: repository.id)

        #expect(created == planID)
        #expect(model.configuration.plans.map(\.id) == [planID])
        let plan = try #require(model.plan(id: planID))
        #expect(plan.path == "/Data/Docs" && plan.repositoryID == repository.id)
        #expect(plan.tags == ["work"])
        #expect(plan.schedule.frequency == BackupPlan().schedule.frequency)
        #expect(model.shelves(for: repository.id).byPlan[planID]?.map(\.id) == ["h2", "h1"])
        #expect(model.banners.first?.title == "Continuing “Docs”")
    }

    @Test("another Mac's history, another folder's, or one shared with another Mac starts a new plan beside it")
    func firstPlanStartsANewHistory() throws {
        func createdPlan(listing: [Snapshot], source: String = "/Data/Docs") -> (created: UUID, model: AppModel) {
            let model = makeModel()
            let repository = makeRepository()
            loadModel(model, repository: repository, listing: listing)
            return (model.createFirstPlan(source: source, repositoryID: repository.id), model)
        }
        let planID = UUID()
        let tag = ResticService.planTag(planID)

        let otherHost = try [snapshot("o1", time: "2026-10-02T02:00:00Z", host: "studio", tags: [tag])]
        let otherFolder = try [snapshot("f1", time: "2026-10-02T02:00:00Z", paths: ["/Data/Docs/Old"], tags: [tag])]
        let shared = try [
            snapshot("s2", time: "2026-10-02T02:00:00Z", tags: [tag]),
            snapshot("s1", time: "2026-09-28T02:00:00Z", host: "studio", tags: [tag]),
        ]
        // Untagged backups of the folder are no plan's history.
        let untagged = try [snapshot("u1", time: "2026-10-02T02:00:00Z")]
        for listing in [otherHost, otherFolder, shared, untagged] {
            let (created, model) = createdPlan(listing: listing)
            #expect(created != planID)
            #expect(model.plan(id: created)?.path == "/Data/Docs")
            #expect(model.plan(id: created)?.announcesFirstBackup == true)
            #expect(model.configuration.plans.count == 1)
        }
        // The same history, asked for a sibling folder.
        #expect(createdPlan(listing: try [snapshot("p1", time: "2026-10-02T02:00:00Z", tags: [tag])], source: "/Data/Doc").created != planID)
    }

    @Test("the banner's singular variant")
    func bannerSingular() async throws {
        let planID = UUID()
        let listing = try [snapshot("only", time: "2026-09-28T02:00:00Z", tags: [ResticService.planTag(planID)])]
        let model = makeModel()
        let repository = makeRepository()
        loadModel(model, repository: repository, listing: listing)
        var draft = try #require(await model.adoptDraft(repositoryID: repository.id, planID: planID))
        draft.path = existingFolder()

        model.adopt(draft: draft)

        #expect(model.banners.first?.message == "Its 1 existing backup is now its history.")
    }

    @Test("a group that left while the sheet was open adopts with honest words, not a count of zero")
    func vanishedGroupSaysSo() async throws {
        let planID = UUID()
        let listing = try [snapshot("g1", time: "2026-09-28T02:00:00Z", tags: [ResticService.planTag(planID)])]
        let model = makeModel()
        let repository = makeRepository()
        loadModel(model, repository: repository, listing: listing)
        var draft = try #require(await model.adoptDraft(repositoryID: repository.id, planID: planID))
        draft.path = existingFolder()

        // A listing refresh drops the group while the sheet is open: the
        // briefing is gone (the sheet's words already left with it), and
        // the banner must not count a history of zero backups.
        model.snapshots[repository.id] = []
        #expect(model.adoptBriefing(for: draft, sourceExists: AppModel.sourceExists(draft.path)) == nil)

        model.adopt(draft: draft)

        #expect(model.banners.first?.message == "Its backups are no longer in this location.")
    }

    @Test("deleting a plan says where its snapshots land, and that they can come back")
    func deleteCopyNamesTheLanding() throws {
        let model = makeModel()
        let repository = makeRepository()
        var plan = BackupPlan()
        plan.repositoryID = repository.id
        model.configuration.repositories = [repository]
        model.configuration.plans = [plan]

        // Nothing backed up: the plain sentence.
        #expect(model.confirmationCopy(for: .deletePlan(plan.id))?.message
            == "This Mac stops backing up “Untitled Plan”. Backups already written to the location are not deleted.")

        // Two backups under it: the repository they stay in is named, with
        // the way back.
        let listing = try [
            snapshot("d1", time: "2026-10-02T02:00:00Z", tags: [ResticService.planTag(plan.id)]),
            snapshot("d2", time: "2026-09-28T02:00:00Z", tags: [ResticService.planTag(plan.id)]),
        ]
        model.snapshots[repository.id] = listing
        #expect(model.confirmationCopy(for: .deletePlan(plan.id))?.message
            == "This Mac stops backing up “Untitled Plan”. Its 2 backups stay in “Home Disk”, and you can continue them later.")

        // The running variant keeps its own first sentence.
        model.activity[plan.id] = PlanActivity(of: plan)
        #expect(model.confirmationCopy(for: .deletePlan(plan.id))?.message
            == "The running backup will be stopped."
                + " Its 2 backups stay in “Home Disk”, and you can continue them later.")

        // One backup agrees in number.
        model.activity[plan.id] = nil
        model.snapshots[repository.id] = [listing[0]]
        #expect(model.confirmationCopy(for: .deletePlan(plan.id))?.message
            == "This Mac stops backing up “Untitled Plan”. Its 1 backup stays in “Home Disk”, and you can continue it later.")
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
