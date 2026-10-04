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

Five timing tests failed now and then under load and passed on a re-run. On
2026-10-04, 5 of 13 `./build.sh test` runs failed on one or more of the first
four, and the fifth failed in 1 of 6 later runs. Other work on the Mac held
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

How the fixes were proved, each at the line that failed:
- **Before.** A stand-in for load on the one term each threshold bet on made each old test fail with its recorded message: the shell living 2 s; 4 s before the first status line; a 3 s gap between lines; the backup's task waiting 11 s before it spawns the stub; the remembered re-run starting 11 s late.
- **After.** The fixed tests pass under the same stand-ins: 96 tests in the four suites.
- **Still able to fail.** With the remembered refresh dropped, the refresh test fails in 0.4 s. With the status line delivered after the stub gave up waiting, the status-line test fails.
- **Natural failures.** A full run that afternoon, before the fixes, failed the grandchild and stall-cap tests on its own, with their recorded messages.

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
the folder or file to select), `SWIFTRESTIC_CAPTURE_TAB` (`files`: the
selected plan or group page on its Files tab), `SWIFTRESTIC_REPO_PASSWORD`,
`SWIFTRESTIC_POWER_SOURCE` (`battery`/`ac`; read at scheduler ticks, so only
in a normal launch — a capture run never arms the scheduler),
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
  user's actual repositories and never touches the login Keychain. Capture
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
- a file pane: "3 versions in 4 backups", with sizes matching the demo files (seen when the pane still sat beside the sidebar's tree; the pane is unchanged);
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
- 1,000 backups (a scratch repository of 2,060 files, three changing per backup; local disk; other work loading the Mac): the index read all of it from empty in 8 min 56 s; the file pane said "100 versions in 1,000 backups" and had every version's Modified and size by the capture, 30 s in. Its `restic find` alone took 6.9–8.5 s, three runs, against 0.6 s at 12 backups.

### Not verified

- **Input the accessibility API cannot give.** Double-click or Return opening an item at the pane's backup time, right-click menus (Show Versions on the Restore pane and Find Files, Show Files on a group), dragging the tree's edge or items to Finder: `AXShowMenu` is unsupported on the rows or opens nothing, and posting real events would land in whatever app is in front on a Mac in use. The router and `preferredVersion` behind them are unit-tested.
- **A group's or a lineage's Files tab by click.** Captured, not pressed; it is the same toolbar picker as the plan page's.
- **Restore… and Restore Folder… through the destination sheet.** Whoever runs one restores into a scratch folder, never the real Desktop.
- **Try Again on a failed level** (only the load key's change is unit-tested).
- **The "N more items…" row.** A 260-file folder open in the tree put it below the window, and the tree does not scroll a selected item into view, so the capture could not reach it. The 200-item cap is unit-tested.
- **A remote repository** (`restic find` and the index read over a network): none was available.
- **The upgrade's reread of real repositories** (schema 3 drops every index file). The 1,000-backup scratch read above is the only timing.
- **Dark mode** of the plan page's paused, manual and running states.

### Not handled

- **A Files pane's chosen backup is lost on leaving the page.** Show in Backups and back finds the folder still selected but its pane at the newest backup again: the choice is the pane's own state, the tab and the selection are the router's.
- **The tree does not scroll a selected item into view.** Seen with `SWIFTRESTIC_CAPTURE_ITEM` on the 43rd file of an open folder. Show Versions selects the same way, so a deep item can land out of sight.
- **The file pane's `restic find` grows with the backups** (6.9–8.5 s at 1,000, above). It searches every backup; the rows need one per version, and `restic find` takes `--snapshot` more than once: given one backup per version there (100 of the 1,000), it took 1.9–2.2 s, two runs.
- **AppKit's reentrancy warning.** One launch on Files (the scale repository, `SWIFTRESTIC_CAPTURE_PANE=files` with a folder item) logged "Application performed a reentrant operation in its NSTableView delegate. This warning will become an assert in the future." Other launches on Files did not.
