# AGENTS.md

Working rules for AI agents (and humans driving scripts) in this repo:
pointers into the README, plus the capture and verification discipline that
each cost a debugging session to learn.

## Build

Always build through `./build.sh`: xcodegen snapshots the source file list,
so new files are invisible to `xcodebuild` until it regenerates the project.
`./build.sh test` runs unit plus end-to-end tests against real restic. Two
rules from the flaky-run hunt of 2026-09-14:

- Never pipe `xcodebuild` through `head` or anything else that closes its
  stdout early: the truncated pipe orphans it, and an agent shell may return
  before it is gone. Read the log `./build.sh` tees, or redirect to a file.
- Concurrent `xcodebuild test` sessions stomp each other's testmanagerd
  sessions: the loser's runner is SIGTERM'd ("Test crashed with signal
  term"), restarted, the rest pass, and the run is marked failed. The script
  refuses to start `test` while another xcodebuild exists and fails any run
  whose log shows the restart banner — which a plain crash or timeout also
  raises, so read the xcresult before blaming a collision.

Six timing tests failed now and then under load and passed on a re-run. On
2026-10-04, 5 of 13 `./build.sh test` runs failed on one or more of the first
four, and the fifth failed in 1 of 6 later runs; the sixth failed once in the
18 gate runs of 2026-10-09, in the one run that other work slowed 3.4×. Other work on the Mac held
the load average between 7 and 53: another project's simulator UI tests and
builds, and mediaanalysisd. No other test failed. Each bet on a wall clock
that load stretches, and each was fixed the same day:

| Test | Failed | What it reported | Now |
| --- | --- | --- | --- |
| "a backgrounded grandchild cannot outlive a finished hook's answer" | 2 of 13 | `.timedOut(seconds: 1.0, command: "restic")` | The run's cap is 20 s. At 1 s it fired on the shell itself: the shell was still running a second after the spawn, or the host had not yet seen it exit |
| "a child that keeps reporting is never stopped by the stall cap" | 2 of 13 | `.idleStalled(seconds: 1.5, command: "restic")` | A line every 0.25 s for ~6 s under a 5 s cap, not every 0.35 s under 1.5 s. The clock starts at the spawn |
| "status lines are decoded and delivered while the run is still going" | 4 of 13 | `arrival < 0.7 * elapsed` | The stub (`dribble-wait`) holds the run open until the progress callback plants a flag, so mid-run delivery holds by construction |
| "cancelling a backup ends the run and the child process is really gone" | 3 of 13 | "the stub never established its hang within 10 s; trace: [no trace]", no stub in `ps` | Waits up to 60 s for the hang, and the message says when the backup's task started |
| "a refresh asked while another is running runs after it, not never" | 1 of 6 | "the refresh requested mid-flight never ran", after 11.4 s against a 10 s poll | Awaits the registry's background lane (`tasks.drain()`), where the re-run is registered |
| "the retention preview is a dry run that works while a backup holds the lock" | 1 of 18 on 2026-10-09 | `Expectation failed: … snapshots(…, planID: plan.id).count == 3` (ResticIntegrationTests.swift:347) after 228 s against its usual 12–20, the whole run 1914 s against ~565; the second of its two issues, the control forget that ran, never reached the log | The backup that holds the lock reads its file from a pipe the test closes after the control forget (`backup --stdin`, one byte written), where `/bin/sleep 30` had let the lock go while the preview and the forget were still starting; the wait for its lock is 120 s, not 20 |

How the fixes were proved, each at the line that failed:
- **Before.** A stand-in for load on the one term each threshold bet on made each old test fail with its recorded message: the shell living 2 s; 4 s before the first status line; a 3 s gap between lines; the backup's task waiting 11 s before it spawns the stub; the remembered re-run starting 11 s late.
- **After.** The fixed tests pass under the same stand-ins: 96 tests in the four suites.
- **Still able to fail.** With the remembered refresh dropped, the refresh test fails in 0.4 s. With the status line delivered after the stub gave up waiting, the status-line test fails.
- **Natural failures.** A full run that afternoon, before the fixes, failed the grandchild and stall-cap tests on its own, with their recorded messages.
- **The sixth, 2026-10-09.** A 31 s sleep between the holder's lock and the preview — the stand-in for the load that stretched that run — failed the old test in 51 s with its two issues, "Issue recorded" at the forget that ran and the count at 347; the fixed test passed under the same sleep in 45 s; with the release written before the control forget instead, it failed in 51 s with the same two issues. That fix held the lock with a shell waiting for a release file; 7bff71c holds it with the pipe, which restic reads until the test closes it — the control forget, which must find the lock held, has in every gate run since. The stand-ins were not repeated on the pipe.

What load stretched is not measured. The suite runs one test at a time (the scheme's testable is `parallelizable = NO`): while a probe test ran first for 110 s, no other test finished. So no other test was holding the cooperative pool when these failed, and blocking as many pool threads as there are cores for 11 s, from inside the cancel test, did not fail it. The likelier source is the other work on the Mac. With the Mac lightly loaded (load average 6–9), the probe's per-10-s maxima over 45 windows were: a task's wait for the pool ≤ 1 ms; a utility-QoS block's wait ≤ 96 ms; `/bin/sh -c` spawn to observed exit 15–37 ms; a script written just before, run directly as every stub and raw-script test does, 55–897 ms, of which `Process.run()` took ≤ 3 ms.

## The snapshot index

What it is and where it lives: the README's Architecture section. Rules for
changing it:

- `Sources/SwiftRestic/Services/Index` imports no AppKit, SwiftUI or Cocoa
  (build.sh's lint fails closed), and only the `SnapshotIndex*.swift` files
  import GRDB — nothing above the store touches SQL.
- Every statement the index prepares — the open-time schema probe, the
  connection pragmas and the test-support invariant checks aside — is a
  stored `let` of `SnapshotIndexSchema.Statements` (an `InList` when its
  text depends on an IN list's length), which
  `SnapshotIndex.registeredStatements` reads by reflection, so declaring a
  statement registers it. `SnapshotIndexPlanTests` (no `@testable import`)
  pins each by its property name and fails on a statement without a rule, a
  rule without a statement, or a stored property that is not a statement.
- Every table is in `SnapshotIndexSchema.create` except the browse caches
  added since schema 3 shipped (`file_node`, a file's `restic find` answer
  per backup), which `SnapshotIndexSchema.addedCaches` creates at every open
  with `CREATE TABLE IF NOT EXISTS`. A cache starts empty either way, while
  bumping `user_version` deletes and rebuilds every repository's index — a
  full restic re-read. Their statements are registered and pinned like the
  rest. A table that answers depend on for correctness belongs in `create`,
  with the bump.
- Tests open their index in a temporary folder or an injected configuration
  folder, never the real `~/Library/Application Support/com.newlix.SwiftRestic`.
  No code path may open, sweep or delete the `<configDir>/<uuid>.sqlite` files
  earlier builds left there.
- Heavier runs, each one xcodebuild session like `./build.sh test`:
  `Tools/sqlite-floor.sh` (plan pins and the property test on SQLite 3.43.2),
  and `TEST_RUNNER_SWIFTRESTIC_INDEX_BENCH=1` or
  `TEST_RUNNER_SWIFTRESTIC_INDEX_PROPERTY=40,30` on an `xcodebuild test
  -only-testing:SwiftResticTests/<Suite>` run — after `xcodegen generate`
  (see Build), output redirected to a file.

## Photographing the app

Debug captures are driven by `SWIFTRESTIC_*` environment variables, all
documented in the README under "Looking at the app" — read it before the
first capture. Everything in the next two sections was verified live on
2026-09-14: macOS 26 / Xcode 26.6, one display (2940×1912 pixels, 1470×956
points @2x), light mode.

### Rules

- **Never point a capture run at the real configuration.** Set
  `SWIFTRESTIC_CONFIG_DIR=/tmp/...` so the run cannot see or refresh the
  user's repositories nor read the login Keychain for a password. Keychain
  writes still go through: never save a repository editor or press Change
  Password in a scratch run.
- **One output directory per agent and run** — a shared filename is
  overwritten by the next agent before the first reads it.
- **Never substitute a full-screen capture for the window capture**: that is
  what makes concurrent agents photograph each other.
- **Run `caffeinate -u` before every scripted shot** (the sweep does; see
  "sleeping display" below), and **read the stderr backend line** after.

### Verified behaviour

- **Captures are occlusion-proof.** Under another app's full-screen window
  (99.91% and 99.90% of the window rect covered, measured by a full-screen
  shot at capture time) they still showed the full, correct content: 0.74% of
  pixels off the unoccluded baseline for a single shot, 0.37–1.34% per sweep
  pane, and 0.0000% of the occluder's colour (strict leak and pinkish glass
  bleed alike).
- **Occluded captures wear inactive-window chrome** — grey traffic lights,
  dimmed labels, desaturated accent buttons: standard for a non-key window,
  not a regression, not fixable at capture level. Across runs whose
  activation differs expect up to ~1.3% difference, all in chrome; mask or
  tolerate it.
- **The window re-renders while covered** (this app's SwiftUI content): the
  sweep switches panes under full occlusion, and the occluded pane images
  differ from each other by 3.1–4.7% and match their unoccluded counterparts
  to within chrome — no stale frame. (The sweep's occlusion was inferred from
  the same occluder plus zero colour leak; only the single shots' coverage
  was measured.)
- **`screencapture -l <windowID>` is equivalent**: pixel-identical to the
  app's ScreenCaptureKit shots on macOS 26, occluded or not — the tool for
  per-window shots outside the app. The window must be on the current Space,
  not minimized or hidden, and the terminal needs Screen Recording permission.
- **With a sheet up, the sheet — not the main window — is photographed.**

### Failure modes

The preferred backend is ScreenCaptureKit, on a 6-second leash. Each capture
logs one of these lines to stderr:

| stderr line | Meaning |
| --- | --- |
| `capture backend: cacheDisplay` | Screen Recording permission was missing (grant it per the README); Tahoe's glass photographed black |
| `failed` | ScreenCaptureKit unauthorised |
| `timed out` | The 6-second leash ran out |
| `found no window N on screen` | ScreenCaptureKit could not find the window it was asked for |

**A sleeping display poisons everything.** Verified 2026-09-14 with
`pmset displaysleepnow` on the single display (`CGDisplayIsAsleep`=true,
active-display count 0): full-screen `screencapture -x` exits 0 with a
pure-black frame (pixel stddev 0.00), and `screencapture -l <windowID>`
fails on *unoccluded* windows — a SwiftRestic and a Postico window — with
exit 1 and "could not create image from window", the same text a missing
Screen Recording permission gives (verified: display awake, permission
absent, `-x` and `-l` fail identically). The discriminator is `-x`: missing
permission fails it (exit 1, no file), a sleeping display passes it with a
uniform frame. Probe with `screencapture -x`, treat near-zero pixel variance
as asleep, wake with `caffeinate -u -t 3` and retry. Existing windows stay
listed in `CGWindowListCopyWindowInfo` while asleep; whether a *newly
created* one registers was not tested. (pgweb's
`docs/postico-observations.md` §27.5 has `screencapture -l` working after
its `list_displays` emptied — evidently not a true single-display sleep.)

### Re-verifying the occlusion behaviour

Assertion-driven: two unoccluded baselines pixel-identical (0.0000
measured); an occlusion proof (full-screen shot at capture time, ≥99% of the
window rect covered — count the occluder's own label pixels as covered, or
it reads 97.7% and fails); the stderr backend line; a diff tolerant of
≤~1.3% chrome-only pixels; a colour-leak check. Self-test the comparator
first — pass on identical images, fail hugely on a solid colour.

### Untested territory

Minimized or hidden windows, other Spaces, multiple displays, dark mode's
vibrancy materials (a locked screen: README's *Looking at the app* and the
facts below). `screencapture -l` matching ScreenCaptureKit shows both read
the same WindowServer surface — equivalence, not independent confirmation.

## Scripted runs against a scratch instance

What three rounds of accessibility-driven checks learned, and what none could verify: the Files view redesign (2026-10-04, `8305539`..`a561666`, then `f461728`..), the Files tab's search field (2026-10-05, `deaace2`..`a35ee15`) and round 4 of the Arq comparison (2026-10-09, `136ae15`..). What each saw is in its commits' messages.

### Facts for the next scripted run

Launching and quitting:

- **A normally launched instance never takes focus.** Launch the Debug binary itself — `DerivedData/…/Build/Products/Debug/SwiftRestic.app/Contents/MacOS/SwiftRestic`, not `open` — with `SWIFTRESTIC_CONFIG_DIR`, `SWIFTRESTIC_REPO_PASSWORD` and `-ApplePersistenceIgnoreState YES`, without `SWIFTRESTIC_CAPTURE`. The window is created without activation; the accessibility API drives it (the sidebar's `AXOutline` named Sidebar, rows set through `AXSelected`, the toolbar's Overview | Files segments, drawer and sheet buttons by description) and `screencapture -x -o -l <CGWindowID>` photographs it, a sheet composited on. Quit it through its application menu, by PID. A capture run activates the app on purpose and keeps the user's input for its whole delay (a 480 s delay took it on 2026-10-07): keep those to the pane presets with a short delay, and check the user's idle time (`ioreg -c IOHIDSystem`, HIDIdleTime) before any scripted session. The agent's shell is in the Background launchd session (`launchctl managername`), so System Events sees none of the instance's windows; nothing needs it, nor the gui-domain LaunchAgent a 2026-10-04 run used to get activation.
- **Address the instance by its PID, never by name**: the user's own SwiftRestic may be running against the real configuration.
- **Such a launch runs what is due.** Switch every plan's `isEnabled` off and the repositories' check and prune off in the scratch configuration, so nothing starts and no "Quit SwiftRestic?" prompt follows the quit; the captions then read "Paused — …", which the notes must say. The running state needs such a launch: `SWIFTRESTIC_CAPTURE_PANE` lands on its pane without `SWIFTRESTIC_CAPTURE`, the scheduler stays armed, and an overdue plan whose before-backup hook sleeps holds the run while `screencapture -l` takes the window.
- **A Back Up Now run writes to the scratch repository**: point it at a copy first. Two such runs of a plan with a source under an absent `/Volumes/…` merged into one Skipped record, `skipCount` 2, the first run's snapshot in `continuedSnapshotIDs` (2026-10-09).
- **restic gets the app's environment** minus the repository and password variables (`ResticRunner.protectedEnvironmentKeys`): `RESTIC_CACHE_DIR` at an empty folder, under a configuration with no repository, shows Settings › restic on an empty cache.
- **To see a surface before the listing lands**, point `resticPathOverride` at a wrapper that sleeps on `snapshots` and execs restic otherwise. A cold index (no `index` folder) makes Find Files take the restic engine.
- **The quiet-plan alert can be raised live** — the scheduler's first tick runs at launch. The plan switched on, every other plan and both repositories' check and prune off; its `lastCompleteBackupAt` further back than the alert's window (7 days for a daily plan at the default threshold), `lastSuccessAt` newer (a partial stretch), a source under an absent `/Volumes/…`; `lastRunAt` past the latest slot, so nothing starts; no `staleAlertedFor`. On 2026-10-10 `staleAlertedFor` in config.json held its `lastCompleteBackupAt` four seconds after launch — counted from the last whole backup, not the partial one. The Debug bundle's notification permission is off, so the window showed "Could not send a notification"; with it on, the notification would reach the user's screen. Its words stay unit-tested. Quit with `NSRunningApplication.terminate` by PID: the menu's Quit asks about the enabled plan's schedule.
- **An open sheet keeps an instance from quitting**: `NSRunningApplication.terminate` ended one within two seconds once its repository editor was closed, and not while open (cause not traced). Cancel on an unchanged draft closes it without asking.
- **A capture run that stops on a precondition** (`findMoved` on a one-repository configuration) leaves macOS's "reopen windows?" prompt, which hangs every later run until answered. Launch with `-ApplePersistenceIgnoreState YES`.
- **A helper binary compiled during a run can take a minute or two to start the first time**: two took 65 s and 110 s on 2026-10-04 while syspolicyd ran at 40–50% CPU logging "Error checking with notarization daemon". Killing launches after 10–60 s did not shorten the next wait; let one finish before timing anything.

The accessibility tree:

- **A dump describes the page it was taken on** — check its window title before reading a page from it. axshot once dumped before a row step's selection, so the Home NAS page's Recent problems row (one `AXButton`, 30 pt tall) passed for the Documents plan page's problem card, and this file called the card's item menus out of reach (8b20956). After the selection, each item line's ⋯ is an `AXMenuButton` titled "Actions for <file name>", offering Reveal in Finder (enabled while the file is on disk) and Exclude from “Documents”… (photographed 2026-10-10, nothing pressed). axshot now dumps after every step.
- **It sometimes answers with the application element**: `AXWindows` returns the application itself — on 2026-10-04 after macOS raised a Screen Recording consent dialog (`universalAccessAuthWarn`) twenty minutes in, and again half an hour later with the dialog still open; for long stretches on 2026-10-07 and 2026-10-08; while the screen was locked on 2026-10-09. Kill by PID and relaunch, else record the check as not seen live.
- **A popup's menu closes when the process that opened it exits.** `AXPress` from a process that stays alive (the session's `ax openhold`) opens and holds it, a `Menu` button's too; `AXPress` on a month item then opens its submenu (the Files pane's "As backed up" and the Compare sheet's "Compared with", both photographed with their rows: axshot's `holdsub:` step, 2026-10-09). Items carry a narrow no-break space (U+202F) before AM and PM: flatten it before matching titles. A SwiftUI list row's context menu and a key press are out of reach: `AXShowMenu` is unsupported on the rows and opens nothing on their text, and nothing is posted to a Mac in use.
- **An Activity row is selected through its `AXRow`**, above the cell (which holds the hosting group the text sits in).
- **A sheet's controls move when its status line appears.** The repository editor inserts its answer above its buttons, moving Test Connection, Cancel and Save each down one place; a script that resolved them once pressed Test Connection meaning Cancel on 2026-10-10 (a read-only probe; nothing written). Resolve a control by name from a fresh dump right before every press.
- **A secure field reads back empty** whatever it holds, so the readout is the probe: a wrong password made Test Connection answer "The password doesn't open this repository — …", the field left blank "Connected to the existing repository." (2026-10-10).
- **A Table's cells follow their row's data**: a lookup held by the parent and read in a cell closure did not re-render the cells when it changed; rewriting the rows did.

The index, the menu bar and a locked screen:

- **The snapshot index warms during such a launch.** Poll `select * from chain` in `<configDir>/index/<repositoryUUID>.sqlite`: the fourth column counts down to 1, the fifth is the total; 495 small backups took about six minutes under load. Keep that configuration folder as the warm one. A Files tab's steps need the listing: wait for the tree's "509 backups" value.
- **Reading 1,000 backups from empty took the index 8 min 56 s** (2026-10-04: 2,060 files, three changing per backup, local disk, other work loading the Mac), and a file pane's `restic find` 6.9–8.5 s against 0.6 s at 12 backups; narrowed to each version's newest backup (`--snapshot`, 100 of the 1,000), 1.6 s of CPU against 10.9 s.
- **The status item is not a window of the app's** (`CGWindowListCopyWindowInfo` lists none): its frame comes from the app's `AXExtrasMenuBar` children, and `screencapture -R` of that rectangle photographs it beside its neighbours; its menu, pressed open, is a layer-101 window captured by ID. Photograph each face, not the idle one alone: that is how the attention face was found drawing black ink on the dark bar (its baked bitmap keyed on an appearance resolved before the button followed the bar).
- **A locked screen fails `screencapture -R`** ("could not create image from rect", display awake) and turns a fresh instance's tree into the application element, while `screencapture -l <windowID>` still photographs the window with its content. Poll `CGSessionCopyCurrentDictionary`'s `CGSSessionScreenIsLocked` before a shot and after a long wait, testing the key's presence: it is absent, not false, while unlocked — a waiter matching `locked=0` slept through the unlock on 2026-10-09. The bar photographs taken then: the idle, attention and empty faces of scratch instances and the user's own item, all in the bar's white ink, the user's attention face byte-identical to the scratch one's.

### Not verified

- **Input the accessibility API cannot give** — posting real events would land in whatever app is in front: double-click or Return opening an item at the pane's backup time; ← on a sidebar backup row and the row's *Hide This Plan's Backups* menu; Return and Esc in the Files tab's search hits; right-click menus (Show Versions on the Restore pane and Find Files, Show Files on a group); dragging the tree's edge or items to Finder. The router, `preferredVersion` and `BackupShelves.page(of:)` behind them are unit-tested.
- **A group's or a lineage's Files tab by click**: captured, not pressed (the plan page's toolbar picker).
- **Restore… and Restore Folder… through the destination sheet** — into a scratch folder, never the real Desktop.
- **Try Again on a failed level** (only the load key's change is unit-tested).
- **A remote repository** (`restic find` and the index read over a network): none was available.
- **A Files pane keeps the backup it was left at** in its final form (the pick written only when the user picks): not clicked, the accessibility API had stopped answering. Show Versions on the item already selected reopening its pane is tested only by the router's count (`filesPaneOpenings`).
- **The Files tab's search at scale** — the scroll on a long hit list, a disk line naming an older version or none (unit-tested only).
- **Dark mode** of the plan page's paused, manual and running states; dark mode and VoiceOver over the Files tab's search field, its hits, the change marks and lines, and the disk line.
- **Whether opening Settings activates the app.**

## Not handled

**AppKit's reentrancy warning** ("Application performed a reentrant operation in its NSTableView delegate. This warning will become an assert in the future.") is an AppKit bug, filed through Feedback Assistant on 2026-10-04 as **FB25056668** (macOS › AppKit, Incorrect/Unexpected Behavior), resolution Open; nothing to fix here yet.

- Any NSTableView with automatic row heights logs it when first filled with more than 200 rows, and every SwiftUI List is one: a three-line app with `List(0 ..< 201)` logged it on 3 of 3 launches, 200 rows on 0 of 3; a plain AppKit table with 201 rows and not 200, nor with automatic row heights off (macOS 27.0.1, Xcode 27.0, 2026-10-04). The reentrancy is in AppKit's row-height cache: `-[NSTableRowHeightData _cacheRowSpansInRange:heightProvider:]` resizes the table and re-enters itself on the same stack, no app frame on it.
- Here, the folder pane's listing of a 260-file folder logged it on every launch that showed it (16). Any List past 200 rows should too — the Files tree with several large folders open (its cap is per folder), the Restore pane — not checked. Three app-side changes did not stop it, as the bug's shape explains: an equatable listing, "Reading…" on the pane's first read only (kept for its own sake), keeping the list mounted. A SwiftUI List cannot turn automatic row heights off.
- The report's text and its one attachment (the two samples and the backtrace, zipped) are in `~/Downloads/NSTableView-201-rows-feedback/`; no sysdiagnose was sent (the user's choice). Check it when a macOS update ships, and before trusting a List past 200 rows on a release where the warning has become an assert.
