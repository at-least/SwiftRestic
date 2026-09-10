---
target: the app UI (Sources/SwiftRestic/Views)
total_score: 35
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 0
target_identity: "file:/Users/newlix/github/at-least/SwiftRestic/Sources/SwiftRestic/Views"
timestamp: 2026-09-10T22-00-08Z
slug: sources-swiftrestic-views
---
Method: dual-agent (A: agent_00ef540f-7ccd-4825-adbb-2f7cde346a2d · B: agent_bf9c6d1e-a663-4fe5-bc18-4c7e87f0a945)

# SwiftRestic UI Critique — Sources/SwiftRestic/Views (run 16)

*Assessment A reviewed all 17 view files plus the App/Services sources they draw on, unanchored, with the ~250-line uncommitted working-tree diff read as the live work under review. Assessment B independently ran the deterministic detector, compiled `MenuBarLogo.swift` standalone and rendered its three faces to real pixels at 1×/2×/10× with numeric per-plate measurements, built the app and ran all 249 tests (all passed), launched the built binary against an empty config directory to verify the unconfigured first-launch state on a real status item with a real open menu, and wired a real restic fixture (3 snapshots, 1 failed run inside the 7-day window) to pixel-sample the Overview Problems tile against the Recent problems card in light and dark, and — in a follow-up pass — clicked the new “Add a Repository…” menu item live with the main window closed to verify the editor sheet is actually delivered (it was). Neither assessment saw the other's output or any prior critique archive; heuristic scores were fixed from the raw evidence before the previous run's snapshot was consulted.*

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Two of this run's P2s are defects of the tray itself — the only always-visible surface: a Reduce Motion user gets no distinct running face at all, and the `?` icon can sit over a menu line announcing a failure. Away from the tray, status is superb: elapsed-time counters, freshness stamps, and all four tray faces verified live in pixels |
| 2 | Match System / Real World | 4 | restic's own vocabulary taught in place, exit code 12 maps to a specific fix; plain verbs where restic's words aren't the truth |
| 3 | User Control and Freedom | 4 | Cancel everywhere; the quit dialog's safe answer owns Return; "Hide" during restore hands progress to the app strip instead of implying cancel |
| 4 | Consistency and Standards | 3 | The bare `?`/`!` tray pair is unconventional in a menu bar and lighter than the in-app filled-triangle trouble convention; toolbar disables Console with no repositories while the sidebar entry stays enabled |
| 5 | Error Prevention | 4 | Consequence-stating confirmations, dry-run hints for destructive console commands, all-zero retention guard |
| 6 | Recognition Rather Than Recall | 4 | The `?` face is now answered in its own menu (runtime-verified); rclone remote menu, repository-string preview, console recall all hold |
| 7 | Flexibility and Efficiency | 3 | Real ⌘-shortcuts throughout, but no multi-select restore, no jump from a Find result to its snapshot, and the tray menu can't open a specific plan's pane |
| 8 | Aesthetic and Minimalist Design | 3 | Overview stacks Protection + 4 tiles + 4 cards; the tile row restates sidebar inventory, and several tiles can sit at "—" simultaneously |
| 9 | Error Recovery | 4 | First-sentence truncation keeps the verdict visible, Retry keeps the failure on screen, stale-vs-failed listings stay distinguished |
| 10 | Help and Documentation | 3 | Concepts guide + ExpandableCaption pattern strong; the tray's four faces are taught only in one Settings caption, and the glossary is reachable from just two places |
| **Total** | | **35/40** | **Good — solid foundation, address the weak areas (top of the band)** |

**Movement from 35 (read after scoring, per score-first discipline).** Assessment A's unanchored card totaled 36; synthesis adjusted Visibility 4→3 because two of this run's priority findings are defects of the tray itself — a 4 can't stand next to them. Net vs run 15: flat total, better composition. Both P1s are gone, verified at the strongest available level: the `unconfigured` dead end is runtime-verified fixed (real status item wearing `?`, real menu reading "No repository set up yet" + "Add a Repository…"), and the pulse alternation is pixel-verified fixed (every plate differs between every pair of frames; tightest margin 0.18 measured). All five of run 15's findings are closed. The Flexibility 4→3 is reviewer judgment naming accelerator gaps on surfaces this diff never touched — not a regression; Recognition 3→4 and User Control 3→4 reflect verified fixes; Consistency holds at 3 (the bare glyph flagged last run was kept deliberately, now as a `?`/`!` pair — judged fresh this run and still unconventional).

