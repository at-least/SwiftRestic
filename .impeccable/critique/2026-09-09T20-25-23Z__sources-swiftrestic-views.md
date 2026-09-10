---
target: the app UI (Sources/SwiftRestic/Views)
total_score: 36
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 3
target_identity: "file:/Users/newlix/github/at-least/SwiftRestic/Sources/SwiftRestic/Views"
timestamp: 2026-09-09T20-25-23Z
slug: sources-swiftrestic-views
---
Method: dual-agent (A: agent_12f4627b · B: agent_96c3a27f)

# SwiftRestic UI Critique — Sources/SwiftRestic/Views

*Assessment A reviewed all 17 view files plus the App/Models/Services/Core sources, unanchored. Assessment B independently built the app, captured 20 real screenshots (light + dark, seeded + first-run) via the app's own debug-capture harness, and ran the deterministic detector. B's rendered evidence corrected one code-level score and produced the top finding.*

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 4 | Freshness stamps, stale-listing strips, live rate/ETA progress — but Find's potentially hours-long walk shows only an indeterminate spinner (FindFilesView.swift:114) |
| 2 | Match System / Real World | 4 | restic vocabulary taught in place; exit code 12 maps to a fix (ResticError.swift:29–38); compression % denominator is tooltip-only |
| 3 | User Control and Freedom | 3 | Cancel for backup/restore/maintenance/console/find — but cancelling a Find wipes all its results (FindFilesView.swift:278–286) |
| 4 | Consistency and Standards | 4 | One Card/StatTile/Banner grammar; pausing one state lives under three names on three surfaces (PlanDetailView.swift:39, RootView.swift:242, PlanEditorSheet.swift:147) |
| 5 | Error Prevention | 4 | All-zero retention guard, dry-run advice, quit confirmation — but the expected "no repository at that location yet" wears danger styling (RepositoryEditorSheet.swift:440) |
| 6 | Recognition Rather Than Recall | 3 | Stable per-plan color identity across surfaces; snapshot filter matches only ID/formatted date, not paths/host/tags (PlanDetailView.swift:348–356) |
| 7 | Flexibility and Efficiency | 3 | Real ⌘-shortcuts, shell-like console recall; Compare has no keyboard path — Return is hard-wired to Browse (PlanDetailView.swift:488–494) |
| 8 | Aesthetic and Minimalist Design | 3 | Token discipline held in 20 of 21 captured views — but the first-run sidebar renders as a blank strip, contradicting the authored empty state (RootView.swift:160–190) |
| 9 | Error Recovery | 4 | Banner queue with text selection, Retry in the failure row; a check that found errors surfaces only in Activity, not on the repository pane |
| 10 | Help and Documentation | 4 | Concepts glossary, per-field captions, hook variable reference; no inline route from a retention "forget" mention to its Concepts definition |
| **Total** | | **36/40** | **Good — solid foundation, address the weak areas** |

Movement from 35: every priority issue from the previous run was addressed and several are now strengths (the true first-backup promise at Create, exit-code-12 mapping with a fix path, resting chevrons on clickable tiles, two-up overview cards). The remaining headroom is behavioral plus one genuine rendering bug that source-only review could not see.

## Design Specificity Verdict

**Authored for restic and only restic.** A glossary that teaches `forget`/`prune`/`blobs` in restic's own words (ConceptsView.swift:32–51), a retention picker that simulates the forget algorithm and asks "how far back do you want to reach?" (RetentionProjection.swift:12), a check dialog that sizes "slow" against the repository's actual bytes (RepositoryDetailView.swift:233–239), and a Create-button warning that is true because the scheduler provably ticks at 60s (PlanEditorSheet.swift:60–64; AppModel+Scheduling.swift:11). An unrelated backup product could not ship this surface unchanged. Gap: the plan editor never shows the restic command the plan compiles to — the live "restic will use" preview exists for repositories only (RepositoryEditorSheet.swift:308–315).

