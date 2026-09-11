---
target: the app UI (Sources/SwiftRestic/Views)
total_score: 35
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 2
target_identity: "file:/Users/newlix/github/at-least/SwiftRestic/Sources/SwiftRestic/Views"
timestamp: 2026-09-11T00-47-14Z
slug: sources-swiftrestic-views
---
Method: dual-agent (A: agent_0d8647e3-b4d7-45f5-a808-41086191253b · B: agent_9ae95923-43e1-41be-a5c9-d1da5f0cb9bc)

# SwiftRestic UI Critique — run 17 (Sources/SwiftRestic/Views)

*A reviewed all 17 view files plus the App/Services sources unanchored, with pre-registered evidence bars for a 4 and a 2 on every heuristic before scoring. B independently ran the detector, built, ran all tests, and produced runtime/pixel evidence against fixture configs (unconfigured launch, nine surfaces light+dark, live tray faces and menu, restic-absent state, standalone MenuBarLogo renders). Neither assessment saw the other's output or any prior critique archive. Every load-bearing claim was re-verified in source during synthesis; two of A's scores were adjusted on named falsifiers (Visibility 4→3, Flexibility 4→3). Browser inspection does not apply (native app); rendered-app evidence substitutes.*

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | P1: the Protection card answers "are you protected?" from the last snapshot only, so a failing plan sits under a green check while the Problems tile beside it is red. Away from that card, status is excellent — tray faces pixel-verified this run |
| 2 | Match System / Real World | 3 | Falsifier for 4: every restic verb translated at its point of use. Activity's Kind column prints raw `Forget`/`Initialize` (ActivityView.swift:71); the glossary definition lives only in Help |
| 3 | User Control and Freedom | 4 | Cancel everywhere; consequence-enumerated confirms; dirty-guarded editors; quit dialog's safe answer owns Return |
| 4 | Consistency and Standards | 3 | Falsifier for 4: one name per concept. The pause concept has three: "Run on schedule" (PlanEditorSheet.swift:148), "Pause Schedule" (PlanDetailView.swift:39), "Pause Scheduled Runs" (RootView.swift:243) |
| 5 | Error Prevention | 4 | Disabled Save names its reason; menu-bar-off strand confirmation; all-zero retention guard; console dry-run hints |
| 6 | Recognition Rather Than Recall | 4 | rclone remote suggestions, prefilled exclude patterns, console history with ↑/↓ and draft return |
| 7 | Flexibility and Efficiency | 3 | Falsifier for 4: any one of multi-select restore, Find-result→snapshot jump, or tray→plan navigation. All three verified absent today (SnapshotBrowserView.swift:22, FindFilesView context menu, MenuBarContentView.swift:57–61) |
| 8 | Aesthetic and Minimalist Design | 4 | One token system, one Card/Tile/Banner vocabulary, depth on demand via ExpandableCaption |
| 9 | Error Recovery | 3 | Falsifier for 4: stored-secret failures diagnosed truthfully. Keychain denial is swallowed (`try?`) and reported as a missing password (SecretStore.swift:19–21); otherwise superb exit-code mapping |
| 10 | Help and Documentation | 4 | Glossary reachable from the Blobs tile itself; deep links into Privacy & Security and Login Items |
| **Total** | | **35/40** | **Good — top of the band** |

