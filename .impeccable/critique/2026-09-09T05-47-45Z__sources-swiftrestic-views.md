---
target: the app UI (Sources/SwiftRestic/Views)
total_score: 35
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 2
target_identity: "file:/Users/newlix/github/at-least/SwiftRestic/Sources/SwiftRestic/Views"
timestamp: 2026-09-09T05-47-45Z
slug: sources-swiftrestic-views
---
# Design Critique — SwiftRestic app UI (Sources/SwiftRestic/Views) — re-run

Method: dual-agent (A: agent_9b626dd1-d4cb-4c3c-8c79-3991273f7f58 · B: agent_119c0cf8-18ea-48ff-92e3-8672a2d699ec)
Evidence: source reading + 13 rendered debug captures (light/dark) across all changed surfaces from the same session.

## Design Health Score

| # | Heuristic | Score | Key issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 4 | Solid — live progress, freshness stamps, menu bar lines for every work kind |
| 2 | Match System / Real World | 3 | Retention shorthand cryptic; Blobs needs glossary |
| 3 | User Control and Freedom | 4 | Cancels everywhere; hide-not-cancel restore; dirty-guarded Esc |
| 4 | Consistency and Standards | 3 | Plan Delete in toolbar; repository remove still at scroll bottom |
| 5 | Error Prevention | 4 | Consequence confirmations; non-zero retention guard |
| 6 | Recognition Rather Than Recall | 4 | Live preview, prompts, save reasons, console recall |
| 7 | Flexibility and Efficiency | 3 | No Return on snapshot rows; no batch restore; no manual forget |
| 8 | Aesthetic and Minimalist | 3 | Retention tab dense; some 30+-word dialogs |
| 9 | Error Recovery | 4 | Listing-outcome honesty; stale strips; paved failure panels |
| 10 | Help and Documentation | 3 | Concepts + captions; no routing from "forget" meetings |
| **Total** | | **35/40** | **Good — top of band** |

## Design Specificity Verdict

Native skin by policy (system accent, semantic colors, custom geometry only) — category-interchangeable composition; product-authored copy and state design (retention projection, diff disambiguation, month grouping, banner-queue eviction policy, plan color identity, Concepts voice). Structural weakness: pane sameness (tiles-then-cards skeleton ×3) and no signature element for snapshots (no timeline/coverage spine).

Deterministic scan: 0 findings over 17/17 files (explicit args); directory invocation scanned 0 files (extension filter — vacuous, not clean). No web surface; 13 debug captures stand in for overlays and showed no defects.

## Priority Issues

1. [P1] Critical state tooltip-locked on detail panes — PlanDetail/RepositoryDetail Snapshots tiles show "—" with reason in .help only (PlanDetailView.swift:147-154, RepositoryDetailView.swift:134-141); Overview's caveats pattern not applied there. Fix: visible caption under tile row when outcome != .loaded. Command: /impeccable polish
2. [P1] No keyboard route to snapshot row actions — Return dead on selection (PlanDetailView.swift:445-479); context menu is not a keyboard path. Fix: .onKeyPress(.return) → Browse, mirroring the browser grammar. Command: /impeccable polish
3. [P2] Destructive-affordance asymmetry — repository removal (pauses all plans; more destructive) is a text button at the bottom of a scroll (RepositoryDetailView.swift:216-221) while plan delete is toolbar. Fix: toolbar-area placement. Command: /impeccable polish
4. [P2] Retention scaffolding weak — six bare steppers, 0 = "off", projection says survives not deletes (PlanEditorSheet.swift:228-275). Fix: preset chips + "next run would remove N snapshots" line. Command: /impeccable shape
5. [P3] Menu-bar-off + closed window orphans the scheduler; warning buried in ExpandableCaption (SettingsView.swift:33-37). Fix: confirm consequence or guarantee window return at launch. Command: /impeccable harden

## Cognitive Load

6 of 8 pass. Failures: chunking (six retention steppers); minimal choices (8-kind edit-mode picker; 5-option hook event picker; 6 steppers; up-to-5 diff segments). Working memory engineered away (editor defaults, diff pre-pick, query snapshotting); progressive disclosure exemplary.

## Emotional Journey

Strong: first run (never-lying CTA, missing-restic card), password warning placement, owned first-backup surprise, peak-end run announcements, paved failure valley (pre-filtered Activity + newest problem selected), destructive confirmations with consequences. Residual valleys: fresh-launch Protected "—"+caveat reads as breakage to eager new users; "Waiting for a repository password" easy to miss at card bottom.

## Persona Red Flags

Alex: Return dead on snapshot rows; no batch restore; no manual forget; bandwidth steppers (typing 50000 impossible); console history capped 20.
Sam: tooltip-only failure reasons on detail panes; custom tile button styles may lack visible focus rings; charts opaque to VoiceOver without announced table alternative.
Riley: 320pt nested-scroll table, filter matches only ID/date strings; sidebar names without lineLimit; four same-named "Refresh" verbs with different scopes; banner references a nonexistent "Extra environment" UI field. Credited: cancellation guards; restore cancelled when repository deleted (tested).

## Minor Observations

Tools section with one item; Activity headerless after it. Problems tile button only when problems exist. "Read All Data" lacks size-aware expectation. Find double-click inert (inconsistent with table). Restore banner lacks Reveal-in-Finder. Console secret filter oversold by its sidebar note.

## Questions to Consider

- Is "Protected: N of M" the right instrument, or should per-plan protection be first-class?
- Should retention ask "how far back do you want to reach?" and derive the buckets?
- Should repository removal be harder to reach than plan deletion, or symmetric?
