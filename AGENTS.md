# AGENTS.md

Working rules for AI agents (and humans driving scripts) in this repo:
pointers into the README, plus the capture and verification discipline that
each cost a debugging session to learn.

## Build

Always build through `./build.sh`: it regenerates the Xcode project with
xcodegen first, and xcodegen snapshots the source file list, so new files are
invisible to `xcodebuild` until it runs. `./build.sh test` runs unit plus
end-to-end tests against real restic.

Two rules the flaky-run hunt of 2026-09-14 added:

- Never pipe `xcodebuild` through `head` (or anything that closes its stdout
  early) — a truncated pipe orphans the invocation, and an agent shell may
  return before xcodebuild is gone. `./build.sh` already tees the full log;
  read that, or redirect to a file and tail it.
- Concurrent `xcodebuild test` sessions on one machine can stomp each other's
  testmanagerd sessions: the loser's runner is SIGTERM'd mid-run ("Test
  crashed with signal term"), xcodebuild restarts it, the remaining tests
  pass, and the run is marked failed. The script therefore refuses to start
  `test` while another xcodebuild exists, and fails any run whose log shows
  the restart banner — which also fires for a plain test crash or timeout,
  so read the xcresult before blaming a collision.

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
| "the retention preview is a dry run that works while a backup holds the lock" | 1 of 18 on 2026-10-09 | `Expectation failed: … snapshots(…, planID: plan.id).count == 3` (ResticIntegrationTests.swift:347) after 228 s against its usual 12–20, the whole run 1914 s against ~565; the second of its two issues, the control forget that ran, never reached the log | The backup that holds the lock reads its stdin from a shell waiting for a file the test writes after the control forget, where `/bin/sleep 30` had let the lock go while the preview and the forget were still starting; the wait for its lock is 120 s, not 20 |

How the fixes were proved, each at the line that failed:
- **Before.** A stand-in for load on the one term each threshold bet on made each old test fail with its recorded message: the shell living 2 s; 4 s before the first status line; a 3 s gap between lines; the backup's task waiting 11 s before it spawns the stub; the remembered re-run starting 11 s late.
- **After.** The fixed tests pass under the same stand-ins: 96 tests in the four suites.
- **Still able to fail.** With the remembered refresh dropped, the refresh test fails in 0.4 s. With the status line delivered after the stub gave up waiting, the status-line test fails.
- **Natural failures.** A full run that afternoon, before the fixes, failed the grandchild and stall-cap tests on its own, with their recorded messages.
- **The sixth, 2026-10-09.** A 31 s sleep between the holder's lock and the preview — the stand-in for the load that stretched that run — failed the old test in 51 s with its two issues, "Issue recorded" at the forget that ran and the count at 347; the fixed test passed under the same sleep in 45 s; with the release written before the control forget instead, it failed in 51 s with the same two issues.

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

Debug captures are driven by environment variables on a debug build —
`SWIFTRESTIC_CAPTURE`, `SWIFTRESTIC_CAPTURE_PANE` (one pane or `all`),
`SWIFTRESTIC_CAPTURE_DELAY`, `SWIFTRESTIC_APPEARANCE`,
`SWIFTRESTIC_CAPTURE_SHEET`, `SWIFTRESTIC_CAPTURE_ITEM` (with pane `files`:
the folder or file to select), `SWIFTRESTIC_CAPTURE_SEARCH` (with pane
`files`: the query in the tab's search field), `SWIFTRESTIC_CAPTURE_TAB` (`files`: the
selected plan or group page on its Files tab), `SWIFTRESTIC_CAPTURE_FIND`
(with pane `find`: a search run on arrival), `SWIFTRESTIC_REPO_PASSWORD`,
`SWIFTRESTIC_POWER_SOURCE` (`battery`/`ac`; read at scheduler ticks, so only
in a normal launch — a capture run never arms the scheduler),
`SWIFTRESTIC_NETWORK` (`metered`/`unmetered`, for the metered-network hold),
`SWIFTRESTIC_LOGIN_ITEM_INSTALLABLE` (`1` shows the start-at-login offers'
button from a build folder; registering still refuses there, so nothing is
ever registered). All are documented
in the README under "Looking at the app"; read that section before the first
capture. Everything in the next two sections was verified live on 2026-09-14:
macOS 26 / Xcode 26.6, one display (2940×1912 pixels, 1470×956 points @2x),
light mode.

### Rules

- **Never point a capture run at the real configuration.** Set
  `SWIFTRESTIC_CONFIG_DIR=/tmp/...` so the run cannot see or refresh the
  user's actual repositories and never reads the login Keychain for a
  password. Writes still go there: never save a repository editor or press
  Change Password in a scratch run. Capture
  runs do not arm the scheduler, so no backup fires mid-capture — but
  snapshot refreshes against real remotes are still waste and risk.
- **One output directory per agent and run.** A shared fixed filename gets
  overwritten by the next agent before the first one reads it.
- **Never substitute a full-screen capture for the window capture.**
  Full-screen is exactly what makes concurrent agents photograph each other.
- **Run `caffeinate -u` before every scripted shot.** The sweep already does;
  any custom capture script must do the same (see "sleeping display" below).
- **Read the backend line in stderr** after every capture (see below).

### Verified behaviour

- **Captures are occlusion-proof.** With another app's full-screen window
  covering the target (coverage of the window rect measured at 99.91% and
  99.90% by a full-screen screenshot taken at capture time), captures still
  showed the window's full correct content: the diff against unoccluded
  baselines was 0.74% of pixels for a single shot and 0.37–1.34% per sweep
  pane, while the occluder's colour never appeared (0.0000% strict-leak
  pixels, 0.0000% pinkish glass-bleed pixels).
