---
target: the app UI (Sources/SwiftRestic/Views)
total_score: 35
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 2
target_identity: "file:/Users/newlix/github/at-least/SwiftRestic/Sources/SwiftRestic/Views"
timestamp: 2026-09-09T03-43-56Z
slug: sources-swiftrestic-views
---
# Design Critique — SwiftRestic app UI (Sources/SwiftRestic/Views)

Method: dual-agent (A: agent_d52147f5-aa1a-43f1-8d05-8ac39ff50c67 · B: agent_dd365ea4-6d8a-483d-a22f-0d2f3c55c185)
Evidence basis: source reading of a native macOS SwiftUI app — the app was not run and no browser inspection exists (no web surface); runtime-dependent findings are marked UNVERIFIED.

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Restores visible only inside the sheet that started them; menu bar icon blind to restores, maintenance, failures |
| 2 | Match System / Real World | 3 | "Keep 24h, 7d…" retention shorthand and "Blobs" tile are restic-speak rescued only by tooltips |
| 3 | User Control and Freedom | 4 | Cancels everywhere, dirty-state Esc guards, console recall with draft restore |
| 4 | Consistency and Standards | 4 | One grammar; minor drift (toolbar vs card-accessory Refresh) |
| 5 | Error Prevention | 4 | Destructive dialogs name what is and is not affected; Save states its missing requirement |
| 6 | Recognition Rather Than Recall | 3 | Failure reasons and protection breakdowns tooltip-only; README-only caveat |
| 7 | Flexibility and Efficiency | 3 | Strong shortcuts; snapshot table lacks sort/search/context menu; Browse/Compare unshortcuted |
| 8 | Aesthetic and Minimalist Design | 3 | Density crests in diff sheet and repository detail |
| 9 | Error Recovery | 4 | Exit codes mapped to distinct copy; stale-listing strip with Retry |
| 10 | Help and Documentation | 4 | Concepts surface, ExpandableCaption pattern, doc links |
| **Total** | | **35/40** | **Good — top of band** |

## Design Specificity Verdict

High specificity in language, states, and consequences (restic-exact copy at every decision point: prune locks, --dry-run suggestion, all-zero retention warning, outcome-projection retention); generic in composition (PlanDetail and RepositoryDetail are near-instances of one tiles-plus-cards template); menu bar icon is the missed opportunity for product character. Authored composition exists only in the snapshot browser's pseudo-root + Finder keyboard grammar.

Deterministic scan: directory invocation scanned 0 files (.swift not in the detector's extension filter; `[]`, exit 0 — not evidence of cleanliness). Forced explicit run over all 17 Swift files: scanned 17/17, zero findings (rule set targets CSS/JSX patterns — weak positive). No false positives. Visual overlays: none available (native app, no web surface).

## Priority Issues

1. [P1] Restores invisible outside the sheet that started them (SnapshotBrowserView.swift:118-125, FindFilesView.swift:154-161; restoreActivity feeds neither icon nor MenuBarStatus; Close enabled mid-restore). Fix: app-level restore indicator, MenuBarStatus line, disable/relabel Close. Command: /impeccable shape
2. [P1] Menu bar icon cannot say "something is wrong" (SwiftResticApp.swift:284-286 — two states keyed on plan activity; SettingsView.swift:36 promises maintenance animation — UNVERIFIED runtime, code-path reading only). Fix: third state from MenuBarStatus.problemLine, include maintenance, align caption. Command: /impeccable polish
3. [P2] Snapshot table does not scale (PlanDetailView.swift:321-378 — no sortOrder, no filter, no context menu). Fix: native sort bindings, filter field, row context menu. Command: /impeccable shape
4. [P2] Diff sheet wall of five equal tiles + five-segment filter (SnapshotDiffView.swift:128-184). Fix: two-tier summary, byte pair as compact +X / −Y block. Command: /impeccable layout
5. [P3] 8-item backend picker as second field of first-run form (RepositoryEditorSheet.swift:134-149). Fix: two-step choice with one-line descriptions. Command: /impeccable onboard

## Cognitive Load

Checklist: 6 of 8 pass. Failures: chunking (5 diff tiles; 6 retention steppers at PlanEditorSheet.swift:222-229); minimal choices (8-kind repository picker; 5 plan-editor tabs; 5-segment diff filter; 5-event hook picker). Working-memory leaks: protection breakdown tooltip-only; plan editor's repository picker shows names only (capacity lives on Overview). Progressive disclosure exemplary. Moderate load overall.

## Emotional Journey

Strong: first run (missing-binary card not dead end; New Backup Plan redirects to repository creation), failure recovery (diagnosis + Open Plan + Back Up Now in one panel), high-stakes dialogs stating consequences precisely. Weak: restore is the least ceremonial high-stakes operation (one sentence in the NSOpenPanel; no conflict count; success is one auto-dismissing banner naming only the destination). Trust crack: Settings caption promises icon behavior the icon state machine does not deliver.

## Persona Red Flags

Alex: Browse/Compare mouse-only (PlanDetailView.swift:354-366); plan deletion only via sidebar context menu (RootView.swift:243) while repository removal is in-pane; fixed 640×580 plan sheet with 160pt exclude list vs resizable repository sheet; Find has no double-click action while browser opens folders on double-click.
Sam: tooltip-locked failure diagnosis (PlanDetailView.swift:120-134, RepositoryDetailView.swift:134-148, OverviewView.swift:118-121); icon state by symbol swap alone with no accessibility label treatment; chart fallback behind icon-only segment. Good: banner announcements, "Due now" icon+words, diff glyphs with spoken explanations.
Riley: 1000-snapshot unsortable/unsearchable table; raw 1000-candidate "Compared with" scroll; remove-repository-during-backup does not cancel the run (AppModel.swift:426-438 vs deletePlan :518-522); Find results can silently predate the snapshot list; diff/browser/search stale-work cancellation otherwise solid.

## Minor Observations

Welcome hero gradient outlier; HookEditor .border(.quaternary); s3=cloud vs gcs=cloud.fill icon near-collision; PathListEditor one icon for two meanings; conditional Stop button shifts row at click time; "Added" means counts and bytes in different tiles; ConceptsView unreachable from inline term help; inconsistent sheet resizability philosophy.

## Questions to Consider

- Why does the always-visible menu bar icon have exactly two states, neither "failing"?
- Should restore earn a conflict preview symmetric with Compare's pre-restore answer?
- What would PlanDetail/RepositoryDetail look like composed for their different jobs?
- Would "how far back do you want to reach?" with the survival projection replace the six retention steppers?
