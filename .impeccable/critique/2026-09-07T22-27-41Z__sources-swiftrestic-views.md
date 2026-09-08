---
target: SwiftUI views (Sources/SwiftRestic/Views)
total_score: 33
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 3
target_identity: "file:/Users/newlix/github/at-least/SwiftRestic/Sources/SwiftRestic/Views"
timestamp: 2026-09-07T22-27-41Z
slug: sources-swiftrestic-views
---
# Critique — SwiftRestic SwiftUI views (Sources/SwiftRestic/Views)

Method: dual-agent (A: agent_9bf71a5f · B: agent_dcfc8a8b) — source-level assessment; no live visuals (native macOS target; the backup app was deliberately not launched to avoid state changes on the user's machine).

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Superb during runs (progress card, sidebar phase text, menu bar); silent after them — no in-app success signal, failures surface two navigations away. |
| 2 | Match System / Real World | 4 | restic jargon systematically translated: glossary, "waiting for password" honesty, exit-3 as "Completed with errors". |
| 3 | User Control and Freedom | 3 | Cancel everywhere on runs; but deletions are confirm-only with no undo, Clear History is permanent. |
| 4 | Consistency and Standards | 4 | One token source (Theme.swift), shared components, identical sheet footer grammar with Esc/Return on every sheet. |
| 5 | Error Prevention | 4 | Retention projection with all-zero guard, console destructive-command interlock, refuses to save unreachable repos. |
| 6 | Recognition Rather Than Recall | 3 | Live "restic will use" preview, summary lines; but the 5-tab plan editor gives no cross-tab summary. |
| 7 | Flexibility and Efficiency | 3 | ⇧⌘B / ⇧⌘F / ⌘R and context menus; but File ▸ New is removed, snapshot browsing is double-click only, restore is single-select. |
| 8 | Aesthetic and Minimalist Design | 3 | Disciplined in source (no clutter, direct value labels); rendered hierarchy/contrast not verifiable from source — palette comments admit some light-mode series sit below 3:1, mitigated by the table view. |
| 9 | Error Recovery | 3 | Errors are selectable, pinned to context, named with cause (brew command in the restic-missing banner); but a failed manual backup is easy to miss and raw restic text is common. |
| 10 | Help and Documentation | 3 | Inline captions everywhere plus a glossary — but the glossary is reachable only from Help, never at the moment of confusion. |
| **Total** | | **33/40** | **Good — address weak areas, solid foundation** |

All ten heuristics scored; none n/a (heuristic 8 partially code-limited).

## Design Specificity Verdict

**Authored in semantics and copy; category-interchangeable in chrome.**

**LLM assessment:** The interface consistently names *true states* rather than generic ones — exit 3 becomes "Completed with errors", a password-less repository is "Waiting for a repository password — nothing is scheduled until one is saved", quitting mid-run is distinguished from a user cancel. Nearly every risky control carries a one-sentence consequence caption (prune's exclusive lock, SFTP's GUI-launch limitation, why Healthchecks needs a start ping). An unrelated Mac app could reuse the card-and-tile chrome unchanged; it could not reuse these sentences. The second authored system is plan-colour identity: a stable palette slot (FNV-1a fallback) follows each plan into the sidebar dot, the stacked 30-day chart and the Next-runs rows, surviving renames and restarts. The visual language itself — tinted icon chips, hairline cards, rounded tabular numerals — is well-executed native-plus-cards but could front any utility app. The app is calm to a fault: nothing on any surface carries the product's core promise ("your data is safe"). Missed opportunity, not failure.

**Deterministic scan:** `impeccable detect --json Sources/SwiftRestic/Views` exited 0 with zero findings. A control probe (a Swift file seeded with an advisory-rule trigger) also returned zero, so the detector demonstrably reports nothing on Swift source — treat "clean" as "nothing reported", not "verified clean". The mechanical evidence of record is Assessment B's labeled fallback pass: 0 hardcoded colors in views (the only literal is `Color.accentColor`, an alias of `Theme.tint`); 25 SF Symbol images of which exactly 2 icon-only controls lack accessibility labels (SnapshotBrowserView.swift:45 go-up chevron, Components.swift:113 banner-dismiss xmark); 9 accessibility labels across 17 files; both Swift Charts charts carry no explicit accessibility text (mitigated on the volume chart by the table alternative); 15 font literals outside Theme (2 true magic sizes: RootView.swift:352, :417); 20 fixed-width frames; 39 numeric paddings vs 13 `Theme.Space` uses (no constant exists for card-inner 12); 1 force-unwrap (ConceptsView.swift:83, static URL); 7 confirmationDialogs covering every destructive action except one gap — SettingsView.swift:186–189 removes a notification channel instantly, unconfirmed; the menu bar menu (MenuBarContentView.swift:23–26) is the one surface without a zero-items empty state. False positives: none (nothing reported).

**Visual overlays:** Not available — native SwiftUI target with no DOM; injection is impossible by construction, so no user-visible overlay exists for this run. The fallback signal is the mechanical pass above.

## Overall Impression

A quietly excellent app that is quietly failing at the one thing it exists to do: reassure. The copy discipline is the best I have seen in a backup tool — every dangerous moment is explained in plain English, every status tells the truth. But the emotional ledger is inverted: failures are loud (notification, Problems tile, Activity) while successes are mute (a vanished spinner), even though a backup product's whole job is making "your data is safe" felt. The single biggest opportunity is to make completion and failure equally visible on the surfaces users actually stare at — the sidebar and the plan page.

## What's Working

1. **Copy as the trust instrument.** Every risky or confusing control explains its consequence in one sentence of plain English (prune locking, retention projection, SFTP agent limitation, hook privilege warning). This is rare, product-specific, and precisely right for a high-stakes domain — it reads like an engineer who has been burned, writing for users who will be.
2. **Honest status semantics, never colour alone.** Exit 3 as "Completed with errors", password-missing as a waiting state, quit-vs-cancel distinguished in records; the diff sheet's glyphs carry meaning with colour as reinforcement only; the volume chart ships a table alternative because the palette's own comments admit light-mode contrast limits.
3. **The retention projection.** "≈ N snapshots would survive, reaching back about X days" (PlanEditorSheet.swift:175–189) converts bucket arithmetic into an outcome — the most reassuring control in the app, and the right answer to the hardest question retention UIs pose.

## Priority Issues

1. **[P1] Success moments are structurally silent.** No banner or state change on backup completion (AppModel.swift:461–505; `notifyOnSuccess` defaults false, ConfigStore.swift:8); restore success renders a banner only on the main-window panes the sheet is covering (AppModel.swift:756–761), so SnapshotBrowserView.swift:109–136 and FindFilesView.swift:147–176 end in a vanished spinner. *Why:* the two moments a user most needs to hear "your data is safe / your file is back" — the peak of the peak-end rule — are spent on nothing. *Fix:* inline success state inside restore sheets; a completion banner (or transient toast) on plan completion; consider a one-time first-success notification per plan. *Suggested command:* `/impeccable delight`.
2. **[P1] A failed backup leaves no trace on the plan's own surfaces.** Sidebar row subtitle ignores the last failure (RootView.swift:331–339); plan page tiles show last *success* only (PlanDetailView.swift:80–85); no failure badge anywhere on the plan. *Why:* users watch Back Up Now fail, see the progress card vanish, and the UI reverts to calm; in backup software, under-reporting failure is the cardinal sin. *Fix:* a "Last run: Failed, 2 min ago" outcome line on the plan page and a failure tint on the sidebar row (the data already exists in `model.configuration.runs`). *Suggested command:* `/impeccable polish`.
3. **[P1] Snapshot browser is a keyboard/VoiceOver dead end.** Directories open only via `onTapGesture(count: 2)` (SnapshotBrowserView.swift:102) — no Return handler, no accessibilityAction, no button; the go-up chevron is icon-only without a label (SnapshotBrowserView.swift:45). *Why:* a VoiceOver or keyboard-only user can select rows but cannot descend into any folder; the restore path is mouse-only for them. *Fix:* make the row a Button (keep double-click as the mouse idiom); label the chevron. *Suggested command:* `/impeccable audit`.
4. **[P2] No keyboard path to create anything — File ▸ New is removed.** `CommandGroup(replacing: .newItem) {}` (SwiftResticApp.swift:158); creation lives only in the sidebar footer Add menu and WelcomeView. *Why:* ⌘N is the native expectation for "new thing"; its absence is felt every session, and the disabled "New Backup Plan…" entries give no reason (repo must come first — implied, never stated). *Fix:* restore File ▸ New Repository / New Backup Plan with ⌘⌥N / ⇧⌘N wired to the same sheet state; state the sequencing on the disabled items. *Suggested command:* `/impeccable polish`.
5. **[P2] The glossary exists but never where confusion happens — plus ghost UI.** ConceptsView opens only from Help (SwiftResticApp.swift:159–162), never from the prune dialog or the "waiting for password" label; PlanEditorSheet.swift:74–81 presents a "Snapshot tags" section containing no control; the banner at AppModel.swift:282–288 references an "Extra environment" field no view renders. *Why:* Jordan meets "prune" inside a destructive confirmation with no learn-more; dead copy referencing invisible UI erodes the trust the app works so hard to build. *Fix:* "What is pruning?" links from destructive dialogs (opening ConceptsView pre-scrolled); replace the tags section with caption text or a real editor; delete or implement the Extra environment reference. *Suggested command:* `/impeccable clarify`.

## Persona Red Flags

*(Casey, the mobile persona, is not applicable — this is a native desktop app.)*

**Alex (impatient power user):** No ⌘N / File ▸ New — creation is menu-click only (SwiftResticApp.swift:158). Snapshot browser navigation is double-click with a single Go-up button; no path entry, no breadcrumbs (SnapshotBrowserView.swift:42–48, :102). Restore is single-select everywhere — no batch restore from Find results. SnapshotTable is not sortable and has no per-row context menu — actions are two small buttons per row (PlanDetailView.swift:194–237). Sources can only be added via NSOpenPanel — no typing, no drag-and-drop (Components.swift:334–343). On the plus side: ⇧⌘B / ⇧⌘F / ⌘R, console History, Esc/Return on every sheet.

**Sam (VoiceOver + keyboard-only):** Cannot descend into snapshot folders at all without a mouse (Priority 3). OperationProgressView's progress has no label tying it to its task (Components.swift:264); StatTiles read caption and value as separate elements (Components.swift:134–162); both charts expose no explicit accessibility values — the repository-size chart has no table fallback either (OverviewView.swift:279–302); the banner dismiss is an unlabelled xmark (Components.swift:113). Exactly 9 accessibility labels across 17 view files — the good ones (ActivityView icons, hook toggles) prove the team knows how; coverage is just thin.

**Jordan (confused first-timer):** Meets "prune" and "forget" inside destructive dialogs with no learn-more link — the glossary hides in Help (RepositoryDetailView.swift:62–100). The "Snapshot tags" section looks like a setting and controls nothing (PlanEditorSheet.swift:74–81). Disabled "New Backup Plan…" gives no reason (RootView.swift:403–405, :167–168). The first backup completes with no in-app confirmation anywhere — Jordan must notice a sidebar caption change. Prune's result is restic's raw log text in Activity (AppModel.swift:959–962) — an expert artifact with no plain-language verdict. On the plus side: the guided Welcome, refused-unreachable saves, inline test-connection status, and the retention projection are genuinely first-timer-friendly.

## Minor Observations

- SettingsView.swift:186–189 — notification-channel Remove is instant, unconfirmed, and lacks a destructive role.
- MenuBarContentView.swift:23–26 — the menu bar menu has no zero-plans empty state (the one surface without one; 16 ContentUnavailableViews elsewhere).
- ChartPalette.swift duplicates Theme's status colours without referencing them (deliberate per comments, but a drift risk — single-source them).
- 39 numeric `.padding(` literals vs 13 `Theme.Space` uses; no constant exists for the card-inner 12 used 17 times — add one (`layout` pass).
- Two different sheet sizes for sibling editors: repository 600×660 vs plan 640×580.
- The banner is a single slot (AppModel.swift:73) — a second event overwrites the first; two quick failures show only the latest.
- Disabled Find/Console toolbar buttons don't say why (RootView.swift:80–85); the restic-missing banner explains only one of the causes.
- ConceptsView.swift:83 — force-unwrap on a static URL literal (the only one in views).
- StatTile's `minimumScaleFactor(0.6)` silently shrinks long values (Components.swift:155); the chart callout clamps only its left edge (OverviewView.swift:219).
- No `#Preview` blocks anywhere; layout verification depends on the debug capture harness (README documents a safe self-photographing capture mode — worth wiring into future critique runs for real visual evidence).

## Questions to Consider

- The app proves backups *happen* but never proves restores *work* — should there be a first-class "verify restorability" moment (test-restore of a random file, or a "last restore verified" tile), given that a backup tool's real promise is restorability, not run history?
- Should the first successful backup per plan trigger a one-time, designed moment of reassurance — regardless of `notifyOnSuccess` — or does that conflate "first run" with "trust earned"?
- If a plan fails three consecutive times, should the sidebar row itself become a persistent problem state, or is routing through Overview ▸ Problems the right amount of alarm for a tool whose users check it rarely?
- The restic console offers arbitrary destructive commands behind one confirmation — is that consistent with an app that refuses to save an unreachable repository? Would requiring the repository name to be typed for `prune`/`forget` be protection or theatre?
- Compare answers "what changed between two snapshots", but the everyday question is "when did this file disappear?" — should Compare walk backward automatically until the path flips from present to absent, pairing with Find Files as a "when did I lose it" instrument?
