---
target: the app UI (Sources/SwiftRestic/Views)
total_score: 35
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 2
target_identity: "file:/Users/newlix/github/at-least/SwiftRestic/Sources/SwiftRestic/Views"
timestamp: 2026-09-10T13-19-04Z
slug: sources-swiftrestic-views
---
Method: dual-agent (A: a3be8306305a816fd · B: ac847dad50510e989)

# SwiftRestic UI Critique — Sources/SwiftRestic/Views

*Assessment A reviewed all ~17 view files plus App/Models/Services/Core sources, unanchored, with the current uncommitted working-tree diff (`MenuBarLogo.swift`, `MenuBarStatus.swift`, `SwiftResticApp.swift`, tests) read as live work-in-progress. Assessment B independently built the app, wired a real restic fixture repository (2 real snapshots, 8 run records) through the app's `SWIFTRESTIC_REPO_PASSWORD`/`SWIFTRESTIC_CONFIG_DIR` debug seam, captured 14 real screenshots across 8 panes/sheets in light and dark, ran the deterministic detector, and separately rendered `MenuBarLogo.swift`'s actual drawing code standalone to real pixels (native 18px + 10× upscale, both appearances) with a numeric per-row luminance measurement rather than eyeballing. B's rendered evidence confirmed one of A's inferred findings with hard numbers and surfaced no new visual bugs in the window panes it exercised.*

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 4 | Freshness stamps, ETA/rate progress cards, per-run elapsed-time counters distinguish "working" from "hung" — but the running tray icon's own pulse is weaker than designed (see Priority Issues): one of its two alternating frames is numerically near-identical to the resting frame |
| 2 | Match System / Real World | 4 | restic's own vocabulary taught in place (ConceptsView.swift), pinned to "restic 0.19.1's output"; exit code 12 maps to a specific fix (ResticError.swift:29-37) |
| 3 | User Control and Freedom | 3 | Cancel available for backup/restore/maintenance/console/find; quitting mid-run builds its own hand-rolled `NSAlert` (SwiftResticApp.swift:52-63) instead of the app's normal confirmation pattern |
| 4 | Consistency and Standards | 3 | Confirmed on B's actual Overview capture: the "Problems (7 days)" tile renders orange while the "Recent problems" card on the *same screen* marks the identical failed run with a red icon — plus a bare-`exclamationmark` problem glyph (MenuBarStatus.swift:60, diff) breaking from the filled-triangle convention used everywhere else |
| 5 | Error Prevention | 4 | All-zero retention guard, named-command confirmation before destructive console commands, password confirm-match gates Save |
| 6 | Recognition Rather Than Recall | 3 | Stable rclone-suggestion and console-recall UX — but the diff's new `unconfigured` tray state (a bare `?`) has no answering copy anywhere in `MenuBarContentView.swift` |
| 7 | Flexibility and Efficiency | 4 | Terminal-style console history recall, real ⌘-shortcuts throughout |
| 8 | Aesthetic and Minimalist Design | 3 | B's actual Overview render is clean and well-organized (confirmed, no visual clutter) — but it still stacks 6 cards + any active banners at first paint, one more than the working-memory guideline |
| 9 | Error Recovery | 4 | Exit-code-12 gets a specific fix, not a generic message; failure text stays selectable; stale-vs-failed listings are distinguished, not collapsed |
| 10 | Help and Documentation | 3 | Strong in-context help (ConceptsView, ExpandableCaption) — but the one place the tray's four faces are explained (SettingsView.swift:63) is now stale, still describing three faces after the diff added a fourth |
| **Total** | | **35/40** | **Good — solid foundation, address the weak areas** |

