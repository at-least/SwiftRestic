---
target: the app UI (Sources/SwiftRestic/Views)
total_score: 35
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 2
target_identity: "file:/Users/newlix/github/at-least/SwiftRestic/Sources/SwiftRestic/Views"
timestamp: 2026-09-09T16-02-05Z
slug: sources-swiftrestic-views
---
Method: dual-agent (A: agent_5587222e · B: agent_55db5d34)

# SwiftRestic UI Critique — Sources/SwiftRestic/Views

*Assessment A reviewed all 17 view files plus the models and services from source; Assessment B independently built the app, captured 18 real screenshots (light + dark, empty + seeded config) and ran the deterministic detector. A's scores were inferred from code; B's rendered captures corroborate them without moving them.*

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 4 | Excellent: bootstrap state, rate/ETA progress, freshness stamps, stale-listing strips, tri-state menu bar icon |
| 2 | Match System / Real World | 4 | restic vocabulary translated, not hidden — glossary, "Applying retention" instead of "forget" |
| 3 | User Control and Freedom | 4 | Cancel for backup/restore/maintenance/console; honest "Hide" while restoring; discard-changes guard |
| 4 | Consistency and Standards | 3 | "Pause Scheduled Runs" vs "Pause Schedule"; "Delete Plan" vs "Remove from SwiftRestic…"; duplicated removal dialog copy; terse "7d" mixed with spelled-out "7 days" |
| 5 | Error Prevention | 4 | Disabled Save with the reason at the button; all-zero retention guard; busy-repository guard; quit confirmation |
| 6 | Recognition Rather Than Recall | 3 | Three click targets whose only affordance is a hover tint; browser keyboard grammar ships only as a tooltip |
| 7 | Flexibility and Efficiency | 3 | Strong ⌘-shortcuts and paste/drop paths; docked for single-select restore, no manual snapshot delete, no Activity search |
| 8 | Aesthetic and Minimalist Design | 3 | Disciplined token system, but the Overview is six stacked blocks — a scroll, not a screen at 1100×720 |
| 9 | Error Recovery | 3 | Good failure pattern at the listing level, but wrong-password gets restic's raw error plus a Retry that cannot succeed |
| 10 | Help and Documentation | 4 | Concepts glossary, Help-menu links, ExpandableCaption pattern, first-run diagnosis of a missing restic |
| **Total** | | **35/40** | **Good — solid foundation, address the weak areas** |

The plateau at 35 plus zero rendered layout, truncation, or contrast defects across 18 captured screenshots means the remaining headroom is behavioral and copy-level, not visual.

## Design Specificity Verdict

**Authored product, not a themed template — but its specificity lives in structure and copy more than in visual identity.** The visual language is deliberately generic-native (accent-following tint, semantic system colors, hairline cards in Theme.swift); what makes it SwiftRestic's own is everywhere the domain shapes the interface: protection-per-plan Overview, retention projection as a consequence sentence backed by a real simulation, "Where is it?"-before-backends repository editor, first-class restic console, glossary sheet owning restic's vocabulary. An unrelated product could not adopt this unchanged. Gap: brand presence is intentionally nil — defensible for a calm trust product, but the window chrome communicates nothing until you read.

**Deterministic scan:** `impeccable detect` on the Views directory exited 0 with zero findings (`[]`). Low weight: the detector's rules target web-markup anti-patterns, so a clean pass on SwiftUI is a null result, not assurance. No false positives.

**Visual overlays:** none — native macOS app, no browser-renderable surface; injection/live-server skipped for that concrete reason. Real-pixel evidence comes from 18 debug-capture screenshots viewed directly.

## Priority Issues

**1. [P1] The first backup ambush.** A new plan defaults to Daily 02:00 and counts as immediately due (BackupPlan.swift:50, 307-310), so a multi-gigabyte upload can start within a minute of Create — and the only warning renders on the Schedule tab while the sheet opens on General (PlanEditorSheet.swift:13, 193-202). On the default golden path, at the exact moment trust is being formed. Fix: restate the one-line warning on the General tab footer (PlanEditorSheet.swift:48-55) or make "Back up now after creating" an explicit toggle. Command: /impeccable shape.

**2. [P1] The password failure loop: unverified saves feed a dead-end Retry.** Upstream: save() probes credentials only when creating (RepositoryEditorSheet.swift:458-460), so a typo'd replacement password is accepted silently and fails one run later. Downstream: the failure surfaces as restic's raw message with a Retry that can never succeed (AppModel.swift:924-935); only missing-password is special-cased (AppModel.swift:894-902); the real fix path (Edit → Test Connection) is undiscoverable. Fix: map restic's wrong-password exit (code 12) to "The password doesn't open this repository — check it in Edit" with an Edit button, and verify changed credentials at Save ("Verify & Save"). Command: /impeccable harden.

