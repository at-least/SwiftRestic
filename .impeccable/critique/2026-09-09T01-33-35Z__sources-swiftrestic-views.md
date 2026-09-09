---
target: the app UI (Sources/SwiftRestic/Views)
total_score: 31
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 3
target_identity: "file:/Users/newlix/github/at-least/SwiftRestic/Sources/SwiftRestic/Views"
timestamp: 2026-09-09T01-33-35Z
slug: sources-swiftrestic-views
---
# Design Critique — SwiftRestic (Sources/SwiftRestic/Views)

Method: dual-agent (A: agent_e6419afb-4985-429e-b200-3e6cc73792d1 · B: agent_434a21b9-18cc-4325-9a77-320b443485fa)

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | In-run visibility excellent — but a successful backup ends with no in-app signal and `notifyOnSuccess` defaults false (AppModel.swift:662–703, ConfigStore.swift:8) |
| 2 | Match System / Real World | 3 | "Blobs" tile is raw restic with tooltip-only translation (RepositoryDetailView.swift:150–155); retention shorthand "24h, 7d, 4w" |
| 3 | User Control and Freedom | 3 | Cancel exists everywhere it matters — except snapshot-listing refresh can't be cancelled (AppModel.swift:790–794) |
| 4 | Consistency and Standards | 3 | Return restores in SnapshotBrowser but not Find Files; console reachable via sidebar with zero repos while its toolbar button disables; editor sizing inconsistent |
| 5 | Error Prevention | 3 | Guards mostly 4-level deep — but quitting mid-backup cancels the run with no interlock prompt (SwiftResticApp.swift:27–40) |
| 6 | Recognition Rather Than Recall | 3 | Solid: summaries, "restic will use" preview, disabled-Save reasons at the button |
| 7 | Flexibility and Efficiency | 3 | ⌘B/⇧⌘B/⇧⌘F/⌘R/⌘N, paste-and-drag paths — but no ↑ history recall in console field, no batch snapshot ops |
| 8 | Aesthetic and Minimalist Design | 3 | Disciplined token system; cost is caption density — 2–4-line explanations on nearly every form, lock warning repeated 4× |
| 9 | Error Recovery | 4 | Genuinely excellent: Retry rows, stale listings kept visible under dated strips, persistent error banners vs self-dismissing successes |
| 10 | Help and Documentation | 3 | Concepts glossary, doc links, at-button reasons — but nothing answers "what is a blob?" at the tile |
| **Total** | | **31/40** | **Good (upper band)** |

All ten heuristics scored; applicable maximum 40; none n/a. Cognitive load: 3/8 checklist failures (moderate) — chunking (six keep-steppers in one group, five stat tiles in one row), borderline 5-segment diff filter, plus lock-warning redundancy.

## Design Specificity Verdict

**Authored-for-product.** Structural evidence: coverage-first dashboard tile that refuses fake zeros ("—" plus naming tooltip, OverviewView.swift:92–122); retention translated into an outcome sentence ("≈ N snapshots would survive, reaching back about X days", PlanEditorSheet.swift:236–250); destructive console commands confirmed against the exact re-quoted argument list with secrets filtered from history; "Cancelled" vs "Interrupted by quitting SwiftRestic" as distinct outcomes. Remaining genericity is idiomatic: stat-tile-plus-cards grid repeats across all three detail pages; Welcome could belong to any backup app.

**Deterministic scan:** detector ran clean over all 17 view files — exit 0, empty findings array. On a native SwiftUI target its markup-oriented rules have limited coverage; "clean" means no generic-template smells found, not proof of quality. Corroborating counts: 12 `.confirmationDialog` / 0 raw `.alert` (all destructive paths confirmed); 16 `keyboardShortcut` modifiers; 11 `accessibilityLabel`s concentrated in files with icon-only controls (SwiftUI derives labels from text, so counts neither prove nor disprove a11y).

**Visual overlays:** unavailable — native SwiftUI target, no browser surface; no user-visible overlay exists.

