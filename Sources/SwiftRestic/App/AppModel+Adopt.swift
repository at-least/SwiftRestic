import Foundation

/// What the adopt sheet says around the draft it edits: the header strip's
/// two lines, the warnings that hold of the group, and whether Adopt asks
/// again. Derived here from the shelves' own facts, so the page that offers
/// the verb, the sheet that performs it and the tests that pin them read one
/// derivation and cannot disagree.
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
    /// group is adoptable — a UUID that names a configured plan anywhere in
    /// the configuration is that plan's moved history, which never offers
    /// Adopt, and an untagged group has no UUID to adopt.
    func adoptDraft(repositoryID: UUID, planID: UUID) -> BackupPlan? {
        guard repository(id: repositoryID) != nil,
              plan(id: planID) == nil,
              let group = shelves(for: repositoryID).orphanPlanGroup(planID),
              // The label derivation that names the sidebar row and the page
              // names the draft too, so the sheet's title never argues with
              // the row the user clicked.
              let title = shelves(for: repositoryID).otherLabels(
                  repositories: configuration.repositories,
                  localHost: localHostname
              )[group.id]?.title,
              let prefill = Self.prefillSnapshot(among: group.snapshots, localHost: localHostname)
        else { return nil }
        var draft = BackupPlan()
        draft.id = planID
        draft.name = title
        draft.repositoryID = repositoryID
        draft.sources = prefill.paths
        draft.excludePatterns = prefill.excludes
        // Plan tags are the group's plumbing; what the user tagged is everything else.
        draft.tags = prefill.tags.filter { !$0.hasPrefix(ResticService.planTagPrefix) }
        // Daily — a new plan's own default — only when every prefilled folder
        // is here to back up. Otherwise the folders are likely another Mac's,
        // and a plan that cannot run here must not start on a schedule.
        draft.schedule.frequency = Self.allSourcesExist(draft.sources) ? .daily : .manual
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
              let prefill = Self.prefillSnapshot(among: group.snapshots, localHost: localHostname)
        else { return nil }
        // The group's own order, newest first — a group exists only around
        // backups, so both ends are always there.
        let snapshots = group.snapshots
        let newest = snapshots[0]

        // The page's "Made from" row reads the same list — one derivation of
        // which Macs made the history, so it cannot count them differently.
        let hosts = Snapshot.distinctHosts(of: snapshots)
        let madeFrom = hosts.count == 1 ? hosts[0] : "\(hosts.count) Macs"

        // The host rule every "this Mac / another Mac" decision in the sheet
        // reads: `localHostname`, which restic itself records for this Mac.
        let hasForeignHost = snapshots.contains { $0.hostname != localHostname }
        let isRecent = now.timeIntervalSince(newest.time) < 48 * 3600

        var warnings: [String] = []
        if let foreign = snapshots.first(where: { $0.hostname != localHostname }) {
            // The overall newest when it is the newest at all; precise, never
            // claiming that title for an older one, when this Mac made the
            // newest backup.
            let lead = foreign == newest ? "The newest backup" : "The newest backup from another Mac"
            warnings.append("\(lead) was made on “\(foreign.hostname ?? "Unknown host")” on \(Format.timestamp(foreign.time)).")
        }
        // Both lines speak about the folders the sheet shows: the
        // another-Mac one only while the prefilled set is still untouched —
        // folders the user replaced with their own are neither Mac's
        // prefill — and the missing one about whichever set is in the box.
        if prefill.hostname != localHostname, draft.sources == prefill.paths {
            warnings.append("The folders come from another Mac and may not exist here.")
        } else if !Self.allSourcesExist(draft.sources) {
            warnings.append("Not all of these folders still exist on this Mac.")
        }
        // Host-aware on purpose: yesterday's deletion on this Mac is not
        // another Mac still writing, and this Mac's fresh backup is not the
        // warning's business — the confirmation below catches that one.
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

        let name = draft.name.isEmpty ? "Untitled Plan" : draft.name
        let becomes = snapshots.count == 1
            ? "This backup becomes the plan's history."
            : "These \(Format.plural(snapshots.count, "backup")) become the plan's history."

        return AdoptBriefing(
            historyLine: historyLine,
            madeLine: madeLine,
            repositoryLine: "\(repository.name) — the backups live here",
            warnings: warnings,
            // Broader than the recent warning on purpose: a fresh backup this
            // Mac itself made is still worth one deliberate look.
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
        // The classification that offered Adopt scanned every configured
        // plan; a UUID that names one is a moved plan's group, which never
        // offered the verb. `upsert` is keyed by id alone, so a draft that
        // slipped past classification would silently *replace* that plan —
        // fail loudly if the two ever disagree.
        precondition(plan(id: draft.id) == nil, "adopting a UUID that already names a plan")
        guard let repositoryID = draft.repositoryID else {
            preconditionFailure("an adopt draft always names its repository")
        }
        let count = shelves(for: repositoryID).orphanPlanGroup(draft.id)?.snapshots.count ?? 0
        upsert(plan: draft)
        // A group exists only around backups, so a count of zero is not "no
        // history yet" — the group left while the sheet was open (a refresh
        // dropped it), and the banner says that instead of counting zero.
        post(Banner(
            title: "Adopted “\(draft.name.isEmpty ? "Untitled Plan" : draft.name)”",
            message: count == 0
                ? "Its backups are no longer in the repository."
                : count == 1
                    ? "Its 1 existing backup is now its history."
                    : "Its \(Format.plural(count, "existing backup")) are now its history.",
            isError: false
        ))
    }

    /// The snapshot the draft prefills from: the newest this Mac made, else
    /// the newest of all — the folders most likely to exist here, with the
    /// other-Mac warning carried beside them when they are not this Mac's.
    /// `snapshots` are the group's, newest first.
    static func prefillSnapshot(among snapshots: [Snapshot], localHost: String) -> Snapshot? {
        snapshots.first { $0.hostname == localHost } ?? snapshots.first
    }

    /// Whether every source folder (or file) is on this Mac now, tilde
    /// expanded — the fact behind both the schedule's default and the
    /// missing-folders warning.
    static func allSourcesExist(_ sources: [String]) -> Bool {
        sources.allSatisfy {
            FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath)
        }
    }

    /// What saving an existing plan against a different repository does to
    /// the backups it already made — said while the picker is being moved,
    /// not after. Nil while the draft keeps its saved repository, when
    /// nothing stays behind, and for a plan that is not saved yet (an adopt
    /// draft's repository is locked, so it never moves either).
    func moveConsequence(for draft: BackupPlan) -> String? {
        guard let saved = plan(id: draft.id),
              let oldRepositoryID = saved.repositoryID,
              draft.repositoryID != oldRepositoryID,
              let oldRepository = repository(id: oldRepositoryID)
        else { return nil }
        let count = shelves(for: oldRepositoryID).byPlan[draft.id]?.count ?? 0
        guard count > 0 else { return nil }
        // The shelf's title as it will read once the plan has left — the
        // sidebar's own derivation, so the line never names a section by a
        // title it will not have ("Backups" beside no plan).
        let shelf = SidebarTree.otherBackupsTitle(
            repositoryHasPlans: plans(in: oldRepositoryID).count > 1
        )
        return "Moving this plan leaves its \(Format.plural(count, "backup")) in “\(oldRepository.name)”"
            + " under \(shelf) — they are never thinned; retention runs against the plan's current repository only."
    }
}
