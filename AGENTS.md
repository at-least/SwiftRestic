# AGENTS.md

Working rules for AI agents (and humans driving scripts) in this repo: pointers
into the README, plus the capture and verification discipline that each cost a
debugging session to learn. Everything under "verified" was measured live on
2026-09-14, macOS 26 / Xcode 26.6, one display (2940×1912 pixels, 1470×956
points @2x), light mode.

## Build

`./build.sh` regenerates the Xcode project with xcodegen before building:
xcodegen snapshots the source file list, so new files are invisible to
`xcodebuild` until it runs — always build through the script. `./build.sh test`
runs unit plus end-to-end tests against real restic.

## Photographing the app

Debug captures are driven by environment variables on a debug build —
`SWIFTRESTIC_CAPTURE`, `SWIFTRESTIC_CAPTURE_PANE` (one pane or `all`),
`SWIFTRESTIC_CAPTURE_DELAY`, `SWIFTRESTIC_APPEARANCE`,
`SWIFTRESTIC_CAPTURE_SHEET`, `SWIFTRESTIC_REPO_PASSWORD` — all documented in
the README under "Looking at the app". Read that section before the first
capture. Two safety rules it implies, worth restating:

- **Never point a capture run at the real configuration.** Set
  `SWIFTRESTIC_CONFIG_DIR=/tmp/...` so the run cannot see or refresh the
  user's actual repositories and never touches the login Keychain. Capture
  runs do not arm the scheduler, so no backup fires mid-capture — but
  snapshot refreshes against real remotes are still waste and risk.
- **One output directory per agent and run.** A shared fixed filename gets
  overwritten by the next agent before the first one reads it.

What the README does not record is how captures behave under concurrency, and
what the stderr log means. Verified live (2026-09-14):

1. **Captures are occlusion-proof.** With another app's full-screen window
   covering the target (coverage of the window rect measured at 99.91% and
   99.90% by a full-screen screenshot taken at capture time), captures still
   showed the window's full correct content: the diff against unoccluded
   baselines was 0.74% of pixels for a single shot and 0.37–1.34% per sweep
   pane, while the occluder's colour never appeared (0.0000% strict-leak
   pixels, 0.0000% pinkish glass-bleed pixels). Never substitute a full-screen
   capture for the window capture — full-screen is exactly what makes
   concurrent agents photograph each other.
2. **Occluded captures wear inactive-window chrome.** Grey traffic lights,
   dimmed labels and desaturated accent buttons: standard macOS for a non-key
   window, not a regression, and not fixable at capture level. When comparing
   runs whose activation state differs, expect up to ~1.3% pixel difference,
   all in chrome — mask the chrome or tolerate it rather than chasing it.
3. **The window re-renders while covered — for this app's SwiftUI content.**
   The all-panes sweep switches panes programmatically under full occlusion
   and each pane's content lands in its capture: the occluded pane images
   differ from each other by 3.1–4.7% and match their unoccluded counterparts
   to within chrome. Do not assume a covered window photographs a stale frame.
   (The sweep run's occlusion was not re-proved mid-sweep — inferred from the
   same occluder plus zero colour leak; the single-shot runs' coverage was
   measured directly.)
4. **`screencapture -l <windowID>` is equivalent.** On macOS 26 its output was
   pixel-identical to the app's ScreenCaptureKit shots, occluded and not — for
   scripted per-window shots outside the app this is the tool. The target
   window must be on the current Space, not minimized or hidden, and the
   calling terminal needs Screen Recording permission.
5. **A sleeping display poisons everything.** Screenshots come back as one
   uniform colour, CGWindowList stops listing new windows, and
   `screencapture -l` fails on *unoccluded* windows with "could not create
   image from window" — the same error text a missing Screen Recording
   permission produces. Probe with a full-screen `screencapture -x` and check
   for near-zero pixel variance: that means asleep, not unauthorised. Wake
   with `caffeinate -u -t 3` and retry. The sweep already runs `caffeinate -u`
   before every shot; any custom scripted capture must do the same.
6. **Read the backend line and know the failure modes.** The preferred backend
   is ScreenCaptureKit; `capture backend: cacheDisplay` in stderr means Screen
   Recording was missing and Tahoe's glass photographed black. ScreenCaptureKit
   sits on a 6-second leash, and three distinct stderr lines name the three
   ways it can lose: `failed` (unauthorised), `timed out` (leash ran out),
   `found no window N on screen`. When a sheet is up, the sheet — not the main
   window — is what gets photographed.

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