## Design Specificity Verdict

**Authored for restic and only restic — reconfirmed on the new work, not just the old.** The new tray faces extend the app's own vocabulary rather than decorating it: the four-state machine is derived from restic's actual operation set (plan backups, check/prune, restore, console all count as running; MenuBarStatus.swift:35) and every state is model-tested. A's anchors all held on re-read: exit code 12 gets a fix named before restic's own words (ResticError.swift:28-38), retention is a projection of outcome not bucket arithmetic (PlanEditorSheet.swift:276-290), rclone remotes come from the user's own `rclone config` (RepositoryEditorSheet.swift:327-339), and the mark itself now documents exactly where it deliberately diverges from the Dock generator and why (MenuBarLogo.swift:13-20). The unconfigured flow is the diff's headline and it is specific to this app's life as a background citizen: the icon asks, the menu answers with the next concrete action.

**Deterministic scan:** `impeccable detect --json Sources/SwiftRestic/Views` exited 0 with zero findings (`[]`) — same null result as the previous two runs. The detector's ruleset targets web-markup anti-patterns and has essentially nothing to match against native SwiftUI; a clean pass is a null result, not assurance. No false positives — nothing to be false positives.

**Visual evidence (no browser applicable — native app).** B produced real rendered evidence instead: standalone vector re-renders of all three `MenuBarLogo` faces at 1×/2×/10× with numeric per-plate measurements; 249 unit tests passing; live screenshots of the unconfigured first-launch state (menu bar crop showing the `?` status item, open-menu crop showing the answering headline and button, Welcome window); and a full fixture run — Overview, Activity, Console, Plan detail, Repository detail with real numbers (102 KB, 3 snapshots, 14 blobs, 3.4% compression), light and dark, with the tray verified wearing the `!` problem face in both appearances. Pixel sampling put the Problems tile glyph at Δ≤1/255 per channel from the Recent problems card glyph in both light and dark. Artifacts are on disk under `/tmp/swiftrestic-assessb/` if you want to inspect them. The one gap run 15 left — the unconfigured state never screenshotted — is closed this run.

## Overall Impression

The fix-set lands. Every finding from the last run is closed, and not nominally: the two that mattered were verified at the pixel and runtime level, which is the strongest evidence a menu-bar app can offer. What remains is second-order wiring, and it clusters around a theme this codebase otherwise excels at — one source of truth. Reduce Motion is read but not observed; "recent problem" has three definitions on one screen; the icon and the menu's first line can disagree after a repository is deleted. None of these erases the fact that this is a disciplined, restic-literate interface at the top of the Good band. The single biggest opportunity: finish the tray's story by giving every channel of it one shared definition of state, so the app's always-visible surface can never contradict itself.

## What's Working

1. **The tray state machine is treated as product surface, and now closes the loop.** Every face, headline, and menu line is a pure, unit-tested function — and the loop is real: B clicked open the actual status item menu on a repository-less launch and found the `?` answered by "No repository set up yet" and a working "Add a Repository…" button, exactly where a first-time user needs it.
2. **Honest states everywhere.** A failed listing wears "—" instead of a fake zero (RepositoryDetailView.swift:132-157), stale rows survive a failure under a dated strip (PlanDetailView.swift:564-583), and the two "no snapshots" cases get different words. B's fixture run confirmed the Activity table rendering a real failure with restic's own truncated error text.
3. **Measured, documented craft.** The running pulse was rebuilt so that every frame differs from every other in both plates — B's independent renders confirm the margins numerically (tightest pair: 0.18 measured on the top plate, resting vs frame 1) — and the file now documents its deliberate divergence from the Dock generator with the real coefficients instead of stale ones.

## Priority Issues