## Overall Impression

A mature, unusually honest interface at 31/40; the gap to Excellent is not structural. Navigation, states, and error recovery are at or near the ceiling. What stands between this app and 35+ is three unguarded trust moments: quitting mid-backup silently cancels the run, a successful backup ends without a period, and the failure channel is silent for VoiceOver users.

## What's Working

1. Honest-state discipline: failed refreshes never collapse into "no snapshots"; stale listings stay visible under dated strips; the Protected tile wears "—" rather than a fake zero. For backup software this is the core design act.
2. The retention projection: the most dangerous decision rendered as a live outcome sentence, in editor and detail alike.
3. A power-user escape hatch made safe: console survives pane switches, confirms destructive verbs with re-quoted commands, filters secrets from history.

## Priority Issues

1. **[P1] Quitting mid-backup cancels the run silently.** Trust contract of a backup app; `applicationShouldTerminate` already returns `.terminateLater` so the hook exists. Fix: "A backup is running — quit anyway?" alert before terminating. → /impeccable harden
2. **[P1] A successful backup ends unmarked by default.** No banner, no notification (notifyOnSuccess=false default); "did it work?" requires hunting tiles. Fix: self-dismissing success banner on plan pane + Overview; leave notification default alone. → /impeccable harden
3. **[P1] Failure channel silent for VoiceOver and invisible in the console pane.** BannerView has no announcement/live-region semantics (Components.swift:85–126); ResticConsoleView renders no banner loop — a failure while the console is open goes unseen. Fix: announcement semantics + shared banner queue in console pane. → /impeccable audit
4. **[P2] Console and Find Files ignore keyboard reflexes.** No ↑/↓ history recall in console field (ResticConsoleView.swift:54–75); Find Files pattern field not auto-focused. → /impeccable audit
5. **[P2] Welcome's "New Backup Plan…" is a disabled primary CTA with no stated reason** (RootView.swift:470–472); disabled controls don't show tooltips, so the explanation is unreachable at peak adoption risk. Fix: keep enabled, route to repository creation, or caption the prerequisite. → /impeccable onboard

## Persona Red Flags

**Alex (power user):** no ↑/↓ console history recall; snapshot table height-capped at 320pt in a dashboard card (PlanDetailView.swift:376) — 1,000 snapshots in a tiny scroller; Activity sortable but not searchable (2,000 rows); no multi-select in snapshot surfaces.

**Sam (accessibility):** transient error banners never announced to screen readers; console pane shows no banners at all; disabled toolbar buttons rely on `.help` which typically doesn't display when disabled. Strong: labeled icon-only controls, state never color-only, chart table toggle.

**Riley (stress tester):** quit mid-backup unprompted is the best attack; black-holed repository holds a spinner up to 300s with no Stop. Exemplary otherwise: repo removal pauses plans and says so; Clear History confirms with exact count; prune/check confirmations spell out lock consequences.

## Minor Observations

- Find Files' Restore button lacks the `.defaultAction` Return shortcut its browser counterpart has (FindFilesView.swift:170–172).
- Repository-lock warning repeated four times in RepositoryDetailView plus Concepts.
- `BackupPlan.tags` in the model with no editor UI — unreachable feature.
- Diff "Different folders or host" hint truncates at one line — the case where the full sentence matters.
- Welcome glyph on accent gradient can go low-contrast under light accents.
- Sidebar restic-missing warning is tooltip-only — no route to the Settings tab with the fix.
- Menu-bar extra is `.menu` style: no at-a-glance progress without opening it.

## Questions to Consider

- The dashboard's first tile answers "how many plans are protected." Would "were my Documents protected, and when?" survive as the first object on screen?
- The retention projection is the app's best idea, and it's a caption. What would a retention timeline — dots across a year, doomed ones crossed out — do to the delete-decision moment?
- Restore is the emotional peak yet lives in a sheet over a sheet. Would a dedicated restore flow — search, preview, conflicts shown, restore, verify — retire the warning copy by making the outcome visible first?
