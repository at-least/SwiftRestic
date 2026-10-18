import Foundation

/// What the adopt sheet says around the draft it edits: the header strip's
/// two lines, the warnings that hold of the group, and whether Adopt asks
/// again. Derived once here, so the offering page, the sheet and the tests
/// that pin them cannot disagree.
struct AdoptBriefing: Equatable {
    /// "These 2 backups become this plan's history."
    var historyLine: String
    /// "Made Sep 28 – Oct 2, 2026 from this Mac. Nothing in “Home Disk” changes."
    var madeLine: String
    /// The locked repository row: "Home Disk — the backups live here".
    var repositoryLine: String
    /// The warnings that hold of the group, in the order the sheet shows them.
    var warnings: [String]
    /// Whether pressing Adopt asks again — any snapshot from another host, or
    /// a newest backup under 48 hours old.
    var needsConfirmation: Bool
    /// The asking-again dialog's words.
    var confirmation: ConfirmationCopy

    /// Always, as the sheet's footer: what adopting does not do, and the one
    /// situation it must not be used in.
    static let footer =
        "Adopting reuses these backups' history — nothing is written to the repository. "
        + "If another Mac still runs this plan, don't adopt it here: both Macs would share one history and one retention policy."
}

extension AppModel {
    // MARK: - Adopt

    /// The draft the adopt sheet edits for one plan-UUID group: the plan
    /// adopting builds, prefilled from the history it adopts. Nil unless the
    /// group is adoptable (`BackupShelves.adoptablePath`).
    func adoptDraft(repositoryID: UUID, planID: UUID) -> BackupPlan? {
        let shelves = self.shelves(for: repositoryID)
        guard repository(id: repositoryID) != nil,
              plan(id: planID) == nil,
              let group = shelves.orphanPlanGroup(planID),
              let path = shelves.adoptablePath(of: group, localHost: localHostname),
              let prefill = BackupShelves.prefillSnapshot(among: group.snapshots, localHost: localHostname)
        else { return nil }
        var draft = BackupPlan()
        draft.id = planID
        draft.repositoryID = repositoryID
        draft.path = path
        draft.excludePatterns = prefill.excludes
        // Plan tags are the group's plumbing; what the user tagged is everything else.
        draft.tags = prefill.tags.filter { !$0.hasPrefix(ResticService.planTagPrefix) }
        // Daily — a new plan's default — only when every prefilled folder is
        // here to back up. Otherwise the folders are likely another Mac's,
        // and a plan that cannot run here must not start on a schedule.
        draft.schedule.frequency = Self.allSourcesExist([draft.path]) ? .daily : .manual
        // The history is the point of adopting: nothing thins it until a
        // policy is chosen with the dry run's answer in view.
        draft.retention.isEnabled = false
        return draft
    }