**3. [P2] Repository removal silently cancels a running restore.** Removing a repository cancels an in-flight restore (AppModel.swift:448); the strip vanishes, the removal dialog never mentions it (RootView.swift:63), cancellation posts no banner (AppModel.swift:1087-1095). Contradicts the app's headline strength — state honesty enforced in the model. Fix: one sentence in the removal dialog when a restore is active, plus a cancellation banner. Command: /impeccable harden.

**4. [P2] Clickability you can't see: three hover-only surfaces.** Problems tile (OverviewView.swift:225-233), Blobs tile (RepositoryDetailView.swift:160-171), overview problem rows rely on HoverableButtonStyle's 4.5% hover tint (Components.swift:203-217) with no resting cue. In Operate mode the dashboard is scanned, not explored. Fix: persistent chevron or tinted value, as the recent-problems rows already do (OverviewView.swift:517). Command: /impeccable polish.

**5. [P2] The Overview is a scroll, not a screen.** Six stacked full-width sections (OverviewView.swift:22-34) at a 1100×720 default means "is everything protected?" needs scrolling once Protection grows past a handful of plans (unbounded list, OverviewView.swift:153-163). Fix: two-column layout below the Protection card, or cap Protection with a "3 of 5 protected — see all" summary row (pattern previewed at OverviewView.swift:165-174). Command: /impeccable layout.

## Persona Red Flags

**Alex (power user):** single-select restore only (SnapshotBrowserView.swift:22), repeated destination-panel round trips; no manual snapshot deletion (console is the only path); Find Files double-click deliberately does nothing (FindFilesView.swift:155-167); sidebar order fixed (RootView.swift:150-155).

**Sam (accessibility):** chart day-inspection pointer-only (OverviewView.swift:295); Table toggle fallback's "Data view" label may not survive .labelsHidden() (uncertain); hover-only surfaces give low-vision sighted users nothing at rest; browser keyboard grammar tooltip-only (SnapshotBrowserView.swift:112). Strong: dual-coded state, color-independent diff glyphs, banners announced once at root.

**Riley (stress tester):** wrong-password Retry loops forever with no named way out; repository removed mid-restore cancels silently; same-named plans merge into one chart series and color (OverviewMetrics.swift:47; OverviewView.swift:350-361). Good under stress: stale rows survive failed refreshes, exit-10 preserves history, banner queue caps, quit-mid-backup recorded.

## Minor Observations

- Overview warning sentence chains two em-dashes ("Can't read snapshots — Waiting for a repository password — add it in…") and repeats up to three times per screen; split and deduplicate.
- Terse units in prose ("Keep 24h, 7d, 4w, 12m, 3y"; "Check every 7d") mixed with spelled-out "7 days" — pick one register.
- "Every 7 day(s)" programmer pluralization in the repository editor's maintenance stepper.
- Sidebar selection renders neutral gray rather than macOS accent blue — consistent everywhere; decide and document either way.
- PlanDetail's red Delete sits as a plain toolbar button beside Edit (PlanDetailView.swift:58-62) — overflow menu would remove the slip target.
- Welcome's "New Backup Plan…" silently opens the Add-Repository sheet when no repository exists (RootView.swift:497-507); label misdescribes the sheet.
- "Back Up All Plans Now" stays enabled and no-ops with zero plans (SwiftResticApp.swift:238-243).
- Activity has no search or per-plan filter despite a 2000-record ceiling (SettingsView.swift:97-99; ActivityView.swift:48).
- Tooling debt: the planRetention capture override lands on General and the empty-config guard blocks pane selection (RootView.swift applyCaptureOverride) — future Retention-tab captures need the hook fixed.

## Questions to Consider

- Would one headline sentence on the Overview — "Everything is protected. Last backup 2 hours ago; one warning this week." — answer the 5-second check-in better than six cards, with cards demoted to detail?
- Restore is the only moment a backup pays off, yet it lives two clicks behind a table row. What if restore were the hero — drag to Finder, or a recent-files quick-restore list on the Overview?
- Should SwiftRestic generate a printable recovery sheet (repository string + password hints) at creation, the way disk utilities offer recovery keys?
- What is the projection-engine equivalent for prune — "this prune will take about 4 hours and reclaim ~120 GB" — before the user commits?
