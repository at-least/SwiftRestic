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

Two facts for the next scripted run:
- An agent's shell runs in the Background launchd session (`launchctl managername` says so). An app it launches cannot be activated, and System Events sees no windows. The run worked only after it launched the app inside the user's Aqua session through a temporary gui-domain LaunchAgent; boot such an agent out the moment the run ends.
- Address the scratch instance by its PID, never by name: the user's own SwiftRestic can be running against the real configuration at the same time.

### Not verified

- **Plan page states other than idle and scheduled.** Not seen:
  - Back Up Now turning into Stop while a backup runs;
  - Resume Schedule while the plan is paused;
  - no Schedule control on a manual plan;
  - the list of lengths under the Pause arrow.
  None of the cards' buttons was clicked either.
- **Interaction in the Files tab.** Not exercised:
  - a group's or a lineage's Show Files menu item, and their pages' Files tabs by click;
  - the Plan menu's Back Up Now being enabled while a plan's Files tab shows (read only on the repository page, where it is rightly grey);
  - a relaunch opening a page on Overview after it was left on Files;
  - dragging the tree's edge, and the edge's bounds at the 940 pt minimum window with a wide sidebar;
  - double-click or Return opening an item at the backup time the pane had chosen. `preferredVersion` and the router's hint being spent once are unit-tested; the wiring between them is not;
  - dragging items to Finder;
  - Restore… and Restore Folder… through the destination sheet. Whoever runs one restores into a scratch folder, never the real Desktop;
  - Show in Backups, and coming back to the page on its Files tab (the router keeping the tab is unit-tested);
  - Try Again on a failed level (only the load key's change is unit-tested);
  - Show Versions from the Restore pane's item menu and from Find Files' results (the page each lands on and the route are unit-tested; the menu items were not clicked).
- **The tree's fallback through restic.** A plan the index holds nothing of yet is listed from its newest backup with `restic ls` (`FilesTree`). No test and no capture reached that branch.
- **Scale.**
  - How the tree responds with thousands of rows open. The 200-item cap is unit-tested, but its "N more items…" row was never shown live.
  - The file pane's single `restic find` per opened file, on a repository with about 1,000 snapshots or on a remote one. The only timing is 0.6 s, measured locally on 20,000 files × 12 snapshots.
- **The first launch after the upgrade.** Schema 3 deletes every existing index file and reads it again. That mismatch path is tested with `user_version` 99, but how long the reread takes on real repositories was not measured.

### Not handled

- **The flaky timing tests.** Fixed; see Build.
