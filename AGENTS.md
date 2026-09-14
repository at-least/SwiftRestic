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

## Photographing the app

Debug captures are driven by environment variables on a debug build —
`SWIFTRESTIC_CAPTURE`, `SWIFTRESTIC_CAPTURE_PANE` (one pane or `all`),
`SWIFTRESTIC_CAPTURE_DELAY`, `SWIFTRESTIC_APPEARANCE`,
`SWIFTRESTIC_CAPTURE_SHEET`, `SWIFTRESTIC_REPO_PASSWORD`. All are documented
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