**[P2] Reduce Motion is half-wired: read without observation, and the fallback erases the running cue**
Why it matters: `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is read inside the view body (SwiftResticApp.swift:321) with no observer anywhere (verified by grep — sole reference), so toggling the setting mid-run leaves the pulse animating until the next model mutation, which during a quiet `check` can be minutes. Worse, the RM branch substitutes the resting image — so for these users the running face is pixel-identical to idle, and the tray's whole point (being the only surface when the window is closed) is lost precisely for the cohort that asked for stillness.
Fix: observe the flag (`.onReceive(NSWorkspace.shared.publisher(for: \.accessibilityDisplayShouldReduceMotion))` or the change notification) so it's live, and give RM a *static* running face — freeze frame 0's alphas `[1.0, 0.35]`, already distinct from rest in both plates, zero motion.
Suggested command: `/impeccable harden` (observer) + `/impeccable adapt` (static running face)

**[P2] The tray can wear two different verdicts at once**
Why it matters: with no repository configured, the icon wears `?` (unconfigured beats problem, MenuBarStatus.swift:33-34) — but the menu's problem line still leads with "Nightly failed 2 hours ago," because `deleteRepository` never clears `configuration.runs` (AppModel+Repositories.swift:83-93) and the unconfigured precedence applies only to the icon, not the headline. One open menu, two verdicts from the same app. The state machine's doc rationale ("with no repository there is nothing that could have produced a run," MenuBarStatus.swift:12-14) is false as worded — old runs survive repository deletion.
Fix: make both channels draw from one source — suppress the problem line when the unconfigured face is showing (or scope `problemLine` to runs whose repository still exists). Keep the run history in Activity; fix the channel agreement, not the data.
Suggested command: `/impeccable harden`

**[P2] "Recent problem" means three different things on one screen**
Why it matters: the Problems tile counts a 7-day window on `startedAt` (OverviewView.swift:214; OverviewMetrics.swift:115-120), the "Recent problems" card is an unwindowed top-5 (OverviewView.swift:492-496), and the tray's problem line uses a 7-day window on `finishedAt` (MenuBarStatus.swift:84-88). So the tile can show a green "0" directly above a card listing a 9-day-old failure, and a check that started 7.2 days ago but failed this morning puts `!` in the tray over a green tile. This diff fixed the *color* disagreement (verified: Δ≤1/255); the *window/basis* disagreement is what's left.
Fix: one shared `problems(in:since:)` definition with one timestamp basis (the private helper already exists), and either window the card or rename it "Latest problems."
Suggested command: `/impeccable clarify`

**[P3] "Add a Repository…" works — verified at runtime — but rests on an uncontracted one-run-loop-turn bet**
Why it matters: `addRepository()` posts `.swiftResticNewRepository` exactly one `Task { @MainActor }` hop after `openWindow` (MenuBarContentView.swift:83-89), betting that one turn is enough for the new scene to install RootView's `.onReceive` (RootView.swift:90-93). B clicked it live with the window closed: the window opened and the sheet was delivered (screenshot on disk), and a repeat click with the sheet already up no-ops gracefully — a typed discriminator value survived, so nothing stacked or reset. The finding therefore drops from P2 to P3: no user impact was demonstrated. What remains is that the bet has no contract behind it — nothing in AppKit promises scene installation completes within one main-actor turn, so this is correct on every machine tested rather than correct by construction — and the sibling variant (some *other* sheet up, e.g. Find) is reasoned to silently swallow the post but wasn't exercised.
Fix: post the intent through the model (a `pendingNewRepository` flag RootView consumes in both `.onAppear` and `.onReceive`) — makes the handoff correct by construction, removes the race, and unifies with the File-menu path.
Suggested command: `/impeccable harden`

**[P3] The two attention faces are the thinnest marks in the menu bar**
Why it matters: B measured the bare symbols' ink coverage at 0.043 (`exclamationmark`) and 0.070 (`questionmark`) of the canvas versus 0.29 for the drawn logo — the two states that need noticing are 3-4× lighter than the resting face beside them, and both are tall hairline strokes that collide with the "help" association (`?`) and the app's own filled-triangle trouble convention everywhere in-app (RootView.swift:221, OverviewView.swift:511). The pair is at least internally consistent — same silhouette-change logic, documented rationale (MenuBarStatus.swift:44-48).
Fix: `exclamationmark.circle.fill` / `questionmark.circle.fill`, or badge the app's own mark — filled shapes that still change silhouette but carry weight.
Suggested command: `/impeccable shape`

**[P3] The Protection card says "No snapshots yet" to a repository that has snapshots**
Why it matters: B's fixture run captured Overview reading "0 of 1 protected / No snapshots yet" while Repository detail, on the same launch, listed 3 real snapshots. The zero is correct by the app's own definition (plan-attributed snapshots; the fixture's were seeded via bare `restic backup` and carry no plan tag) — but the copy isn't: anyone adopting an existing restic repository hits this on day one, and "No snapshots yet" reads as a false statement about their repository. Plan Detail already has the accurate distinguishing sentence ("This repository has snapshots, but none from this plan yet," PlanDetailView.swift:371-381).
Fix: reuse that distinction on the Overview Protection card.
Suggested command: `/impeccable clarify`

## Persona Red Flags

**Sam (Accessibility-Dependent).** The Reduce Motion gap is Sam's finding, in two parts: the flag is read once with no observer (stale for minutes after being toggled), and the fallback gives no running cue at all on the only always-visible surface. Everything else around it is handled unusually well — accurate per-state VoiceOver strings for all four tray faces (MenuBarStatus.swift:64-70, verified this run), combined accessibility elements, banners announced once at the root. The gap stands out precisely because its surroundings are excellent.

**Riley (Deliberate Stress Tester).** The quit-dialog double-⌘Q race flagged last run now has its safe answer owning Return (SwiftResticApp.swift:60-63). Riley's remaining probes: delete a repository right after a failed run and watch the tray say `?` while the menu says "failed 2 hours ago" (issue 2); the repeat-click case is now settled — B verified a second click with the repository sheet already up no-ops without resetting typed input — but the sibling variant is still open: trigger "Add a Repository…" while a *different* sheet (e.g. Find) is up and the post is reasoned to be silently swallowed (RootView's guard no-ops it), forwarding the user to a window that ignores them.

**Jordan (Confused First-Timer).** The first-timer loop this diff was built to close now closes: Welcome routes repository-first with an explaining caption, the sidebar says "No repositories yet," the tray `?` menu answers with a button — B verified all of it live on a real launch with an empty config. The one soft spot is the timing bet in issue 4: if it ever loses the race, Jordan lands on a bare Welcome window one step short of the promised sheet — recoverable, but exactly the kind of flaky first impression that reads as "buggy."

## Minor Observations

- `MenuBarLogo.swift:28-30`'s safety argument names only the ring, but the leftmost ink is actually the arrowhead's base corner — ~0.92pt from the left edge by arithmetic, 0.90pt measured by B (the binding constraint is axis-aligned, not radial). Both fit; the comment could name the true binding constraint.
- Sidebar's Console row stays enabled with no repositories while the toolbar disables Console (RootView.swift:96-101 vs 195-196) — the orphan console offers only "Choose…".
- Global notification toggles and per-channel toggles overlap (SettingsView.swift:68-69 vs 282-294) without stating which wins.
- SettingsView.swift:63's four-face caption is accurate now but never mentions that the running face pulses.
- The maintenance menu names repositories because `AppModel+Maintenance.swift:74` smuggles the name into `planName` — correct by convention, fragile by accident (MenuBarStatus.swift:91-105 depends on it).
- project.yml:54-58 special-cases `MenuBarLogo.swift` into the test target with a good comment; the next pure-logic file placed in Views/ will silently miss test coverage.
- `deleteRepository`'s self-documented disclosure gap (cancelled work not announced, AppModel+Repositories.swift:66-70) remains open, still flagged as a defect class in the code itself.
- At 1× the anti-aliased fringe touches all four canvas edges at an any-alpha threshold, but vector geometry leaves ≥0.5pt margin — a measurement artifact, not clipping.
- 249 tests in 44 suites passed (`** TEST SUCCEEDED **`), including the new cadence, four-face, and worst-problem-severity tests.

## Questions to Consider

- When the tray's first line says "Nightly failed 2 hours ago" and its icon says "no repository configured yet," which one is the app telling the truth with? Should a state machine ever let its two always-visible channels disagree?
- The Problems tile, Recent problems card, tray line, and Activity filter implement "recent trouble" with three windows and two timestamps — the tile and card already share one private helper to prevent disagreement; why does the tray's definition live outside it?
- The running pulse exists to say "data is climbing" in peripheral vision — but the same slot could carry a determinate cue (the tray menu already computes percentages). If Reduce Motion must be able to suppress the animation entirely, is an animation the right primitive for a state that also has a number?