- **Occluded captures wear inactive-window chrome.** Grey traffic lights,
  dimmed labels and desaturated accent buttons: standard macOS for a non-key
  window, not a regression, and not fixable at capture level. When comparing
  runs whose activation state differs, expect up to ~1.3% pixel difference,
  all in chrome — mask the chrome or tolerate it rather than chasing it.
- **The window re-renders while covered — for this app's SwiftUI content.**
  The all-panes sweep switches panes programmatically under full occlusion
  and each pane's content lands in its capture: the occluded pane images
  differ from each other by 3.1–4.7% and match their unoccluded counterparts
  to within chrome. Do not assume a covered window photographs a stale frame.
  (The sweep run's occlusion was not re-proved mid-sweep — inferred from the
  same occluder plus zero colour leak; the single-shot runs' coverage was
  measured directly.)
- **`screencapture -l <windowID>` is equivalent.** On macOS 26 its output was
  pixel-identical to the app's ScreenCaptureKit shots, occluded and not — for
  scripted per-window shots outside the app this is the tool. The target
  window must be on the current Space, not minimized or hidden, and the
  calling terminal needs Screen Recording permission.
- **When a sheet is up, the sheet — not the main window — is photographed.**

### Failure modes

The preferred backend is ScreenCaptureKit, on a 6-second leash. Each capture
logs one of these lines to stderr:

| stderr line | Meaning |
| --- | --- |
| `capture backend: cacheDisplay` | Screen Recording permission was missing (grant it per the README); Tahoe's glass photographed black |
| `failed` | ScreenCaptureKit unauthorised |
| `timed out` | The 6-second leash ran out |
| `found no window N on screen` | ScreenCaptureKit could not find the window it was asked for |

**A sleeping display poisons everything.** Re-verified 2026-09-14 by forcing
`pmset displaysleepnow` on the single display and capturing while asleep
(`CGDisplayIsAsleep`=true, active-display count 0): full-screen
`screencapture -x` still exits 0 but returns a pure-black frame (pixel
stddev 0.00), and `screencapture -l <windowID>` fails on *unoccluded*
windows — both a SwiftRestic and a Postico window — with exit 1 and "could
not create image from window". That is the same error text a missing Screen
Recording permission produces (also verified: with the display awake and
permission absent, `-x` and `-l` fail identically), so the text alone is not
diagnostic. The discriminators are the exit code and the black frame:
missing permission fails `-x` too (exit 1, no file); a sleeping display lets
`-x` succeed as a uniform frame. Probe with `screencapture -x` and check for
near-zero pixel variance — near-zero means asleep. Wake with
`caffeinate -u -t 3` and retry. (Existing on-screen windows stay listed in
`CGWindowListCopyWindowInfo` while asleep; only capture of them fails. Whether
a *newly created* window registers while asleep was not tested. pgweb's
`docs/postico-observations.md` §27.5 records `screencapture -l` working after
its `list_displays` emptied; that state was evidently not a true single-
display sleep, because a true one fails here.)

