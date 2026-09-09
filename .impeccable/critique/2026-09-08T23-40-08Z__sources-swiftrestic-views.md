---
target: Sources/SwiftRestic/Views
total_score: 31
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 2
target_identity: "file:/Users/newlix/github/at-least/SwiftRestic/Sources/SwiftRestic/Views"
timestamp: 2026-09-08T23-40-08Z
slug: sources-swiftrestic-views
---
# Design Critique — Sources/SwiftRestic/Views (native macOS, Operate surface)

Method: dual-agent (A: agent_3ec4872b · B: agent_f797273c). Evidence: all 19 view files + app/menu-bar layer; ten live captures (7 panes, diff sheet, hooks sheet, light+dark) of the running app against a throwaway demo repository.

## Design Health Score — 31/40 (Good)

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Snapshot Refresh shows no progress / no last-refreshed timestamp once rows exist |
| 2 | Match System / Real World | 3 | "Blobs" bare tile; expected new-repository state styled as red failure |
| 3 | User Control and Freedom | 3 | Cancel everywhere; Delete Plan / Clear History have confirmation only, no undo |
| 4 | Consistency and Standards | 3 | Fixed vs resizable editor sheets; SheetHeader used by only one sheet; hooks-tab renders as black pill in capture |
| 5 | Error Prevention | 4 | Retention zero-guard, blast-radius copy, first-run warning — excellent |
| 6 | Recognition Rather Than Recall | 3 | Status never color-only; icon-only chart/table toggle; "Excludes: 7 patterns" hides contents |
| 7 | Flexibility and Efficiency | 3 | ⌘R means Refresh in menu, Restore Selected in browser sheet (SwiftResticApp.swift:213 vs SnapshotBrowserView.swift:139) |
| 8 | Aesthetic and Minimalist Design | 3 | Disciplined tokens; caption fatigue; diff sheet 5 tiles breaks 4-tile rhythm |
| 9 | Error Recovery | 3 | Copyable failures, first sentence visible; raw restic errors untranslated, no Retry |
| 10 | Help and Documentation | 3 | Concepts glossary real; help never linked at the jargon's side |

All ten heuristics scored (Operate surface). na_heuristics: none.

## Design Specificity Verdict

Authored, with a generic shell. Domain work is unmistakably restic-specific: "restic will use" live backend preview (RepositoryEditorSheet), SWIFTRESTIC_* env-var reference in HookEditor, forget-vs-Prune glossary (ConceptsView), retention projection as outcome ("≈ 21 snapshots would survive, reaching back about 617 days"). The surrounding language — icon-chip stat tiles, hairline cards, segmented pickers (Components.swift) — is the standard macOS settings dialect; Theme.swift delegates all color to system semantics, so the only brand is geometry.

Deterministic scan: detector over Views/ and App/ — exit 0, zero findings both runs. No false positives to classify. Calibration: rules tuned for web markup/CSS, so a clean pass on SwiftUI is weaker evidence than on the web.

Visual overlays: not applicable — native SwiftUI target, no web surface to inject.

## What's Working

1. Failure-to-action routing: Overview problem tiles → pre-filtered Activity with newest failure selected → copyable detail + Open Plan / Back Up Now. Alarm → action in one click.
2. Consequence projection: retention stated as outcome with zero-rule guard (isSafeToRun).
3. Accessibility as structure: glyph+word status, ChartPalette documents sub-3:1 slots and ships table alternative, Finder keyboard grammar in snapshot browser.

## Priority Issues

- [P1] Health numbers derive silently from snapshot listings; stale/failed listings read as fact. Overview asserted "Protected 0 of 2" while repository page listed 3 snapshots; plan page said "Snapshots 0 / No snapshots yet." UI rendered contradictory facts instead of "unknown". Fix: three distinct empty states (never loaded / failed+Retry / genuinely none); Protected tile renders "—" or error when any listing is missing. Files: OverviewView.swift, PlanDetailView.swift. Root cause not yet traced — trace before fixing.
- [P1] Failure message truncated at scan surface: failed row reads "Repository / Volumes/Photos…" — the volume name is the diagnosis. Fix: path-aware truncation or full first sentence as standing subline. File: ActivityView.swift.
- [P2] Disabled Save/Test buttons give no reason (PlanEditorSheet validation spans five tabs; mismatched passwords = two grey buttons). Fix: status line naming the missing piece. Files: PlanEditorSheet.swift, RepositoryEditorSheet.swift.
- [P2] Hooks sheet second tab renders as illegible black pill (confirmed in capture; RepositoryEditorSheet.swift:54-59 standard TabView tabItem). Real appearance defect or cacheDisplay artifact — needs one manual look; primary nav must never render unlabeled either way.
- [P2] Snapshot Refresh has no visible status (no spinner, no "updated 7:27 AM"), compounding issue 1. Fix: last-refresh timestamp + spinner in Snapshots card accessory regardless of row count. Files: PlanDetailView.swift, RepositoryDetailView.swift.
- [P3] Test Connection styles expected new-repository state ("No repository at that location yet. Saving will create one.") with red octagon — teaches discounting error styling on the sheet where wrong password is the unrecoverable error. Fix: neutral info status. File: RepositoryEditorSheet.swift.

## Cognitive Load

Moderate. Failures: chunking (retention tab 6 steppers in one group; repository maintenance card 5 DetailRows; diff sheet 5 tiles). Decision points >4 options: PlanEditorSheet 5 tabs; Repository Type picker 8 kinds in 3 sections; retention tab 6 steppers; RepositoryEditorSheet repository tab ~11 fields. Passes: single focus, grouping, visual hierarchy, one thing at a time, working memory, progressive disclosure.

## Emotional Journey

Peak: failure moment — problem routing moves alarm to action in one click. End: success visible only as sidebar subtitle "Last backup just now"; success notifications opt-in; no in-window success banner traced. Valleys respected: live elapsed timers on maintenance, "You can keep working while it runs", Find Files Stop button. High-stakes reassurance uniformly strong (prune lock warning, unlock corruption warning, restore overwrite warning twice, password "no recovery" line).

## Persona Red Flags

- Jordan (first-timer): Test Connection red for normal first-time state; 8-backend picker; password scare before mental model; ConceptsView only in Help menu, never linked from the sheet.
- Sam (accessibility): chart values hover-only; icon-only table toggle is the sole keyboard/VO path to per-day values; Activity detail panel has no announced relationship to selected row; black-pill tab if it reproduces live.
- Riley (stress tester): clamped minute field silently rewrites input to 0; PathListEditor Remove without confirm; console output pane = one Text in ScrollView (megabyte dumps); repository-removal guard doesn't cover open editor sheet.

## Minor Observations

Two console entry points; console pane squeezes at 940pt min width; "Due now" orange in Overview, black on plan page; HookEditor mixes .border/.roundedBorder; Find Files shows overwrite warning before any search; no "Back Up All" in menu bar extra; Formatting.swift quiet strength.

## Questions to Consider

- What would a verdict line ("2 of 2 plans protected; 1 problem needs attention") do to the four tiles?
- Should failure diagnosis be a first-class destination?
- Tappable restic terms in place (prune, blobs, locks)?
- Selection-driven inspector instead of per-row Browse/Compare at 500 snapshots?
- Provenance lines ("from restic stats at 7:27 AM") under numbers?