**Deterministic scan:** `impeccable detect` on the Views directory exited 0 with zero findings (`[]`). Low weight: the detector's rules target web-markup anti-patterns, so a clean pass on SwiftUI is a null result, not assurance. No false positives. It caught nothing A missed — and it structurally could not catch the run's top finding.

**Visual overlays:** none — native macOS app, no browser-renderable surface; live-server/injection skipped for that concrete reason. Real-pixel evidence instead: 20 debug-capture screenshots across light/dark and seeded/first-run states, viewed directly. 20 of 21 rendered views were clean; the one defect is Priority Issue 1.

## Overall Impression

This is a mature, disciplined interface whose trust machinery — provenance captions, honest "—" placeholders, stale-listing strips — is now close to faultless, and the previous critique's fixes landed without regressing anything. What remains is exactly what source review can't fix alone: the first-run screen ships a blank sidebar (a real bug), and restore — the product's emotional payoff — is still capped at one file per round trip. Biggest opportunity: make restore deserve the story the Welcome screen tells.

## What's Working

1. **Truth-in-state discipline, applied uniformly.** "Updated 7:27 AM" captions, "—" with a visible reason instead of a lying zero, the stale-listing strip, and now a Create-button promise that is provably true. The single most trust-building pattern in the codebase.
2. **Every "no rows" moment has its own words and its own way back.** SnapshotTable distinguishes not-loaded vs loaded-empty vs repository-has-other-snapshots vs filter-empty (with Clear Filter) vs failure (with Retry) — PlanDetailView.swift:358–404.
3. **The keyboard story is authored, not incidental.** The browser speaks Finder's grammar (Return enters, ⌘↑/⌫ ascend), the console recalls history like a shell while preserving the interrupted draft, and the quit dialog gives Return to Cancel.

## Priority Issues

**1. [P1] The first-run sidebar renders blank.** With an empty configuration the entire left column is a grey strip: no Overview row, no "No plans yet"/"No repositories yet" captions the code explicitly authors (RootView.swift:160–190), no Tools section, no + Add button. Verified in light and dark by two independent capture methods. A new user's very first screen shows half the window empty. Fix: find why the sidebar's sections don't render under an empty config (likely a conditional swallowing the unconditional Overview section) and render the designed empty state. Command: /impeccable harden.

**2. [P1] Restore is single-select only — no batch restore anywhere.** Browser selection is one `SnapshotNode.ID?` (SnapshotBrowserView.swift:22) and Find selection is one path string (FindFilesView.swift:15); restoring 40 files from a search is 40 destination-panel round trips. Restore is the reason people buy backup software. Fix: `Set` selection in both surfaces, plural restore via the existing per-node call, single-item wording when one row is selected. Command: /impeccable shape.

**3. [P1] Expected states wear alarm styling in the new-repository flow.** Test Connection on a brand-new location correctly finds no repository, then renders "No repository at that location yet. Saving will create one." as a red `xmark.octagon.fill` in Theme.danger (RepositoryEditorSheet.swift:440, 236) — the same octagon that means "your password is wrong" elsewhere (ResticError.swift:35). Setup is where adoption is decided, and this trains users to ignore the error signal. Fix: a neutral/info status case for expected outcomes, or probe with `initializeIfMissing` for new repositories so the expected path is success. Command: /impeccable polish.

**4. [P2] Failure rendering is quadruplicated and re-posted every run.** One dead repository renders the same failure four times on one pane — banner, tile tooltip, caveat line, failure row (RepositoryDetailView.swift:119–121, 143–150, 185, 203–217; PlanDetailView.swift:530–560) — and each scheduled run re-posts a fresh banner (AppModel+Banners.swift:13–21 has a cap but no same-title dedupe). The app's worst moment becomes a wall of repeated red. Fix: when the listing failed, render the failureRow only; make `post(_:)` replace a banner with the same title. Command: /impeccable quieter.