### Re-verifying the occlusion behaviour

The verification was assertion-driven: two unoccluded baselines must be
pixel-identical (content is deterministic — 0.0000 measured), an occlusion
proof (full-screen screenshot at capture time, ≥99% of the window rect covered
— count the occluder's own label pixels as covered, or the proof reads 97.7%
and fails), the stderr backend line, a diff tolerant of ≤~1.3% chrome-only
pixels, and a colour-leak check. Self-test the comparator first: it must pass
on identical images and fail hugely on a solid colour — a comparator that has
never failed is untested.

### Untested territory

Minimized or hidden windows, other Spaces, multiple displays, dark mode's
vibrancy materials (README records that a locked screen hides the window from
capture entirely). The pixel identity between `screencapture -l` and the
ScreenCaptureKit pipeline shows both read the same WindowServer surface —
equivalence, not independent confirmation.

## Open items from the Files view redesign

The 2026-10-04 redesign (`8305539`..`a561666`) added the Files view and the plan page's cards. A follow-up the same day (`f461728`..) moved the Files view out of the sidebar, whose Backups | Files control and ⌘1/⌘2 are gone, onto the pages: a plan's page and every Other backups group's — an untagged lineage gained a page for it — have Overview | Files in the window toolbar. The items below are open.

What was checked live, one capture each, in light mode, against a scratch configuration:
- the plan page, idle and scheduled;
- a plan's Files tab, its first folder opened and selected on a first visit;
- a plan-UUID group's Files tab, an untagged lineage's page and its Files tab;
- a file pane: "3 versions in 4 backups", with sizes matching the demo files (seen when the pane still sat beside the sidebar's tree; that header line is gone since `0e9923f`);
- the Files tab on a first launch after the repository gained and lost backups — wrong before `0ede383`, right after;
- the window not overflowing with a long root path, after the split moved from HSplitView to an HStack (`939fa63`);
- dark mode of the plan page, a plan's Files tab, a lineage's page and a group's Files tab.

Clicked live the same day, through the accessibility API against a scratch instance, with its window captured after each step:
- the sidebar without its old control, and the View menu without Show Backups or Show Files;
- the plan row opening its page on Overview, the toolbar showing Overview | Files;
- pressing Files: the tab opened with the plan's first folder selected and open;
- a folder's chevron opening it, and selecting a subfolder moving the pane to it, keeping the chosen backup.

The rest of that run stalled. About 20 minutes in, macOS raised a Screen Recording consent dialog (`universalAccessAuthWarn`), the instance lost activation for good, and accessibility reads failed across the system.

Facts for the next scripted run:
- An agent's shell runs in the Background launchd session (`launchctl managername` says so). An app it launches cannot be activated, and System Events sees no windows. The run worked only after it launched the app inside the user's Aqua session through a temporary gui-domain LaunchAgent; boot such an agent out the moment the run ends.
- Later that day the accessibility API did work, for half an hour, on instances launched straight from an agent's shell, with the consent dialog still open: reading the tree, `AXPress`, setting `AXSelected` on sidebar rows, reading the menu bar. Nothing needed activation. Then it stopped again: `AXWindows` answered with the application element, for a fresh instance too.
- A popup's menu closes when the process that opened it exits: open it and press the item in one process. SwiftUI list rows' context menus are out of reach: `AXShowMenu` is unsupported on the rows and opens nothing on their text.
- A helper binary compiled during such a run can take a minute or two to start the first time. That afternoon two took 65 s and 110 s, while syspolicyd ran at 40–50% CPU and logged "Error checking with notarization daemon". Launches killed after 10–60 s did not shorten the next one's wait, so let one finish before timing anything.
- Address the scratch instance by its PID, never by name: the user's own SwiftRestic can be running against the real configuration at the same time.

Checked live later the same day, against scratch copies of that configuration:
- the plan page's other states, one capture each: paused ("Paused — Daily at 09:30", Resume Schedule, next backup "Paused"); paused for two hours ("Paused until 4:56 PM — Daily at 09:30", Resume Schedule, next backup tomorrow at 09:30); manual (the Schedule card says Manually and has no Pause control); running (the Backups card's Back Up Now is Stop, next backup "Running now", the hook strip above with Cancel). The running state needed a normal launch: `SWIFTRESTIC_CAPTURE_PANE` lands on its pane without `SWIFTRESTIC_CAPTURE`, so the scheduler stays armed, and an overdue plan whose before-backup hook sleeps holds the run while `screencapture -l` takes the window;
- the Pause arrow, opened through the accessibility API: For 1 Hour, Until Tomorrow, Until I Resume. No length was chosen;
- through the accessibility API, on a plan page: pressing Files; the Plan menu with Back Up Now, Edit Plan… and Pause Schedule enabled there (Stop Backup grey); the repository page, which has no segment, and back to the plan on Files; an older backup chosen in a folder's pane, then Show in Backups — the Restore pane opened at that backup with the folder selected and open, its plan's fold open — and back to the plan on Files with the folder still selected;
- a relaunch: the plan page opened on Overview after the last session left it on Files;
- 1,000 backups (a scratch repository of 2,060 files, three changing per backup; local disk; other work loading the Mac): the index read all of it from empty in 8 min 56 s; the file pane said "100 versions in 1,000 backups" (a header line `0e9923f` has since removed) and had every version's Modified and size by the capture, 30 s in. Its `restic find` alone took 6.9–8.5 s, three runs, against 0.6 s at 12 backups.

