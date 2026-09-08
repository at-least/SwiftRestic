---
target: SwiftRestic app UI (Sources/SwiftRestic/Views)
total_score: 34
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 1
target_identity: "file:/Users/newlix/github/at-least/SwiftRestic/Sources/SwiftRestic/Views"
timestamp: 2026-09-08T16-53-22Z
slug: sources-swiftrestic-views
---
# Design Critique — SwiftRestic app UI (Sources/SwiftRestic/Views)

Method: dual-agent (A: agent_01ee3e08-f0ca-4bce-9b29-3ecaa799f38f · B: agent_9ed1b065-3e76-4a5f-9f91-4ea3ebb0464d)

Surface mode: Operate (task-completion app UI). Visual evidence: 8 self-capture screenshots from a Debug build with a seeded demo repository (real restic repo, 3 snapshots, 8 run records; Keychain untouched via `SWIFTRESTIC_CONFIG_DIR` + `SWIFTRESTIC_REPO_PASSWORD`). Some seeded dates were written as UTC on a UTC+8 Mac, so the specific date strings visible in captures are seed artifacts — the truncation and formatter behaviors they exposed are real and traced to code.

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 4 | Excellent: live progress with files/bytes/rate/ETA, sidebar spinners, elapsed-time `TimelineView` on maintenance, menu-bar icon swap |
| 2 | Match System / Real World | 3 | restic exit codes mapped to plain outcomes; but "Blobs 64" as a top-level tile is tooltip-only jargon, retention shorthand "Keep 24h, 7d…" leads its sentence |
| 3 | User Control and Freedom | 3 | Cancel everywhere, Esc-with-dirty-check editors; but Clear History and prune are permanent (dialog only), Problems filter sticks once set |
| 4 | Consistency and Standards | 3 | Native SplitView/sheets done right; but toolbar labeling grammar differs per pane, Activity paints phantom striped rows where SnapshotTable content-sizes |
| 5 | Error Prevention | 4 | Every destructive action confirmed with consequences stated; retention all-zero guard; console confirms exact command, suggests `--dry-run`, excludes secret-bearing commands from history |
| 6 | Recognition Rather Than Recall | 4 | Plan colour identity across sidebar/chart/runs; "restic will use" live preview; console history persisted; retention outcome projection |
| 7 | Flexibility and Efficiency | 3 | ⌘B/⇧⌘B/⇧⌘F/⌘R, drag-or-paste paths, console history; but ⌘N is killed entirely, browser folders keyboard-dead, no batch snapshot actions |
| 8 | Aesthetic and Minimalist Design | 3 | Restrained native palette, tokenised spacing; but Welcome lockup awkward, StatTile truncates its most important value, repository pane trails into dead space |
| 9 | Error Recovery | 4 | Failures keep restic's own words, selectable; problem rows deep-link into pre-filtered Activity; "Open Plan"/"Back Up Now" offered in the failure panel |
| 10 | Help and Documentation | 3 | ConceptsView glossary + doc links; excellent inline captions; but Concepts is menu-only and nothing links to it from the confusing "Blobs" tile |
| **Total** | | **34/40** | **Good — address weak areas, solid foundation (28–35 band)** |

## Design Specificity Verdict

**LLM assessment:** Unmistakably authored for this product, not a template. The dashboard's first tile is "Protected 2 of 2" (coverage, not a vanity byte sum); the repository pane leads with Blobs and Compression saved — the two numbers someone diagnosing dedup actually wants; the Compare sheet speaks restic's +/−/M glyph language while explaining it; the console keeps restic's raw output unparsed and scrubs secret-bearing commands from history; retention is projected as an outcome ("≈ 35 snapshots would survive, reaching back about 617 days") instead of restating bucket rules; ConceptsView exists to translate restic's vocabulary rather than hide it. Per-plan colour identity is minted at creation and carried across sidebar dot, chart series, and run lists. The information architecture *is* restic's mental model (repository → plan → snapshot → run), so an unrelated product could not reuse this surface unchanged. The residual genericness is small: SF Symbols defaults, the icon-chip tile pattern, and the Welcome screen's marketing trio — the one place that could belong to any backup product.

**Deterministic scan:** Unavailable for this target — this is *not* a clean result. `impeccable detect --json` returned `[]` with exit 0 on both `Sources/SwiftRestic/Views` and the repo root, but a positive-control HTML probe (deliberate tight-leading) was correctly flagged with exit 2, and `strings` on the detector binary shows zero Swift support (web-only: html/blade/svelte/astro/vue/jsx/tsx/js/ts). The detector silently skipped all Swift files — silence here is not success (a caveat worth remembering on any native target). No deterministic findings exist to weave in; none were missed relative to the manual review, and no false positives are possible. The skill's own `audit.native.md` states `impeccable detect` and browser tooling do not apply to SwiftUI.

