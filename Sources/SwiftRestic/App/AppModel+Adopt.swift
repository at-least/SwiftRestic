import Foundation

/// Derived once here, so the offering page, the sheet and the tests
/// that pin them cannot disagree.
struct AdoptBriefing: Equatable {
    var historyLine: String
    var madeLine: String
    var repositoryLine: String
    /// In the order the sheet shows them.
    var warnings: [String]

    static let footer = "Don’t continue backups another Mac still makes — the two Macs would share one history."
}

extension AppModel {
    func adoptDraft(repositoryID: UUID, planID: UUID) async -> BackupPlan? {
        guard var draft = continuingDraft(repositoryID: repositoryID, planID: planID) else { return nil }
        // Daily — a new plan's default — only when the prefilled folder is
        // here to back up. Otherwise it is likely another Mac's, and a plan
        // that cannot run here must not start on a schedule. Off the main
        // actor, as every presence read: a stalled share holds it.
        let path = draft.path
        let isHere = await Task.detached { Self.sourceExists(path) }.value
        draft.schedule.frequency = isHere ? .daily : .manual
        return draft
    }

    /// The plan an orphan group's backups continue under: the group's UUID,
    /// so its tag, and its newest backup's folder, excludes and tags, on a
    /// new plan's schedule.
    private func continuingDraft(repositoryID: UUID, planID: UUID) -> BackupPlan? {
        shelves(for: repositoryID).orphanPlanGroup(planID).flatMap { continuingDraft(repositoryID: repositoryID, group: $0) }
    }

    /// `group`, one of the location's shelves' groups, already in hand.
    func continuingDraft(repositoryID: UUID, group: OtherBackupsGroup) -> BackupPlan? {
        let shelves = self.shelves(for: repositoryID)
        guard case let .plan(planID, snapshots) = group,
              repository(id: repositoryID) != nil,
              plan(id: planID) == nil,
              let path = shelves.adoptablePath(of: group, localHost: localHostname),
              let prefill = BackupShelves.prefillSnapshot(among: snapshots, localHost: localHostname)
        else { return nil }
        var draft = BackupPlan()
        draft.id = planID
        draft.repositoryID = repositoryID
        draft.path = path
        // restic records each exclude as it was passed, tilde expanded: a
        // rule the app applies goes back to the app's own spelling, so it is
        // recognised below.
        let spelled = Dictionary(
            BackupPlan.appliedExcludes.filter { $0.hasPrefix("~") }
                .map { (ResticService.expandTilde($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let recorded = BackupPlan.withoutDuplicates(prefill.excludes.map { spelled[$0] ?? $0 })
        // A run records the applied rules among the excludes (not the
        // markers): what they do not pass is the user's own list.
        draft.excludePatterns = BackupPlan.withoutAppliedRules(recorded)
        draft.tags = prefill.userTags
        return draft
    }

    /// Derived as it stands, so a backup landing or the group leaving while
    /// the sheet is open keeps the words true; nil once the group is gone.
    /// `sourceExists` is the sheet's own read of the draft's folder, made
    /// off the main actor: the sheet derives this on every render.
    func adoptBriefing(for draft: BackupPlan, sourceExists: Bool, now: Date = .now) -> AdoptBriefing? {
        guard let repositoryID = draft.repositoryID,
              let repository = repository(id: repositoryID),
              let group = shelves(for: repositoryID).orphanPlanGroup(draft.id),
              let prefill = BackupShelves.prefillSnapshot(among: group.snapshots, localHost: localHostname)
        else { return nil }
        // Newest first, and never empty: a group exists only around backups.
        let snapshots = group.snapshots
        let newest = snapshots[0]

        // The page's "Made on" row reads the same list, so the two cannot
        // count the Macs differently.
        let hosts = Snapshot.distinctHosts(of: snapshots)
        let madeFrom = hosts.count == 1 ? hosts[0] : "\(hosts.count) Macs"

        // `localHostname` is the hostname restic records for this Mac.
        let hasForeignHost = snapshots.contains { $0.hostname != localHostname }
        let isRecent = now.timeIntervalSince(newest.time) < 48 * 3600

        var warnings: [String] = []
        if let foreign = snapshots.first(where: { $0.hostname != localHostname }) {
            let lead = foreign == newest ? "The newest backup" : "The newest backup from another Mac"
            warnings.append("\(lead) was made on “\(foreign.hostname ?? "Unknown Mac")”, \(Format.timestamp(foreign.time)).")
        }
        if prefill.hostname != localHostname {
            warnings.append("The folder comes from another Mac and may not exist here.")
        } else if !sourceExists {
            warnings.append(Self.missingSourcesWarning)
        }
        // Both conditions: a stale foreign host is not another Mac still
        // writing, and a fresh backup this Mac made is this Mac's own.
        if hasForeignHost && isRecent {
            warnings.append("These backups are recent — a plan on another Mac may still be writing them.")
        }
        let dualTagged = snapshots.filter { $0.planTags.count > 1 }.count
        if dualTagged == 1 {
            warnings.append("1 backup also belongs to another plan and stays with it.")
        } else if dualTagged > 1 {
            warnings.append("\(Format.plural(dualTagged, "backup")) also belong to another plan and stay with it.")
        }

        let historyLine = snapshots.count == 1
            ? "This backup becomes this plan’s history."
            : "These \(Format.plural(snapshots.count, "backup")) become this plan’s history."
        let madeLine = "Made \(Format.historySpan(oldest: snapshots[snapshots.count - 1].time, newest: newest.time))"
            + " from \(madeFrom). Nothing in “\(label(of: repository))” changes."

        return AdoptBriefing(
            historyLine: historyLine,
            madeLine: madeLine,
            repositoryLine: label(of: repository),
            warnings: warnings
        )
    }

    /// Adopts the group the draft was prefilled from: one plan whose id is
    /// the group's UUID, and nothing else — no repository write, no restic
    /// call, no index change, no run record. Reshelve is tag-driven, so the
    /// records move under the new plan on their own.
    func adopt(draft: BackupPlan) {
        // `upsert` is keyed by id alone: it would replace that plan silently.
        precondition(plan(id: draft.id) == nil, "adopting a UUID that already names a plan")
        guard let repositoryID = draft.repositoryID else {
            preconditionFailure("an adopt draft always names its repository")
        }
        let count = shelves(for: repositoryID).orphanPlanGroup(draft.id)?.snapshots.count ?? 0
        upsert(plan: draft)
        // A group exists only around backups, so count zero means the group
        // left while the sheet was open — the banner says that, not a count.
        post(Banner(
            title: "Continuing “\(label(of: draft))”",
            message: count == 0
                ? "Its backups are no longer in this location."
                : count == 1
                    ? "Its 1 existing backup is now its history."
                    : "Its \(Format.plural(count, "existing backup")) are now its history.",
            level: .notice
        ))
    }

    static let missingSourcesWarning = "This folder isn’t on this Mac."

    /// A stat, which a stalled share can hold for seconds: never on the
    /// main actor.
    nonisolated static func sourceExists(_ path: String) -> Bool {
        // Not ResticService.expandTilde: it leaves a path without a tilde
        // as typed, and a file spelled with a trailing slash then reads as
        // missing. NSString tidies every path.
        FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath)
    }
}
