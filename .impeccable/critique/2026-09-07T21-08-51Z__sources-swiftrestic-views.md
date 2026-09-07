---
target: the SwiftRestic app UI (all panes)
total_score: 34
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 2
target_identity: "file:/Users/newlix/github/at-least/SwiftRestic/Sources/SwiftRestic/Views"
timestamp: 2026-09-07T21-08-51Z
slug: sources-swiftrestic-views
---
# Impeccable critique (5th run) — SwiftRestic app UI

Method: dual-agent (A: agent_51c57b95 · B: agent_70eadeb0)

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 4 | OperationProgressView (files/bytes/rate/ETA/current file), sidebar spinner, "Reading snapshots…", maintenance row with Cancel — exemplary |
| 2 | Match System / Real World | 3 | "Blobs 6" and "Compression saved 34.1%" unexplained at point of use; Activity's "Plan" column holds repository names for check runs |
| 3 | User Control and Freedom | 4 | Cancel for backup/restore/maintenance/search/console, Esc closes every sheet, selection revalidated after deletes |
| 4 | Consistency and Standards | 3 | Chart series colors (blue/orange) vs accent-only sidebar icons; Problems tile is a button only when >0, affordance hover-only |
| 5 | Error Prevention | 4 | Every destructive action confirmed with consequence-stated copy; retention all-zero guard; console destructive confirmation with --dry-run hint |
| 6 | Recognition Rather Than Recall | 3 | Good tooltips and sidebar subtitles, but the restic-missing signal is a tooltip-only 14pt triangle |
| 7 | Flexibility and Efficiency | 3 | ⇧⌘B/⇧⌘F/⌘R, context menus; but no per-plan backup shortcut, no ⌘1-4 section jumps, no persistent console history |
| 8 | Aesthetic and Minimalist Design | 3 | Calm and restrained; Overview stacks 5 sibling blocks; Plan detail is half-empty with one snapshot |
| 9 | Error Recovery | 4 | Failure's first sentence preserved at 2-line limit, selectable text, auto-selected problem row, banners |
| 10 | Help and Documentation | 2→3 | Concepts sheet (10 plain-language terms) + restic doc links in Help menu + pervasive captions; glossary only reachable via Help menu |
| **Total** | | **34/40** | **Good** |

## Design Specificity Verdict

Borderline — authored in microcopy and safety design, interchangeable in layout and visual identity. The genuinely authored moments are at the point of decision (Protected coverage, retention projection, the unlock corruption warning, the glossary). Snapshots — the app's core object — have no visual identity; the per-plan chart series is positional and appears nowhere else.

Deterministic scan: 0 findings. This run's control refined the earlier characterization: the detector CAN fire line-level findings inside .swift files (its rules are regex-based), so the zero is a genuine content-level "no web anti-pattern regex matches", not a file-type skip — though the rule set remains web-oriented and audit.native.md states detect does not apply to native apps. Browser overlay: skipped, native app.

## Priority Issues

1. **[P1] "Recent problems" isn't recent** — OverviewView.swift:341-343 filters storage-ordered runs and prefix(5)s without sorting; the capture shows "6 days ago" above "3 days ago" on the dashboard's trust-making card. Fix: sort by startedAt descending before prefix(5).
2. **[P1] Activity's "Plan" column mislabels check runs** — check runs are repository-level, and the column shows the repository name under "Plan" ("Documents vault | Check"), teaching a wrong model. Fix: rename the column "Subject" or render the entity kind.
3. **[P2] No stable plan identity color** — ChartPalette assigns by domain position, so colors shift when plans change and never appear outside the chart. Fix: persist a color per plan and carry it through sidebar, tiles, run rows.
4. **[P2] Maintenance menu density** — 5 commands; check depths phrased differently from the editor's Depth picker. Fix: collapse to Check… / Prune Now… / Remove Stale Locks… with depth in the dialog.
5. **[P3] Disabled-without-explanation states** — Find/Console/Back Up Now gray out silently; the restic-missing explanation is a tooltip-only triangle. Fix: a detail-pane banner when restic is missing; "why" sentences on disabled controls.

## What's Working

1. The failure path is designed end-to-end: buttons with authored labels, filter carried into Activity, newest problem pre-selected, detail panel answers with actions.
2. Destructive-action copy states consequences, not threats — unlock ("removing its lock can corrupt the repository") and clear history (exact count) are the exemplars.
3. The retention projection plus the all-zero guard converts six unknowable steppers into one outcome sentence at the moment of decision.

## Emotional Journey

Peaks: the projection sentence, Find's empty-state promise, the Problems empty state. Valleys: "Due now" twice in warning-orange with no affordance; "Recent problems" misrepresenting recency; plan detail half-empty with one snapshot. Peak-end: the failure journey ends strong (selected problem, red message, actions).