**Visual overlays:** None — a native macOS app has no DOM to inject `detect.js` into, so no user-visible overlay exists. Visual evidence instead came from eight self-capture screenshots (the Debug build's documented capture mode).

## Overall Impression

This is a mature, deeply considered Operate UI that has clearly been through critique cycles — state coverage, cancellation hygiene, and error empathy are well above what most native apps ship. The remaining work is not structural; it is a handful of places where the interface fails its own high standard of legibility: the app whose entire job is schedules truncates the AM/PM off its most-watched timestamp, and a first launch can momentarily look broken. The single biggest opportunity: make "did each plan last succeed, and when?" the dashboard's opening statement.

## What's Working

1. **Retention outcome projection** (PlanEditorSheet.swift:206-229, PlanDetailView.swift:137-146) — the hardest mental arithmetic in backup software (six buckets against a schedule) answered as a concrete outcome sentence, in both editor and detail. It converts a configuration task into a decision about a result.
2. **Plan colour identity** (ChartPalette.swift:43-57, minted in PlanEditorSheet.swift:44-51) — a stable palette slot per plan with deterministic FNV-1a fallback, "Other" deliberately grey. Sidebar dot, chart stack, and legend agree without the user consulting a legend twice.
3. **The console made safe** (ResticConsoleView.swift:143-188) — the escape hatch for everything the UI does not cover gets a destructive confirmation quoting the exact command, a dry-run nudge, cancellation, and a persisted history that silently excludes secret-carrying commands. Power-user freedom and safety are not traded off.

## Priority Issues

*Synthesis note: these are reordered from Assessment A's unanchored ranking. The persistent, every-session table-clip defect outranks the transient launch race; the silent first backup was promoted from the emotional-journey findings because its cost is real (an unprompted multi-gigabyte upload). The Welcome lockup and toolbar grammar moved to minor observations for the same reason — first-run cosmetics vs. persistent defects.*

1. **[P1] StatTile truncates the one value that must be exact.** Plan detail shows "Next backup: Sep 9, 2026 at 3:00…" — the AM/PM is ellipsized (`minimumScaleFactor(0.75)` + `lineLimit(1)` in Components.swift:156-163, fed by PlanDetailView.swift:97-102). A user cannot tell morning from evening in a scheduler app. The specific date in the capture is a seed artifact; the truncation is real code behavior. **Fix:** format tile timestamps for tiles — "Today 3:00 AM" / "Tomorrow 3:00 AM" / "in 6 h" — full timestamps in tooltips. **Suggested command:** /impeccable polish
2. **[P2] SnapshotTable clips its last row.** With 3 snapshots the third row is cut mid-glyph with a stray horizontal scrollbar (capture: repository pane). The content-height estimate `min(320, 34 + count*26)` (PlanDetailView.swift:266) underestimates real row height — the exact "reads as broken" failure its own comment set out to avoid. Persistent: visible every session with ≥3 snapshots. **Fix:** measure real row height or use the table's intrinsic height inside the scroll pane. **Suggested command:** /impeccable layout
3. **[P2] Snapshot browser is a keyboard dead-end.** Opening a folder is double-click only (`onTapGesture(count: 2)`, SnapshotBrowserView.swift:102); no Return-to-open, no Backspace/⌘-up to go up, no Restore shortcut. Arrow-key users highlight a folder and stop. Restoring a file is the product's payoff moment. **Fix:** handle Return/Backspace on List selection; add a Restore shortcut. **Suggested command:** /impeccable audit
4. **[P2] Creating a plan silently starts a real backup within a minute.** Sensible design, never told to the user — a first-timer's first experience of the app is an unprompted multi-gigabyte upload starting behind their sheet. **Fix:** one caption in the schedule tab ("Creating a plan starts a first backup within a minute; pick Manually to prevent that"). **Suggested command:** /impeccable clarify
5. **[P2] First launch can look broken.** A config-load race was accidentally photographed: empty sidebar, no loading indicator, no `ProgressView` state exists for configuration load. On a slow disk the first seconds read as "broken/empty" instead of "starting". Transient, but it is the app's first impression. **Fix:** add a loading state for config bootstrap before the empty states. **Suggested command:** /impeccable onboard

## Persona Red Flags

**Alex (impatient power user)** — Real gifts: ⌘B/⇧⌘B/⇧⌘F/⌘R, drag-and-drop paths, persisted console history, menu-bar plan runs. Red flags: `CommandGroup(replacing: .newItem) {}` (SwiftResticApp.swift:160) kills ⌘N — adding a repository is always a mouse trip to the sidebar footer Menu; the Compare sheet's per-row Browse/Compare are small text buttons with no shortcuts and no double-click; retention's six steppers force six click-sessions instead of accepting a typed "7d 4w" preset; no way to run two plans' backups in one gesture short of ⇧⌘B for all.

**Sam (accessibility-dependent)** — Strong foundations: status carried by symbol shape + colour + text (ActivityView.swift:49-54); diff glyphs are characters with colour only reinforcing; icon-only buttons keep real VoiceOver labels; mini toggles get explicit accessibilityLabels; the chart has a table alternative with a documented light-mode contrast admission (ChartPalette.swift:8-10). Red flags: the diff list's "+/−/M/U" glyphs are bare `Text` (SnapshotDiffView.swift:199-203, 271-278) — VoiceOver reads "plus" without saying "added"; the sidebar's three plan states (spinner / pause icon / colour dot) are distinguishable only by symbol until the subtitle; "Due now" is orange-on-light caption text, borderline contrast; the chart's hover callout is visual-only with no accessible summary.

**Riley (stress tester)** — Excellent cancellation hygiene (`.task(id:)` cancel guards in browser/diff/find are models of stale-result prevention). Red flags: the config-load race above is the real first-seconds experience on a slow disk; renaming a plan splits its chart history into a second series with a new colour (deliberately handled, but nothing tells the user why the chart "duplicated"); the minute picker silently offers only :00/:15/:30/:45 (PlanEditorSheet.swift:181-184) — a typed expectation of :05 fails invisibly; quit during a running backup waits gracefully but the UI offers no "backup in progress" caution at quit time.

## Cognitive Load

Failed items: **Chunking** (retention tab: six "Keep" steppers in one group, PlanEditorSheet.swift:192-199; Compare sheet: five stat tiles, SnapshotDiffView.swift:126-160); **Minimal choices** (repository Type picker offers 8 kinds, Repository.swift:9 / RepositoryEditorSheet.swift:121-125); **One decision at a time, partial** (the repository editor stacks identity, location, encryption, credentials and maintenance scheduling in one long form — the plan editor by contrast chunks well into 5 tabs). Passed: grouping, visual hierarchy, single focus per pane, working memory, progressive disclosure. Decision points over 4 visible options: repository kind (8), retention rules (6), check depth (4 — at the limit).

## Emotional Journey

Peak-end is strong: failures end with the cause in restic's own words and two concrete next actions ("Open Plan", "Back Up Now") directly beneath — a failure that ends in a path forward. Valleys are handled: wrong-password and missing-repository are distinct named states ("Waiting for a repository password — nothing is scheduled until one is saved"), and a skipped backup is "held back", never silently lost. High-stakes reassurance is consistently concrete ("If restic is running somewhere else right now, removing its lock can corrupt the repository"). The one unmanaged moment is Priority Issue 4: the unprompted first backup.

## Minor Observations

- **Console confirmation can misquote the command** (ResticConsoleView.swift:59): args are joined with `" "`, so a quoted argument renders unquoted in the confirmation — the confirmation shows text that differs from the confirmed command. Sharpest of the minors; fix soon.
- **"in 0 seconds"** (Formatting.swift:42-45): any timestamp >45 s in the future hits the `min(date, now)` clamp and formats a zero delta. Visible in captures via seed skew, reachable for real via clock corrections.
- **⌘B silently no-ops** when selection is not a runnable plan (RootView.swift:79-93); the menu item stays enabled — disable it contextually.
- `cornerRadius(3)` applies to every stacked chart segment (OverviewView.swift:165), rounding mid-stack segments, not just bar tops.
- ActivityView's full-height Table paints phantom striped rows under the last record (ActivityView.swift:48), at odds with SnapshotTable's content-sizing; reads as loading.
- Diff comparison label "Sep 9, 2026 at 12:30 AM · 33eca070" is ambiguous when both snapshots share a display minute; "2 minutes earlier" would disambiguate (SnapshotDiffView.swift:266-269).
- Tile unit inconsistency: "2 files / 1 file" vs bare "1" for Changed (SnapshotDiffView.swift:126-158).
- Minute picker's hidden 15-minute grid also means "every 6 hours at :20" is inexpressible (PlanEditorSheet.swift:181-184).
- Repository editor's fixed 600×620 frame (RepositoryEditorSheet.swift:79): the SFTP notes push the form taller than the sheet at default font sizes.
- The menu-bar icon's activity swap (SwiftResticApp.swift:217) is a lovely ambient signal nothing documents.
- **Welcome lockup** (RootView.swift:395-402): "SwiftRestic" sits beside, not above, the wrapped mission sentence, vertically centered — the first screen reads unfinished. Stack title above tagline, centered under the icon. (Demoted from A's priority list: first-run cosmetics.)
- **Toolbar grammar differs per pane**: plan pane mixes titled buttons with an icon-only Pause between them (PlanDetailView.swift:26-50); repository pane is all icon-only. One rule: label all primary toolbar actions; icons only for global find/console/refresh. (Demoted: consistency polish.)

## Questions to Consider

1. The dashboard's first tile answers "how many plans are covered" — but the question a backup user opens the app to ask is "when did each plan last succeed, and did it?" Should per-plan freshness (currently hidden in the Protected tile's tooltip) be the dashboard's opening statement, with coverage as the summary?
2. The architecture leans on the console as the escape hatch for what the UI does not cover — is a 720×460 sheet the right stature for the surface the product's philosophy depends on, or should it be a first-class pane with its own history sidebar?
3. Setup forces a two-step ontology — create a repository, then create a plan pointing at it. Would first-run conversion improve if "New Backup Plan" offered to create the repository inline, treating a repository as what it is for most people: a property of the backup rather than a sibling concept?
