---
target: the SwiftRestic app UI (all panes)
total_score: 34
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 1
target_identity: "file:/Users/newlix/github/at-least/SwiftRestic/Sources/SwiftRestic/Views"
timestamp: 2026-09-07T18-43-32Z
slug: sources-swiftrestic-views
---
# Impeccable critique (4th run) — SwiftRestic app UI

Method: dual-agent (A: agent_a1228626 · B: agent_9d94860a; A stalled once and was re-dispatched fresh)

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 4 | Sidebar spinner, OperationProgressView with rate/ETA/current file, "Running…" states, menu-bar icon swap — status is everywhere |
| 2 | Match System / Real World | 3 | "Blobs" tile and "Added" column are restic jargon leaking through |
| 3 | User Control and Freedom | 4 | Cancel for backup/restore/maintenance/search/console, Esc/Return on every sheet, sortable tables, console history |
| 4 | Consistency and Standards | 4 | One wobble: "Failures (7 days)" tile counts failed only, "Recent problems" card counts warned too — 1 vs 2 reads as a bug |
| 5 | Error Prevention | 4 | Every destructive action confirmed with consequence-stated dialogs; all-zero retention guard; console tokenizer; re-entrancy guard |
| 6 | Recognition Rather Than Recall | 3 | Back Up Now, Edit, Maintenance menu, Clear History trash are icon-only with no visible label and no .help |
| 7 | Flexibility and Efficiency | 3 | Cmd+Shift+B/F, Cmd+R, context menus; but no per-plan backup shortcut, no filter field on the 64-row Activity table |
| 8 | Aesthetic and Minimalist Design | 4 | Disciplined, restrained, captions earn their length |
| 9 | Error Recovery | 3 | Failure text verbatim + selectable + Open Plan/Back Up Now; but the sidebar restic-missing warning icon is a dead end and stale selection shows "Plan not found" after deleting the viewed item |
| 10 | Help and Documentation | 2 | Excellent inline captions but no Help menu, no doc links, no guided first-run beyond three welcome blurbs |
| **Total** | | **34/40** | **Good** |

## Design Specificity Verdict

Borderline — authored in behavior and copy, interchangeable in appearance. "Protected" counting coverage instead of bytes, the retention editor projecting an outcome instead of restating rules, the console's honest contract, and the maintenance lock caption are product-specific thinking. The visual shell is the stock-native KPI dashboard; identity lives in the system accent.

Deterministic scan: 0 findings with a control experiment proving the detector functions (gradient-text fired on an HTML probe) but its rules are web-pattern-oriented; audit.native.md states "no browser tooling or impeccable detect applies" to SwiftUI. Browser overlay: skipped, native app.

## Priority Issues

1. **[P1] Primary actions are unlabeled icon-only toolbar buttons** — Back Up Now, Edit, Maintenance, Clear History render icon-only with no .help tooltip. Fix: visible labels or .help at minimum.
2. **[P2] Stale-selection dead end after deletion** — selectSomething guards selection == nil, so deleting the viewed plan/repository lands on "Plan not found" with no exit except the sidebar. Fix: validate selection on count change and retarget to .overview.
3. **[P2] Restore overwrite risk is a standing caption, not a checkpoint** — the footer line is tuned out by the time it matters. Fix: restate in the panel's message or confirm on collision.
4. **[P2] Overload clusters** — retention's 6 steppers, 5-item Maintenance menu mixing safe and destructive, 5-segment diff filter. Fix: split/group and signal severity.
5. **[P3] Failures-vs-problems count mismatch on Overview** — tile counts failed only; card lists warned too; 1 vs 2 reads as a bug. Fix: align or caption.

## What's Working

1. Destructive-action choreography: five distinct confirmation dialogs, each stating the consequence and the non-consequence, plus console-level destructive detection.
2. Empty/zero-state completeness: every container has a distinct honest state; nothing reads as breakage.
3. Not-color-alone status everywhere: shape-differentiated icons with labels, diff glyphs, chart/table toggle justified in ChartPalette.

## Emotional Journey

Peak: the retention projection sentence (the app thinking for you); Find Files' empty state; the Activity "Problems" empty state. Reassurance at high stakes uniformly strong (delete/remove/prune/unlock/clear-history dialogs). Valleys: restore overwrite is a tuned-out caption; deleting the viewed plan lands on a dead-end pane; healthy is still a nonevent.