Movement from 36: this run scores one point lower than the last snapshot. The uncommitted diff under review adds a real feature (the app's own mark replacing a stock SF Symbol in the tray, per commit `cbe09de`) but also introduces two new regressions this run caught that weren't present last time: the `unconfigured` state has no answering UI (heuristic 6), and the tray's running-frame doc comment/help text drifted out of sync with the code it describes (heuristic 10). Net: real progress, tracked by real dings — not a wash.

## Design Specificity Verdict

**Authored for restic and only restic — reconfirmed with live data, not just code reading.** B's actual repository-detail capture shows real numbers this app is built to surface: 6 KB repository size, 2 snapshots, 22 blobs, 38.0% compression saved, live snapshot IDs (`bc2b4815`, `21c18959`) with correct byte counts. The diff sheet correctly diffed two real snapshots with accurate added/removed/changed counts. A's source read adds the qualitative case: a retention editor that projects survivor counts instead of restating bucket rules (PlanEditorSheet.swift:276-290), a console that explicitly disclaims parsing restic's own output (ResticConsoleView.swift:143-146), and an SFTP warning specific to the fact that the app has no terminal to answer an SSH passphrase prompt (RepositoryEditorSheet.swift:218-220). An unrelated backup product could not ship this screen set unchanged.

**Deterministic scan:** `impeccable detect --json Sources/SwiftRestic/Views` exited 0 with zero findings (`[]`). Low weight, confirmed by B: the detector's ruleset targets web-markup anti-patterns and has essentially nothing to match against native SwiftUI, so a clean pass is a null result, not assurance. No false positives — there was nothing to be a false positive.

**Visual evidence (no browser applicable):** This is a native macOS app, not a web page — there is no `[Human]`-tab browser overlay to point you at. In its place, B produced real rendered evidence: 14 PNG screenshots of actual app panes (light + dark: overview, plan detail, repository detail, activity, find, console; plus the repository-hooks and snapshot-diff sheets) built against a live restic fixture, and 12 direct renders of the tray icon's own drawing code at native 18px and 10× upscale. All are on disk under the session scratchpad if you want to inspect them directly. No visual bugs — no blank regions, no clipped text beyond expected column-ellipsis, no contrast problems, no misalignment — turned up in any of the 8 panes/sheets B exercised. B did not build a fixture for the `unconfigured` (no-repository) state, so A's top finding about that state is source-verified but not independently pixel-verified this run.

## Overall Impression

This is a well-executed, restic-literate interface sitting on a genuinely disciplined foundation — real accessibility architecture (not an afterthought), a failure taxonomy that reflects actual restic operating experience, and an Overview screen that renders exactly as clean as the code suggests it should. The diff under review is a good idea (the tray finally wears the app's own mark instead of borrowed system furniture) executed with a visible gap between intent and result: the mark itself is legible at 18px in both appearances, but the running-state pulse it was built to carry is measurably weaker than its own doc comment claims, and the new state the diff exists to introduce (`unconfigured`) has no home in the menu it lives under. The single biggest opportunity: finish what this diff started — give `unconfigured` an answer, make the running pulse actually alternate, and true up the doc comments the file's own contract depends on — before it lands.

## What's Working

1. **Failure taxonomy that respects restic's own semantics.** `ResticError.swift:29-37` singles out exit code 12 (wrong password) with a specific, actionable fix rather than a generic "command failed," and separately treats exit 3 as a warning, not a failure, because that's what it is in restic. B's live captures back this up end-to-end: the Activity table correctly rendered 7 real successes and 1 real failure with restic's own truncated error text, not a synthesized placeholder.
2. **"Why is this a dash" discipline.** Every stat tile dependent on a snapshot listing distinguishes "not loaded," "failed to load," and "loaded and empty," with the reason surfaced as visible text — explicit in the code as "a reason only a hovering mouse user can reach is no reason at all" (PlanDetailView.swift:118-120). This is accessibility built into the architecture, not bolted on.
3. **A tray mark that actually reads at 18px.** B's pixel-exact 10× render confirms the ring-opening-left, downward-arrowhead, two-plate-stack construction is legible in both light and dark menu bars — a real, working improvement over a generic system glyph, even with the animation gap noted below.

## Priority Issues

**[P1] The diff's own new `unconfigured` tray state has no answer in the menu it belongs to**
Why it matters: `MenuBarStatus.glyph(.unconfigured)` renders a bare `?` (MenuBarStatus.swift:57), but `MenuBarContentView.swift` has no branch for it — the dropdown shows only "No backups scheduled" plus Open/Quit. This is the diff's own headline new state, and the one place a user would click to resolve it says nothing about what's wrong or how to fix it — a real dead end for a first-time user at the exact moment the icon prompted them to click. Source-verified by Assessment A; not independently screenshotted this run (B's fixture always had a repository configured).
Fix: add a line to `MenuBarContentView.swift`, parallel to the existing `problemLine`, for `hasNoRepositories` — e.g. "No repository set up yet" plus an "Add a Repository…" action.
Suggested command: `/impeccable onboard`

**[P1] The running-state pulse doesn't actually alternate — half its frames look like resting**
Why it matters: this is the diff's own core deliverable (the animated stack that's supposed to read as "data climbing" while a backup runs), and B's direct pixel measurement of the real drawing code contradicts the file's own doc comment. `resting` alphas are `[0.60, 1.0]`; `running` frames are `[1.0, 0.55]` and `[0.55, 1.0]`. B's per-row luminance measurement on the actual rendered 18px bitmaps shows `running(phase: 1)` is numerically near-identical to `resting` (peak-row values matched exactly in one case), while only `running(phase: 0)` reads as visually distinct. Confirmed on the 180px upscales by eye. Net effect: across the 0.6s-per-frame cycle, the icon reads as a flicker toward one inverted frame and back, not the continuous two-state alternation the doc comment describes ("brightness reads as climbing from the bottom plate to the top and back").
Fix: widen the gap between the two running frames (e.g. push further from resting's `[0.60, 1.0]` than `[0.55, 1.0]` currently does) so both frames are visually distinct from idle, not just one of them.
Suggested command: `/impeccable animate`

**[P2] `MenuBarLogo.swift`'s doc comment overstates its own parity with the icon it claims to mirror**
Why it matters: dual-confirmed. A caught it by re-deriving the comment's own arithmetic (its "0.301 × s" ring-edge figure is still computed from the pre-diff 0.082 stroke); B independently confirmed it by rendering both `MenuBarLogo.swift` and `Tools/GenerateAppIcon.swift`'s small-size construction from source and diffing the actual coefficients: stroke went from `0.082` to `0.068` (~17% thinner) and the arrowhead's length/width multipliers from `2.3`/`1.45` to `1.9`/`1.15`, while the generator's own small-size proportions were untouched by this diff. Ring radius and plate geometry still match exactly. Visually the two still read as the same mark (B's blow-up comparison confirms this), but the comment's explicit "mirrors... so the tray wears the same mark the Dock icon does" claim (MenuBarLogo.swift:13-17) no longer holds at the numbers it cites — and that comment is the file's whole enforcement mechanism for staying in sync ("keep the two in sync when the icon changes," line 17). Same pass should also fix `SwiftResticApp.swift:298` ("Three faces, not two" — there are now four `IconState` cases) and `SettingsView.swift:63`'s stale user-facing help text, which still doesn't mention the new unconfigured face.
Fix: update the doc comment's numbers to the actual `0.068`/`1.9`/`1.15` values, or soften "mirrors" to "loosely follows"; update the two stale help-text references in the same pass.
Suggested command: `/impeccable polish`

**[P2] Severity color doesn't mean the same thing twice — visible within a single screenshot, not just across views**
Why it matters: B's actual Overview capture shows this directly, not just in source: the "Problems (7 days): 1" stat tile renders in orange (`Theme.warning`), while the "Recent problems" card three inches below it, on the same screen, marks that identical failed run with a red circled-X icon. A's source read explains why: `OverviewView.swift:236-237` and `ProtectionRow` (lines 79, 196) paint both `.failed` and `.completedWithErrors` uniformly orange, while `ChartPalette.status(outcome)` — used in Activity and the diff sheet — resolves `.failed` to red. On a backup tool, status color is one of the few signals users scan quickly; having it mean "problem exists" in orange on one card and "this specific thing failed" in red four inches away, on the same page, erodes exactly the trust this app otherwise works hard to earn.
Fix: either have the Overview tile/row draw from `ChartPalette.status` per-run severity, or make the coarser "orange = needs attention" vocabulary intentional and visually distinct in weight, not just hue, from the per-run red.
Suggested command: `/impeccable polish`

**[P3] The tray icon image is no longer cached — rebuilt from scratch on every 0.6s animation tick**
Why it matters: source-verified regression. The pre-diff code built the icon once as a cached `static let`; the diff replaced it with a `static func` that reconstructs the `NSImage` on every call, including every `TimelineView` tick for the full duration of every running backup (SwiftResticApp.swift:324-326, MenuBarLogo.swift:52-56). Cheap per call, but a real, silent behavioral regression introduced as a side effect of adding animation, in a status-item image redrawn on a timer.
Fix: cache the three possible images (resting + 2 running frames) instead of rebuilding per tick.
Suggested command: `/impeccable optimize`

## Persona Red Flags

**Jordan (Confused First-Timer).** `WelcomeView` does its job well on first launch. But SwiftRestic is explicitly designed to live on after the window closes (`AppDelegate.applicationShouldTerminateAfterLastWindowClosed` returns `false`), so a Jordan who dismisses Welcome without adding a repository is left with only the tray `?` as their remaining surface — and per the P1 finding above, clicking it explains nothing. This is a real gap for exactly the persona the app is built to keep engaged in the background.

**Sam (Accessibility-Dependent).** Two concrete, specific findings: (1) `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is read once inside the view body (SwiftResticApp.swift:321) with no observer on the system's accessibility-change notification — a user who enables Reduce Motion *mid-backup* keeps seeing the pulse until the run's state changes, not immediately. (2) Elsewhere the app is unusually careful: `.accessibilityElement(children: .combine)` used correctly to avoid double VoiceOver stops, banners announced once at the root rather than per-pane, decorative icons consistently `.accessibilityHidden(true)`. The Reduce Motion gap stands out precisely because everything around it is handled well.

**Riley (Deliberate Stress Tester).** The two genuinely destructive paths — repository removal and prune — are well-defended: a single testable consequence string reused identically in both the sidebar and detail-pane dialogs, and the prune dialog names the actual lock consequence rather than a generic warning. Riley's one finding: quitting mid-run bypasses the app's normal confirmation pattern entirely and hand-rolls a second `NSAlert` with its own re-entrancy guards (`isConfirmingQuit`, `isTerminating`) — worth stress-testing specifically for double-⌘Q races, since the guards exist because that race was anticipated.

## Minor Observations

- The new `MenuBarLogoTests.imageRenders` test asserts only `size.width > 0`; `NSImage(size:flipped:drawingHandler:)` sets its size eagerly at construction and defers the drawing handler until actually drawn, so this assertion cannot detect a crash inside `draw(in:into:content:)`. The test name promises more than it checks.
- `WelcomeView` uses the stock SF Symbol `externaldrive.badge.timemachine` as the app's hero mark (RootView.swift:451) — the same "system furniture, not our mark" problem the tray-icon work was written to fix. The brand mark never appears on the first screen a new user sees.
- `Theme.tint` follows the system accent color everywhere in the app, while the Dock/tray mark is a fixed teal (Tools/GenerateAppIcon.swift) — brand color and in-app color are two disconnected systems. Plausibly deliberate given the app's stated native-first philosophy, but worth naming as a choice rather than an accident.
- B's fixture-generated snapshots showed as "No snapshots yet" / "0 of 1 protected" on Overview despite 2 real snapshots existing in the repository — traced to the fixture being seeded via a bare `restic backup` outside the app's own plan-run path, not an app bug; the app's own "none from this plan yet" empty-state copy in Plan Detail was accurate and well-written given that fixture gap.
- `PlanEditorSheet`'s 5-tab structure and `RepositoryDetailView`'s Maintenance menu (which mixes one safe action with three destructive ones of different blast radii, by the code's own admission "for reach") both sit one item over the ≤4 working-memory guideline — low severity since every item is individually well-labeled and confirmed.

## Questions to Consider

- The whole point of this diff is "the tray should wear the app's own mark instead of system furniture" — so why does `unconfigured`, a state introduced in the same diff, fall back to a bare SF-Symbol-style `?` instead of a silhouette in the same visual language as the ring-and-stack mark? Scope cut, or a deliberate bet that punctuation reads faster at 18px?
- If Reduce Motion is meant to suppress the pulse, why does the running *state* itself not re-evaluate when that setting changes mid-run — is the intent "reduce motion" or "reduce motion, eventually, next time something else changes"?
- Given how carefully this codebase differentiates failure/loading/empty states everywhere else — arguably its strongest trait — why does a successful backup get no positive "peak" moment beyond a relative timestamp update? Deliberate quiet reliability, or unaddressed?