### Not verified

- **Input the accessibility API cannot give.** Double-click or Return opening an item at the pane's backup time, right-click menus (Show Versions on the Restore pane and Find Files, Show Files on a group), dragging the tree's edge or items to Finder: `AXShowMenu` is unsupported on the rows or opens nothing, and posting real events would land in whatever app is in front on a Mac in use. The router and `preferredVersion` behind them are unit-tested.
- **A group's or a lineage's Files tab by click.** Captured, not pressed; it is the same toolbar picker as the plan page's.
- **Restore… and Restore Folder… through the destination sheet.** Whoever runs one restores into a scratch folder, never the real Desktop.
- **Try Again on a failed level** (only the load key's change is unit-tested).
- **A remote repository** (`restic find` and the index read over a network): none was available.
- **The upgrade's reread of real repositories** (schema 3 drops every index file). The 1,000-backup scratch read above is the only timing.
- **Dark mode** of the plan page's paused, manual and running states.

Fixed after that run, each checked where it was seen:
- **A Files pane keeps the backup it was left at.** The router remembers each item's pick (`filesChosenVersion`), the newest as nothing, written only when the user picks, and a pane opens at the era one level up when it holds the item, else at that pick, else the newest (`preferredVersion(previousID:rememberedID:)`, unit-tested for folders and files). Seen through the accessibility API on an earlier form of the fix, which wrote on every change: Photos at Oct 2 kept it through Show in Backups and back; a file's fourth version kept it through a trip to the repository page. The final form was not clicked again — the API had stopped answering. Show Versions asked for the item already selected now opens its pane again (`filesPaneOpenings`); only the router's count is tested.
- **The tree brings a selected item into view**, once, when its row or its folder's "more items" row is listed (`FilesTree.row(showing:in:)`, unit-tested). Captured: the 43rd file of an open folder, out of sight before, in view after; a file past the 200-item cap brought the "60 more items…" row into view — the first time that row was seen live.
- **The file pane's `restic find` names each version's newest backup** (`--snapshot`, up to 2,000, past that every backup), the only rows it reads. A real-restic test pins the narrowing and that a name restic no longer holds is skipped (a stderr warning, exit 0, restic 0.19.1). Timed with the pane's exact arguments, 100 of the 1,000 backups against all: 1.6 s of CPU against 10.9 s (28–33 s and 156 s of wall time that hour, at load averages near 60).
- **The pane no longer swaps its view for "Reading…" on every re-read** while the index has not reached the item: only the first read shows it. Before, the folder view was made anew each time — four times in one minute of the setup below, once after.

### The search field and the trimmed panes (2026-10-05)

`deaace2`..`a35ee15` put a search over each Files tab's tree, sent ⇧⌘F and the magnifier there on plan and group pages, cut the panes to what picks a copy, and added a folder's changes since the backup before and the file's state on this Mac. Seen live on the demo configuration, light mode:
- captures: hits for "notes" and "onboarding" (the dropped checklist dimmed, "until Oct 2"), a search with no match and Search All Backups…, the trimmed file and folder panes, "On this Mac: the same as the newest version" and "Not on this Mac", the folder change lines;
- the ⇧⌘F route (capture pane `filesSearch`): the window's first responder became the field's editor, and on the plain `files` pane it stays the tree;
- through the accessibility API on a scratch instance: a hit picked, then the field's clear button pressed — the tree came back with the hit's folders open and its row selected; Quarterly at Oct 2 ("2 modified", two rows Modified) and Reports at Oct 3 ("1 removed", the checklist named), both as `restic diff` of the same backups says.

Not verified: Return and Esc in the hits, and the scroll on a list long enough to need it (no key could be posted safely); the hits at scale; a disk line naming an older version or none (unit-tested only); dark mode and VoiceOver over the field, the hits, the change marks and lines, and the disk line.

Facts for the next scripted run:
- A capture run that stops on a precondition (`findMoved` on a one-repository configuration does) leaves macOS's "reopen windows?" prompt, which then hangs every later run of the app — capture or not — until answered. Launch with `-ApplePersistenceIgnoreState YES`.
- A popup's menu items carry a narrow no-break space (U+202F) before AM and PM: match titles after flattening it.

### Round 4 of the Arq comparison (2026-10-09)

`136ae15`.. built round 4's stages against a scratch copy of the demo configuration, driven through the accessibility API without a capture run. Facts for the next scripted run:
- **A normally launched instance never takes focus.** Launch the Debug binary itself from the agent shell — `DerivedData/…/Build/Products/Debug/SwiftRestic.app/Contents/MacOS/SwiftRestic`, not `open` — with `SWIFTRESTIC_CONFIG_DIR`, `SWIFTRESTIC_REPO_PASSWORD` and `-ApplePersistenceIgnoreState YES`, and without `SWIFTRESTIC_CAPTURE`: the window is created without activation, the accessibility API drives it (the sidebar's `AXOutline` named Sidebar, its rows set through `AXSelected`, the toolbar's Overview | Files segments, a drawer's and a sheet's buttons by description), and `screencapture -x -o -l <CGWindowID>` photographs it, a sheet composited on the window. Quit it through its application menu, by PID. A capture run (`SWIFTRESTIC_CAPTURE`) activates the app on purpose and keeps the user's input for its whole delay — on 2026-10-07 a 480 s delay took it — so keep capture runs to the pane presets with a short delay, and check the user's idle time (`ioreg -c IOHIDSystem`, HIDIdleTime) before any scripted session.
- **Such a launch runs what is due.** Switch every plan's `isEnabled` off and the repositories' check and prune off in the scratch configuration, so nothing starts and no "Quit SwiftRestic?" prompt follows the quit; the captions then read "Paused — …", which the notes must say.
- **The snapshot index warms during such a launch.** Poll `select * from chain` in `<configDir>/index/<repositoryUUID>.sqlite`: the fourth column counts down to 1 as the chain is read, the fifth is the total; 495 small backups took about six minutes under load. Keep that configuration folder as the warm one for later runs. A Files tab's steps need the listing in: wait for the tree's "509 backups" value.
- **The tree still sometimes answers with the application element** for a fresh instance (as 2026-10-04 recorded); kill it by PID and launch again, else record the check as not seen live.
- A popup's menu opens and holds through `AXPress` from a process that then stays alive (the session's `ax openhold`); a `Menu` button's does the same. A SwiftUI list row's context menu and a key press are still out of reach: nothing is posted to a Mac in use.
- **The status item is not a window of the app's.** `CGWindowListCopyWindowInfo` lists none for it; its frame comes from the app's `AXExtrasMenuBar` children (position and size), and `screencapture -R` of that rectangle photographs it in the bar, beside its neighbours. Its menu, once pressed open, is a layer-101 window of the app's and is captured by ID. The photograph is what found the attention face drawing black ink on the dark bar (the baked bitmap keyed on an appearance resolved before the button followed the bar): photograph each face, not the idle one alone.
- **A locked screen fails `screencapture -R`** ("could not create image from rect", the display awake), and the accessibility tree of a fresh instance answered with the application element while it was locked; `screencapture -l <windowID>` still photographed the instance's window with its content. `CGSessionCopyCurrentDictionary`'s `CGSSessionScreenIsLocked` says whether it is locked: poll it before a scripted shot and after a long wait. The key is absent, not false, while the screen is unlocked — a waiter that matched `locked=0` slept through the unlock on 2026-10-09, and the bar photographs waited until the user was back — so test for the key's presence. Taken then: the idle, attention and empty faces of scratch instances and the user's own item, all in the bar's white ink, the attention face of the user's instance byte-identical to the scratch one's.
- **To see a surface before the listing lands**, point the scratch configuration's `resticPathOverride` at a wrapper that sleeps on `snapshots` and execs restic otherwise: the listing is held for as long as the wrapper says while every other command runs at once. A cold index (no `index` folder) makes Find Files take the restic engine.
- **A Table's cells follow their row's data.** A lookup held by the parent view and read in a cell closure did not re-render the cells when the lookup changed; rewriting the rows did.
- **A submenu opens through the accessibility API** while a process holds its menu open: `AXPress` on the month item of the Files pane's "As backed up" menu and of the Compare sheet's "Compared with" menu opened its submenu, both photographed with their rows (the scratchpad's axshot `holdsub:` step, 2026-10-09 after the unlock). An Activity row is selected through its `AXRow` — above the cell, which holds the hosting group the text sits in — not through the cell. The plan page's problem card is one `AXButton` to the tree — its item lines' ⋯ menus cannot be opened that way.
- **A partial skip merges live.** Two Back Up Now runs of a scratch Journal plan with a second source under an absent `/Volumes/…`, the plan paused: one Skipped record in Activity, "“Archive SSD” is not connected; the other folders were backed up. Skipped 2 times since …", on disk with `skipCount` 2 and the first run's snapshot in `continuedSnapshotIDs`, the repository two backups richer. Point the scratch repository at a copy first: the runs write to it.

### Not handled

- **AppKit's reentrancy warning** ("Application performed a reentrant operation in its NSTableView delegate. This warning will become an assert in the future."). An AppKit bug, reported to Apple as FB25056668 (last point); nothing to fix here yet:
  - Any NSTableView with automatic row heights logs it when first filled with more than 200 rows, and every SwiftUI List is one. A three-line SwiftUI app with `List(0 ..< 201)` logged it on 3 of 3 launches, with 200 rows on 0 of 3. A plain AppKit table logged it with 201 rows and not with 200, nor with automatic row heights off. macOS 27.0.1, Xcode 27.0, 2026-10-04.
  - The reentrancy is inside AppKit's row-height cache: `-[NSTableRowHeightData _cacheRowSpansInRange:heightProvider:]` resizes the table and enters itself again on the same stack, with no app frame on it.
  - In SwiftRestic, the folder pane's listing of a 260-file folder logged it on every launch that showed it (16). By the same rule any List here past 200 rows should too — the Files tree with several large folders open (its cap is per folder), the Restore pane — not checked.
  - Three app-side changes did not stop it, as the bug's shape explains: comparing the listing as equatable, the flicker fix above (kept for its own sake), and keeping the list mounted. A SwiftUI List cannot turn automatic row heights off.
  - Filed through Feedback Assistant on 2026-10-04 as **FB25056668** (macOS › AppKit, Incorrect/Unexpected Behavior), resolution Open. Its text and its one attachment — the two samples and the backtrace, zipped — are in `~/Downloads/NSTableView-201-rows-feedback/`. No sysdiagnose was sent (the user's choice). Check the report when a macOS update ships, and before trusting a List past 200 rows on a release where the warning has become an assert.
