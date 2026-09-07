---
target: the SwiftRestic app UI (all panes)
total_score: 33
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 2
target_identity: "file:/Users/newlix/github/at-least/SwiftRestic/Sources/SwiftRestic/Views"
timestamp: 2026-09-07T17-52-22Z
slug: sources-swiftrestic-views
---
# Impeccable critique (3rd run) — SwiftRestic app UI

Method: dual-agent (A: agent_f2d362e1 · B: agent_6e195072)

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 4 | OperationProgressView (files/bytes/rate/ETA/current file), sidebar phase + spinner, "Due now", maintenance "running…" — genuinely excellent |
| 2 | Match System / Real World | 3 | Mostly translated, but "Blobs" tile and "Check + Read 5% of Data" expose raw restic semantics |
| 3 | User Control and Freedom | 3 | Cancel everywhere, Esc closes every sheet; Clear History and Remove are confirm-only, no undo |
| 4 | Consistency and Standards | 4 | One card/tile/banner language, uniform confirmationDialog pattern, native controls throughout |
| 5 | Error Prevention | 4 | Standout: console destructive-command gating, retention all-zero guard, sidebar deletes routed through the same dialogs as detail pages |
| 6 | Recognition Rather Than Recall | 3 | Hook variable reference, console History; retention offers 6 steppers with no survival projection |
| 7 | Flexibility and Efficiency | 3 | ⌘⇧B/⌘⇧F/⌘R; but no per-plan run shortcut, no per-plan Activity filter |
| 8 | Aesthetic and Minimalist Design | 3 | Overview duplicates signal: Failures tile + Recent problems card |
| 9 | Error Recovery | 4 | Failure detail panel with Open Plan / Back Up Now, auto-select on arrival from dashboard — the app's best peak |
| 10 | Help and Documentation | 2 | No help surface: no restic glossary, no docs links, tooltips carry the only explanations |
| **Total** | | **33/40** | **Good** |

## Design Specificity Verdict

Borderline — authored microcopy, interchangeable layout. The craft is native and disciplined; every surface opens with the identical 4-StatTile row so Overview/Plan/Repository are silhouettes of each other. The app never visualizes its emotional core ("your data is safe") beyond a byte total.

Deterministic scan: 0 findings, exit 0 — but the detector's rules do not apply to .swift (control experiment: gradient-text fired on an .html probe, not on Swift; extension list in reference/hooks.md has no .swift; audit.native.md: "no browser tooling or impeccable detect applies" for SwiftUI). Zero = scope boundary, not clean. Browser overlay: skipped, native app.

## Priority Issues

1. **[P1] Truncated failure text in the Activity Detail column** — lineLimit(1) cuts "The repository does not exist (code 10)." to "The repository…" exactly when stress is highest; the full text hides behind row selection with no visual cue. Fix: wrap Detail to 2-3 lines for failed outcomes or add a disclosure affordance; auto-select failed rows on arrival in All-runs mode too.
2. **[P1] Retention editor is a 6-stepper wall with no outcome preview** — users decide what gets deleted blind. Fix: live projection ("roughly N snapshots survive, ~X days") under the summary; presets optional.
3. **[P2] Invisible interactive tiles** — the Failures tile is a plain button with no hover cue (the problem rows have chevrons; the tile doesn't). Fix: hover tint + trailing affordance.
4. **[P2] "Remove Stale Locks" is the only ungated maintenance action** (RepositoryDetailView.swift:41) — it can interfere with other restic processes and sits next to gated Prune. Fix: same confirmation treatment.
5. **[P2] Help floor thin for an Operate surface** — prune vs forget, "Read 5% of data", Blobs assume restic literacy. Fix: short in-app Concepts sheet or help anchors on Maintenance items.

## What's Working

1. Failure-to-action routing: problem rows → pre-filtered, newest problem pre-selected, detail panel with Open Plan / Back Up Now — "a failure the user cannot reach is a failure they cannot fix" made real.
2. Honest zero/empty states everywhere, including content-sized snapshot tables with no phantom rows.
3. Accessibility as data integrity: CVD-safe palette + labeled chart/table toggle, glyph-coded status, labeled toggles.

## Emotional Journey

Peak: the failure recovery arc (dashboard → filtered Activity → selected problem → actionable panel). High-stakes dialogs remain the trust high point. Valleys: the truncated Detail column hides the most-wanted sentence; "Remove from SwiftRestic…" renders as an orphaned chip below All Snapshots; healthy is a nonevent — no designed "all clear" state.