**5. [P2] Find gives no progress over a potentially hours-long walk.** The app's own caption warns the search "takes longer the more history a repository holds" (FindFilesView.swift:97–100), yet the only status is an indeterminate spinner (114) — indistinguishable from hung. Fix: stream a snapshots-walked count ("312 of ~1,400…") from the service's per-snapshot loop into the results header. Command: /impeccable polish.

## Persona Red Flags

**Alex (impatient power user):** Compare has no keyboard path — Return opens Browse, full stop (PlanDetailView.swift:488–494). No batch pause: laptop-offline means N context-menu trips (RootView.swift:242–244); only *running* is batched (⇧⌘B). Snapshot quick-filter can't match paths/host/tags — weaker than restic's own `--path`. Pasting 40 paths with 3 duplicates silently adds 37 with no "skipped 3" feedback (Components.swift:467).

**Sam (accessibility-dependent):** Hook reordering is drag-only `.onMove` (HookEditor.swift:60–62) with no Move Up/Down commands, while the caption says "drag to reorder" (79–81) — a mouse-only affordance named in copy. PathListEditor's list isn't labeled by its heading (Components.swift:404–416), so VoiceOver announces an unlabeled list with ambiguous "Remove" buttons. Modal `runModal` open panels block the whole app including the menu bar's cancel line during a restore (Components.swift:492–525). Strong elsewhere: state never color-only, labeled mini-toggles, banners announced once at root.

**Riley (deliberate stress tester):** The removal dialog discloses only a cancelled *restore*; cancelled backups/maintenance/console are undisclosed — a gap the authors themselves documented as open (AppModel+Repositories.swift:66–70). A hand-edited empty plan name renders "Untitled Plan" everywhere except the PlanDetail navigation title, which renders blank (PlanDetailView.swift:22). Renamed plans leave old `planName`s in Activity history with no note that the name changed (AppModel+Backup.swift:43).

## Minor Observations

- Hook "Run" event picker offers 5 overlapping answers to one question (HookEditor.swift:93–96) — a segmented Success/Warnings/Failure/Always choice would halve it and remove the overlap by construction. [P2]
- Paused tint disagrees: sidebar neutral (RootView.swift:407–409) vs "Next backup" tile warning-orange (PlanDetailView.swift:158); a deliberate pause is a choice, not degradation.
- Schedule time entry is a 24-item popup plus a separate minute field (PlanEditorSheet.swift:235–254) where a native `DatePicker(.hourAndMinute)` would read as one control.
- SnapshotDiffView "Show" filter reaches 5 segments with metadata on (SnapshotDiffView.swift:192–201).
- Welcome feature row mixes parts of speech: "Encrypted" / "See what changed" / "restic console" (RootView.swift:475–477).
- "Due now" is plain text in the repository pane but icon+label in the overview (RepositoryDetailView.swift:333 vs OverviewView.swift:473).
- Clear History permanently destroys all run history in one confirmed click — no export first (ActivityView.swift:140–145).
- Editor footers show only the *first* missing requirement (EditorRequirements.swift:13–22) — up to a three-round blind fix loop.
- Overwrite-warning caption duplicated verbatim in browser and Find (SnapshotBrowserView.swift:127; FindFilesView.swift:181) — one shared constant.
- Console placeholder idioms differ: "Output appears here." vs "Running…" (ResticConsoleView.swift:153; ConsoleModel.swift:158).

## Questions to Consider

1. If run history is the app's evidence of trust, why is its only management action "permanently remove all of it" — where is export before the destructive confirm?
2. The editor projects retention against a *simulated* cadence, while the plan page holds the *real* snapshot list — why doesn't the plan page say "your next retention pass would drop 3 of your actual 41"?
3. The menu bar's first job is the failure line (MenuBarContentView.swift:15–17) — should it be a button that opens Activity pre-filtered to that run, the way the overview's problem tile already routes?
