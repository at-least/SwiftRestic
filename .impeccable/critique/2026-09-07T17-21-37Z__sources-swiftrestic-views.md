---
target: the SwiftRestic app UI (all panes)
total_score: 35
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 2
target_identity: "file:/Users/newlix/github/at-least/SwiftRestic/Sources/SwiftRestic/Views"
timestamp: 2026-09-07T17-21-37Z
slug: sources-swiftrestic-views
---
# Impeccable critique (2nd run, post-fix) — SwiftRestic app UI

Method: dual-agent (A: agent_076b4677 · B: agent_38eb8eaf)

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 4 | Exemplary: OperationProgressView (files/bytes/rate/ETA), per-plan sidebar spinner, maintenance progress, console "Running…" |
| 2 | Match System / Real World | 4 | restic jargon consistently translated; honest, precise captions throughout |
| 3 | User Control and Freedom | 3 | Cancel everywhere; Clear History permanent (no undo); plan deletion only in sidebar context menu |
| 4 | Consistency and Standards | 4 | One Card/StatTile/SheetHeader system, Theme tokens, identical confirmation-dialog patterns everywhere |
| 5 | Error Prevention | 4 | Disabled Save until complete, retention zero-rule warning, prune confirm, console destructive tokenizer |
| 6 | Recognition Rather Than Recall | 4 | Helper captions under every sheet control, inline hook variable reference, console History menu |
| 7 | Flexibility and Efficiency | 3 | ⇧⌘B/⇧⌘F/⌘R exist; but no Cmd+N (newItem emptied), no Console shortcut, Activity not sortable |
| 8 | Aesthetic and Minimalist Design | 3 | Restrained, but SnapshotTable minHeight renders phantom gray rows on the two most-visited screens |
| 9 | Error Recovery | 3 | Selectable error text, detail panel; but no Retry, no link to the plan from a failure |
| 10 | Help and Documentation | 3 | Inline captions excellent; no help menu, no restic-doc links |
| **Total** | | **35/40** | **Good** |

## Design Specificity Verdict

Borderline. The interaction design is unmistakably authored for restic (plan/repository model, retention zero-rule warning, destructive-command tokenizer, SWIFTRESTIC_* hook reference); the visual shell is the generic modern-macOS dashboard kit. Identity lives in copy and behavior, not in any signature visualization.

Deterministic scan: `impeccable detect --json` over Views → 0 findings, exit 0. Assessment B proved by controlled experiment that the detector's rules do not run on `.swift` content (same gradient-text pattern fires in an .html probe, nothing in a .swift probe; `.swift` is absent from the detector's documented extension list) — so 0 means "does not apply", not "clean". Browser overlay: skipped, native app.

## Priority Issues

1. **[P1] Phantom rows in SnapshotTable** (PlanDetailView.swift:234, minHeight: 180) — empty row slots render as gray rounded bars below real rows on plan/repository pages; reads as a broken loading skeleton. Fix: size to content.
2. **[P1] Activity list unsorted, visible order non-monotonic** (ActivityView.swift) — capture shows Sep 8 rows then Aug ascending; no sort descriptors. Fix: default sort by startedAt descending; sortable columns.
3. **[P2] Failure flow stops at reading** — deep-link works, but no auto-select of the newest problem, no Retry, no Open Plan in the detail panel.
4. **[P2] Unlabeled VoiceOver toggles** — HookEditor.swift:28 and SettingsView.swift:157 use Toggle("").labelsHidden() for enable state.
5. **[P3] "Protected" hero tile semantically weak** — sums latest-snapshot bytes ("5 bytes" with the demo data); reads as nonsense as the dashboard's first tile.

## What's Working

1. Destructive-action gating with consequence-naming copy at every high-stakes path (delete plan names the plan; prune names the exclusive lock; Clear History states the exact count).
2. Non-color status discipline: CVD-safe palette, chart/table fallback, glyph-coded diffs, accessibilityLabels on outcome icons.
3. Honest zero-states: "—" with explanation instead of confident zeros; distinct "no statistics yet" vs "repositories are empty".

## Emotional Journey

Peak: the destructive dialogs are the trust high point. Valleys: first failure (no Retry/auto-select), restore overwrite caption far from the commit point, phantom table rows recurring on every visit. Peak-end: sessions end in an unsorted Activity list rather than a reassuring note.