**Movement from 35 (prior scores read after A's were fixed).** A's unanchored card totaled 37; synthesis moved Visibility 4→3 because a fix-before-release defect lives in the app's central status answer — a 4 can't stand next to a P1 — and Flexibility 4→3 because the three accelerator absences that cost this point in the last two runs were re-verified absent in source today. The flat number hides the real story: the tray — subject of the last three runs' P1s — is finished and verified at the strongest level available, and every finding this run is new.

## Design Specificity Verdict

**Authored for restic on a Mac — strongest specificities re-confirmed on re-read.** restic's exit codes map into distinct UI truths with fixes named before restic's own words (ResticError.swift:29–67); the scheduler is shaped by restic's lock model, holding plans back rather than skipping (AppModel+Scheduling.swift:16–40); retention is projected by simulating `forget`'s bucket rules and surfaced as the user's actual question — "≈ N snapshots would survive, reaching back about M days" (PlanEditorSheet.swift:283–290). The menu bar is treated as the product's only always-visible surface with opinionated precedence (running > problem > unconfigured), and the running pulse's Reduce Motion still-face differs from idle in both plates — numerically verified this run (Δ166/Δ102 per-channel at 10×). Category-interchangeable residue is small: the Alerts tab and stat-tile row could appear in any monitoring app; Activity's raw Kind verbs are the one unpolished leak.

**Deterministic scan:** `impeccable detect --json Sources/SwiftRestic/Views` → exit 0, `[]`, zero findings — the third consecutive null result. The ruleset targets web-markup anti-patterns and has nothing to match on SwiftUI; a clean pass remains a null result, not assurance.

**Visual evidence (no browser applicable — native app).** B rendered the real app against fixture configs: unconfigured first launch light+dark; nine surfaces light+dark with real content (2.5 TB repo stats, failed run with red row, editors, console with history); the tray verified live — problem `!`, unconfigured `?`, idle logo, all other status items byte-identical across kill-diff — and, by clicking the real status item, the unconfigured menu answering "No repository set up yet / Add a Repository…" with no failure line anywhere (AX description confirms precedence). The restic-absent state revalidates correctly: the console selection lands back on Overview with "Can't read snapshots — Could not find the restic executable" + Retry. 254 tests in 45 suites pass, including the real-restic integration suite (52 s). Not reproduced at runtime, with attempts recorded: problem/idle tray menus (launch-method AX artifacts, documented), live Reduce Motion toggle (TCC-refused; standalone render of the real MenuBarLogo substitutes), File-command window opening (input routes failed). All 81 artifacts: /tmp/swiftrestic-run17-b/.

## Overall Impression

The number is flat for the sixth run; the app is not. Everything the last three runs flagged about the tray — the only always-visible surface — is closed and now verified in pixels and in the live menu, which raises the evidence quality more than the score. What's new cuts deeper than wiring: the app's core promise is trust, and this run found two places where the interface states something untrue — a green "protected" check over failing backups, and a Keychain denial reported as a missing password. Both are fix-before-release defects precisely because the app otherwise earns the trust it then betrays. Biggest opportunity: make the Protection card and the secret path as honest as the rest of the app already is.

## What's Working

1. **The tray's story is finished and proven.** Three faces pixel-verified live (glyph widths ≈2 pt / 7 pt / 16 pt measured), unconfigured-beats-problem verified in the real open menu and AX tree, Reduce Motion still-face numerically distinct from idle (Δ166 top / Δ102 bottom plate at 10×), and the menu's first line answers the state that summoned it. The hardest surface in a menu-bar app is now its best evidence.
2. **Consequence-exact destructive dialogs sourced from the model.** `removalConsequences` enumerates cancellations clause by clause (AppModel+Repositories.swift:51–85); the quit dialog builds from `quitInterruptions`; the delete-plan dialog re-words when a run is in flight. The wording *is* the code path — it cannot drift.
3. **The honest-unknown pattern.** "—" tiles with visible reasons, two different empty messages for "none yet" vs "none from this plan," stale listings kept beside a failure strip instead of erased. For a backup app, never mistaking "unknown" for "nothing" is the core trust promise — kept systematically everywhere except the two P1s below.

## Priority Issues

1. **[P1] The Overview Protection card shows "protected" for a plan whose latest run failed.** `isProtected` derives only from the newest snapshot (`latest != nil`); run outcomes are never consulted (OverviewView.swift:138–165). A plan failing every night wears the green checkmark with "Latest backup 2 days ago" two inches above the red Problems tile. For a backup tool this is a false safety signal — the canonical support ticket: "the app said protected while my backups had failed for weeks." Fix: consult the latest run record in `protectionRows`; when `lastRunAt > lastSuccessAt`, render the warning symbol/hue with the failure's age. → `/impeccable harden`
2. **[P1] Keychain denial is misdiagnosed as "no password stored," and a failed secret save still dismisses the editor as success.** `try?` swallows the denial at SecretStore.swift:19–21, so a denied read surfaces as "Waiting for a repository password" (AppModel+Snapshots.swift:43–51) and re-entry then "doesn't open this repository" — wrong twice. A failed save does post an error banner, but `upsert` persists the repository anyway and the sheet closes (AppModel+Repositories.swift:8–14), landing the user in "Waiting for a repository password — nothing is scheduled" purgatory (RepositoryDetailView.swift:304–312). Source-verified, not runtime-reproduced. Fix: propagate KeychainError out of `load`, give it its own ResticError copy, keep the sheet open when the secret write fails. → `/impeccable harden`
3. **[P2] The first backup is invisible on the screen the first-timer is looking at.** After Create Plan, selection stays nil and Welcome renders no banner strip (RootView.swift:330–333, 387–422); with success notifications default-off (ConfigStore.swift:8), the promised "first backup within a minute" (PlanEditorSheet.swift:60–64) starts and completes with no in-window signal. Fix: render the banner queue on Welcome and/or select the new plan after first creation. → `/impeccable onboard`
4. **[P2] The only remedy for the missing prerequisite is a shell command.** "Install it with `brew install restic`" (RootView.swift:288, ResticError.swift:24–25, confirmed in B's captured banner) offers no copy affordance, no link, and no explanation of Homebrew — to the exact audience that chose a GUI because it doesn't live in the terminal. Fix: a "Copy install command" button plus a link to restic's install docs next to the Settings path-override escape hatch. → `/impeccable clarify`
5. **[P3] The pause concept has three names.** "Run on schedule" / "Pause Schedule" / "Pause Scheduled Runs" (PlanEditorSheet.swift:148, PlanDetailView.swift:39, RootView.swift:243). Pick one phrase family. → `/impeccable clarify`

## Persona Red Flags

**Jordan (confused first-timer):** hits the brew wall before the product — the first remediable screen offers a terminal incantation with no affordance or explanation (RootView.swift:288). After Create Plan, the sheet closes onto a silent Welcome; Jordan, who doesn't guess, can't confirm the "first backup within a minute" promise was kept. Exclude presets arrive prefilled with no explanation of what a pattern is. Otherwise served unusually well: "New Backup Plan…" reroutes to repository creation with a one-line reason, "Blobs" is defined one click from the word.

**Riley (deliberate stress tester):** 1000 snapshots handled (capped scroll, month-grouped diff picker, honest "walks each one" caption + Stop); non-ASCII paths clean; restic-missing is the best-covered failure in the app. Three cracks: the Overview failure row's "Retry" re-reads snapshots rather than retrying the backup (OverviewView.swift:218–224) — the label promises more than it does; numeric snapshot columns are unsortable and the filter matches only ID/date, so "largest snapshot this month" is inexpressible; and the Keychain-denial path makes the app lie twice in a row — Riley concludes the backup tool can't be trusted, which is the real data-loss event.

## Minor Observations

- Snapshot refreshes are uncancellable (bounded by the 300 s ceiling, AppModel+Snapshots.swift:9); `unlockRepository` runs fire-and-forget with no spinner.
- Settings shows the resolved restic path twice — the field's grey prompt duplicates the "Using" row (SettingsView.swift:118–131).
- Console sidebar fixed at 230 pt; console output is one Text in a ScrollView — enormous outputs may get heavy (UNVERIFIED at runtime).
- Browser list offers no sorting and no jump-to-path; HookEditor has no test-run affordance and no keyboard reorder.
- Whole-snapshot vs per-node restore semantics are documented in the README but never in the restore dialogs.
- The tray's "Back Up Now" list grows one button per plan, unbounded (MenuBarContentView.swift:57–61).
- Operational: the installed /Applications/SwiftRestic.app (Release, Sep 10 16:09) predates commit c0a3ab2 — the release you run daily is missing the last four fixes; rebuild/reinstall when convenient.
- Disclosure from B: three system-wide ⌘W keystrokes were sent while attempting the File-command test and may have closed IDE editor tabs.

## Questions to Consider

- What if protection were defined as "the most recent attempt succeeded" rather than "a snapshot exists"?
- Should SwiftRestic own the install moment — copyable command, Homebrew explainer, link — instead of renting it from `brew`? Or vendor restic outright?
- The tray's problem face clears 7 days after the last failure; a Mac that silently stops backing up decays to a quiet idle logo. Should the UI carry a "no successful backup in N days" face instead of leaning on Healthchecks for the dead-man's-switch case?
- The console supplies credentials "for you" — meaning a user can't run a one-off command against a different password. Documented limitation or future feature — should the pane say which?
