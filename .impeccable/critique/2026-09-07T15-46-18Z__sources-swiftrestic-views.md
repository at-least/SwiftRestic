---
target: the SwiftRestic app UI (all panes)
total_score: 27
max_score: 40
na_heuristics: 
p0_count: 2
p1_count: 1
target_identity: "file:/Users/newlix/github/at-least/SwiftRestic/Sources/SwiftRestic/Views"
timestamp: 2026-09-07T15-46-18Z
slug: sources-swiftrestic-views
closed: true
---
# Impeccable critique — SwiftRestic app UI (Sources/SwiftRestic/Views)

Method: dual-agent (A: agent_7525527f · B: agent_c25d61ba)

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Strong (sidebar spinner, OperationProgressView, banners) but "Protected 0 bytes" reports the opposite of the true state. |
| 2 | Match System / Real World | 3 | restic jargon well glossed, but "2 pattern(s)" / "3 new, 2 changed" programmer-plurals leak through. |
| 3 | User Control and Freedom | 2 | Clear History, Delete Plan and Prune Now are instant and irrevocable; Esc missing on Find/Browser sheets. |
| 4 | Consistency and Standards | 2 | Confirmation asymmetry: the console confirms destructive commands, the GUI's own Prune Now doesn't. |
| 5 | Error Prevention | 3 | Retention zero-rule warning, password no-recovery warning — yet Prune Now and Restore Entire Snapshot have no gate. |
| 6 | Recognition Rather Than Recall | 3 | Sidebar subtitles, config summary, hook-variable DisclosureGroup good; retention state invisible until the editor opens. |
| 7 | Flexibility and Efficiency | 2 | Back Up Now in 3 places, console history — but no keyboard shortcut for backup, no Activity filters, Find is single-select. |
| 8 | Aesthetic and Minimalist Design | 3 | Disciplined and native in both modes; zero-value charts render as broken-looking floating "0 bytes" text. |
| 9 | Error Recovery | 3 | Error banners and ContentUnavailableViews with selectable text are good; failure rows in Overview are dead ends. |
| 10 | Help and Documentation | 3 | Inline microcopy is genuinely excellent; nothing links to restic docs for the console/Find power features. |
| **Total** | | **27/40** | **Acceptable** |

## Design Specificity Verdict

Borderline. The craft system is authored — Theme tokens, a disciplined Card/StatTile/SheetHeader kit, ChartPalette with documented CVD/contrast rationale, honest microcopy. But the composition is the category's default template (sidebar + 4-KPI strip + stacked cards) applied identically to Overview, Plan and Repository panes. Product character survives only in fragments (lowercase "restic console", monospaced command field, Welcome view). Nothing on the dashboard expresses "this is the app that keeps your data safe" — it expresses "this is a dashboard".

Deterministic scan: `impeccable detect --json` over Views and whole Sources → 0 findings (exit 0), cross-checked with --no-config. The detector is web-oriented; zero findings mean no rule fired, not zero issues. No false positives to report. Browser overlay injection: skipped — native macOS app, no URL/dev server exists.

## Overall Impression

A disciplined, honest, native app with genuinely excellent microcopy and chart integrity, wearing a dashboard skeleton that could belong to any backup utility. The single biggest opportunity: the Overview — the trust surface of a trust product — reports zeros and dead ends exactly where a first-time user needs verified safety.

## What's Working

1. Microcopy voice (RepositoryDetailView:179, ResticConsoleView:83, retention zero-rule warning): honest, specific, calm — explains consequences instead of hedging. This is the app's personality.
2. Chart integrity (ChartPalette.swift, OverviewView:99-110): status colors quarantined, fixed CVD-safe order, legend + table alternative for sub-3:1 series, monospaced digits, selection callout — accessibility reasoning written into source.
3. Consistent native shell: token-driven cards hold up identically in light and dark across all 12 captures; sheets carry proper cancel/default shortcuts; focus lands in the pattern field on open.

## Priority Issues

1. **[P0] Zero-state metrics render as confident zeros** — "Protected 0 bytes" (OverviewView.swift:59-63 computes from loaded snapshot lists; a fresh repo is "no snapshots yet", rendered as "0 bytes protected") and floating "0 bytes" repository-size rows. In a trust product this reads as data loss. Fix: distinguish "no snapshots yet / measuring" from a real 0; hide zero-width bars until stats exist.
2. **[P0] Destructive-action asymmetry** — Prune Now (RepositoryDetailView.swift:39) and Clear History (ActivityView.swift:67-69, runs.removeAll()) execute instantly; the restic console — the expert surface — confirms destructive commands and suggests --dry-run. Fix: same confirmation treatment; Delete Plan names what's at stake.
3. **[P1] Failures are dead ends** — "Failures (7 days)" tile and "Recent problems" rows aren't navigable; Activity has no outcome filter. Fix: problem rows open Activity pre-filtered; add an outcome filter.
4. **[P2] "Last backup: Never" trusts only the plan field** (PlanDetailView.swift:77-81). Real successful runs stamp lastSuccessAt (test suite proves it), so the contradiction needs config edits/imports to occur — a robustness nit, not a common-state lie. Fix: derive from run history or relabel precisely.
5. **[P2] Zero/one-value chart states look broken** — single-bar data chart, zero-width repository-size bars. Shares the same zero-state root cause as issue 1. Fix: empty/insufficient-data states with a CTA.

## Persona Red Flags

- **Alex (power user)**: no keyboard shortcut for Back Up Now (only sheet cancel/default and ⌘Q exist); Maintenance menu is mouse-only; Activity unfilterable — finding the seeded failure means scrolling 60 rows; Find is single-select (FindFilesView.swift:15) so restoring several files means repeated round-trips; no console up-arrow recall; Esc doesn't close Find/Browser sheets.
- **Sam (a11y)**: the chart/table segmented control is icon-only with labelsHidden() and no accessibility labels (OverviewView.swift:104-110) — VoiceOver gets an unlabeled control guarding the only non-visual path to chart data; Activity status icons rely on .help tooltips; the sidebar restic-missing warning is a hover-only tooltip icon (RootView.swift:135-139).
- **Riley (stress tester)**: Prune Now's point of no return is one mis-click; Clear History destroys the 60-run audit trail instantly; Restore Entire Snapshot picks a destination with no overwrite warning; a confirmed destructive console command killed silently when the sheet closes (ResticConsoleView.swift:28-30, by design).

## Minor Observations

- Programmer-plurals: "2 pattern(s)" (PlanDetailView:114), "match(es) across snapshot(s)" (FindFilesView:159), "change(s)" (SnapshotDiffView:293).
- Snapshots empty state is bare text; a "Back Up Now" CTA would convert the dead end.
- Sidebar "Add" disables "New Backup Plan…" with no reason shown.
- Plan/Repository detail leave the lower half empty at default height; PlanEditorSheet fixes 640×580 and retention+hooks are tight in it.
- Welcome view's gradient icon tile is richer than the app-wide chrome.
- Activity "Detail" column duplicates the failure message shown in the detail panel.

## Questions to Consider

1. If the KPI strip said "Protected: No" instead of "Protected 0 bytes", would you ship it? Why is the byte-count version shippable?
2. Should a GUI whose product is trust in irreversibility have a destructive path with fewer gates than its own terminal?
3. What on the Overview communicates *verified* safety rather than mere activity?