    /// Everything the adopt sheet shows around the draft. Derived as it
    /// stands, so a backup landing or the group leaving while the sheet is
    /// open keeps the words true; nil once the group is gone.
    func adoptBriefing(for draft: BackupPlan, now: Date = .now) -> AdoptBriefing? {
        guard let repositoryID = draft.repositoryID,
              let repository = repository(id: repositoryID),
              let group = shelves(for: repositoryID).orphanPlanGroup(draft.id),
              let prefill = BackupShelves.prefillSnapshot(among: group.snapshots, localHost: localHostname)
        else { return nil }
        // The group's snapshots, newest first — a group exists only around
        // backups, so both ends are always there.
        let snapshots = group.snapshots
        let newest = snapshots[0]

        // The page's "Made from" row reads the same list, so the two cannot
        // count the Macs differently.
        let hosts = Snapshot.distinctHosts(of: snapshots)
        let madeFrom = hosts.count == 1 ? hosts[0] : "\(hosts.count) Macs"

        // The host every "this Mac / another Mac" decision in the sheet
        // reads: `localHostname`, which restic itself records for this Mac.
        let hasForeignHost = snapshots.contains { $0.hostname != localHostname }
        let isRecent = now.timeIntervalSince(newest.time) < 48 * 3600

        var warnings: [String] = []
        if let foreign = snapshots.first(where: { $0.hostname != localHostname }) {
            let lead = foreign == newest ? "The newest backup" : "The newest backup from another Mac"
            warnings.append("\(lead) was made on “\(foreign.hostname ?? "Unknown host")” on \(Format.timestamp(foreign.time)).")
        }
        // The adopt sheet shows the path, it does not change it: the folder
        // came from another Mac, or — this Mac's own — it is gone.
        if prefill.hostname != localHostname {
            warnings.append("The folder comes from another Mac and may not exist here.")
        } else if !Self.allSourcesExist([draft.path]) {
            warnings.append(Self.missingSourcesWarning)
        }
        // Both conditions: a stale foreign host is not another Mac still
        // writing, and a fresh backup this Mac made is the confirmation's
        // business below, not the warning's.
        if hasForeignHost && isRecent {
            warnings.append("These backups are recent — a plan on another Mac may still be writing them.")
        }
        let dualTagged = snapshots.filter {
            $0.tags.filter { $0.hasPrefix(ResticService.planTagPrefix) }.count > 1
        }.count
        if dualTagged == 1 {
            warnings.append("1 backup also carries another plan's tag and stays with that plan.")
        } else if dualTagged > 1 {
            warnings.append("\(Format.plural(dualTagged, "backup")) also carry another plan's tag and stay with that plan.")
        }

        let historyLine = snapshots.count == 1
            ? "This backup becomes this plan's history."
            : "These \(Format.plural(snapshots.count, "backup")) become this plan's history."
        let madeLine = "Made \(Format.historySpan(oldest: snapshots[snapshots.count - 1].time, newest: newest.time))"
            + " from \(madeFrom). Nothing in “\(repository.name)” changes."

        let name = label(of: draft)
        let becomes = snapshots.count == 1
            ? "This backup becomes the plan's history."
            : "These \(Format.plural(snapshots.count, "backup")) become the plan's history."

        return AdoptBriefing(
            historyLine: historyLine,
            madeLine: madeLine,
            repositoryLine: "\(repository.name) — the backups live here",
            warnings: warnings,
            // Broader than the recent warning: a fresh backup this Mac made
            // gets the confirmation too.
            needsConfirmation: hasForeignHost || isRecent,
            confirmation: ConfirmationCopy(
                title: "Adopt “\(name)”?",
                message: becomes
                    + " Nothing is written to “\(repository.name)”."
                    + " If another Mac still runs this plan, both Macs share one history and one retention policy"
                    + " — adopt only backups no other Mac is still making."
            )
        )
    }

    /// Adopts the group the draft was prefilled from: one plan whose id is
    /// the group's UUID, and nothing else — no repository write, no restic
    /// call, no index change, no run record. Reshelve is tag-driven, so the
    /// records move under the new plan on their own.
    func adopt(draft: BackupPlan) {
        // `upsert` is keyed by id alone, so a draft whose UUID already names
        // a plan would silently *replace* it — fail loudly if the two ever
        // disagree.
        precondition(plan(id: draft.id) == nil, "adopting a UUID that already names a plan")
        guard let repositoryID = draft.repositoryID else {
            preconditionFailure("an adopt draft always names its repository")
        }
        let count = shelves(for: repositoryID).orphanPlanGroup(draft.id)?.snapshots.count ?? 0
        upsert(plan: draft)
        // A group exists only around backups, so count zero means the group
        // left while the sheet was open — the banner says that, not a count.
        post(Banner(
            title: "Adopted “\(label(of: draft))”",
            message: count == 0
                ? "Its backups are no longer in the repository."
                : count == 1
                    ? "Its 1 existing backup is now its history."
                    : "Its \(Format.plural(count, "existing backup")) are now its history.",
            isError: false
        ))
    }

    /// The missing-folder warning, said by the adopt sheet's footer and
    /// beside the plan editor's path.
    static let missingSourcesWarning = "This folder isn't on this Mac."

    /// Whether every source folder (or file) is on this Mac now, tilde
    /// expanded — the fact behind both the schedule's default and the
    /// missing-folders warning.
    static func allSourcesExist(_ sources: [String]) -> Bool {
        sources.allSatisfy {
            FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath)
        }
    }
}
