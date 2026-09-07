# SwiftRestic

A native macOS backup app in the spirit of Arq, with [restic](https://restic.net)
doing the actual work underneath. SwiftUI front end, restic's `--json` output as
the only interface to the engine.

## Build and run

```sh
brew install restic xcodegen   # restic is a runtime dependency, not vendored
./build.sh                     # regenerate the Xcode project + build
./build.sh test                # unit tests + end-to-end tests against real restic
open SwiftRestic.xcodeproj     # or work in Xcode
```

`xcodegen` snapshots the source file list, so `build.sh` regenerates the project
on every build — new files are invisible to `xcodebuild` otherwise.

### App icon

The icon is drawn in code rather than stored as a master image:

```sh
swift Tools/GenerateAppIcon.swift
```

It writes all ten renditions plus `Contents.json` into
`Sources/SwiftRestic/Assets.xcassets/AppIcon.appiconset/`. Because the artwork is
vector, every size is rendered natively instead of being downscaled from one
master, so strokes stay crisp at 16pt. The 16 and 32 pixel renditions deliberately
use a coarser glyph — two thick plates instead of three thin ones — since at that
size the gaps in the full stack fall below a pixel and smudge together. The
variant is chosen by pixel count, so 16pt@2x and 32pt@1x render identically.

Re-run the generator after editing `Tools/GenerateAppIcon.swift`; the PNGs are
checked in so a normal build does not need it.

## What it does

- **Overview dashboard** — what is protected, data written per day for the last
  30 days (stacked by plan), repository sizes, what runs next, and what has gone
  wrong lately.
- **Repositories** — local disk, SFTP, S3-compatible, Backblaze B2, Azure Blob
  Storage, Google Cloud Storage, an rclone remote, or a restic REST server.
  Creating one runs `restic init`; the app refuses to save a repository it could
  not reach.
- **Backup plans** — a set of folders, exclude patterns, a schedule and a
  retention policy, pointed at one repository. Each plan stamps its snapshots
  with a private tag so retention can only ever touch its own.
- **Scheduling** — hourly / daily / weekly, checked once a minute. A daily plan
  whose window passed while the Mac was asleep runs as soon as it wakes rather
  than skipping the day.
- **Browsing and restore** — walk a snapshot one directory at a time, restore a
  single file, a subtree, or the whole snapshot. Per-node restores land in the
  chosen folder with no absolute path rebuilt above them.
- **Find files across snapshots** — search every snapshot for a name or glob when
  you do not know which backup still has the file, then restore the match. ⇧⌘F.
- **Compare snapshots** — *Compare* on any snapshot runs `restic diff` against
  the previous snapshot of the same folders from the same Mac (any earlier one
  can be chosen) and lists what was added, removed or modified, filterable by
  kind and path, with restic's byte totals. Answers "what did last night's
  backup actually pick up?" without restoring anything.
- **Start at login** — the scheduler only runs while the app runs, so SwiftRestic
  can register itself as a login item and sit in the menu bar.
- **Maintenance** — scheduled `check` and `prune` per repository, on a day
  interval, plus manual runs, stale lock removal and repository stats.
- **Hooks** — shell commands before a backup and after success, warnings or
  failure, and per repository before and after a check or prune. Context arrives
  as `SWIFTRESTIC_*` environment variables; a before hook can be set to call the
  run off.
- **Alerts** — webhooks, Slack, Discord and Healthchecks.io, per run outcome.
- **restic console** — run any restic command against a repository and read its
  own output, for the things the UI does not cover.
- **Activity** — every run recorded with its outcome, duration, bytes added and
  the list of files restic could not read.

## Architecture

```
Core/       ResticBinary   locate the executable (GUI apps get a bare PATH)
            ResticRunner   actor: spawn, stream NDJSON, cancel, time out, map exit codes
            ResticMessage  decode restic's --json union
Models/     Repository, MaintenancePolicy, BackupPlan, Schedule, RetentionPolicy,
            BackupHook, NotificationChannel, Snapshot, RunRecord
Services/   ResticService     typed restic commands
            HookRunner        shell hooks, on the same process machinery
            NotificationPoster + payload builders per provider
            OverviewMetrics   dashboard series, kept pure and testable
            SecretStore       Keychain, injectable so tests never touch yours
            ConfigStore, Scheduler, KeychainStore
App/        AppModel       @MainActor @Observable single source of truth
Views/      NavigationSplitView UI, Swift Charts dashboard, restic console
```

Everything runs under Swift 6 strict concurrency. restic executes on the
`ResticRunner` actor and reports progress back by hopping to the main actor.
The few places Foundation forces the issue — `Process`, its exit handler and
file handles — use small lock-guarded `@unchecked Sendable` wrappers
(`ProcessBox`, `ExitWaiter` and `FileHandleBox` in `ResticRunner`,
`DiffCollector` in `ResticService`).

### Notes on restic's JSON

Its stream is a union keyed only by `message_type`, and the same key is reused
across commands with different payloads:

- `status` from `backup` carries `files_done`; from `restore`, `files_restored`.
- `summary` is emitted by `backup`, `restore` **and** `check`, with disjoint fields.
- errors are nested under `error.message` for `backup`/`restore`, but flat under
  `message` for `check`.
- `short_id` is deprecated upstream, so it is derived from `id` when absent.

`Tests/SwiftResticTests/ResticMessageTests.swift` pins all of this against output
captured verbatim from restic 0.19.1.

Exit codes are mapped rather than treated as pass/fail: **3** means "finished,
but some data could not be read" and is recorded as a warning, not a failed
backup; 10 is a missing repository, 11 a lock, 12 a wrong password.

## Tests

```sh
./build.sh test
```

Three layers:

- **Decoding** — restic's JSON pinned against output captured verbatim from
  restic 0.19.1, plus scheduling, retention and repository-string logic.
- **`ResticService` against real restic** — a throwaway local repository is
  created, backed up, listed, browsed, restored (file, subtree and whole
  snapshot), diffed, pruned and checked; wrong passwords, missing repositories
  and cancellation are asserted on their real exit codes. Skipped when restic is
  not installed.
- **`AppModel`** — the glue: the scheduler starting a due plan unprompted, the
  run history, retention after a backup, hooks firing around a real backup and a
  real check, and that a failed run is recorded rather than dropped. Secrets are injected
  (`SecretStore.inMemory`) so tests never touch the login Keychain.

Plus the pure layers that are easy to get quietly wrong: notification payloads
per provider, dashboard series reduction, console argument tokenising, and that
configuration written by an older build still decodes.

### Looking at the app

Debug builds can photograph themselves, which is how the screens here were
checked:

```sh
open --env SWIFTRESTIC_CONFIG_DIR=/tmp/demo \
  --env SWIFTRESTIC_CAPTURE=/tmp/overview.png \
  --env SWIFTRESTIC_CAPTURE_PANE=overview \
  SwiftRestic.app
```

`SWIFTRESTIC_CONFIG_DIR` points the app at a throwaway configuration instead of
your real one. `SWIFTRESTIC_CAPTURE` writes a PNG of the front window and quits;
`SWIFTRESTIC_CAPTURE_PANE` picks which screen (`overview`, `plan`, `repository`,
`activity`, `find`, `console`). The capture uses `cacheDisplay` from inside the
process, so unlike `screencapture` it needs no Screen Recording permission. All
of it is `#if DEBUG`. Launching through `open` matters: a plain child-process
launch is never activated, and SwiftUI then defers creating the main window
until activation, long after the capture:

Three more environment variables shape a capture run: `SWIFTRESTIC_APPEARANCE`
(`light`/`dark`) pins the appearance instead of following the system,
`SWIFTRESTIC_CAPTURE_SHEET=diff` opens the compare sheet on the repository pane,
and `SWIFTRESTIC_REPO_PASSWORD` hands repositories a password directly (only
honoured together with `SWIFTRESTIC_CONFIG_DIR`), so capture runs never touch
the login Keychain. Capture runs also do not arm the scheduler, so a due plan
cannot fire mid-capture. This all needs a logged-in GUI session on the Mac —
not a headless SSH box.

## Security and privacy

- **The app is deliberately not sandboxed.** restic has to read arbitrary user
  paths and reach the network, and a sandboxed parent confines its children. Arq
  is non-sandboxed for the same reason.
- Repository passwords and backend secrets live in the login Keychain. Only the
  repository UUID is written to `config.json`
  (`~/Library/Application Support/com.newlix.SwiftRestic/`).
- `config.json` is rewritten whole on every edit, so the two previous
  generations are kept next to it (`config.json.1`, `config.json.2`) — a bad
  write or an edit gone wrong is never more than two saves deep.
- Snapshots and repository stats are refreshed with a five-minute ceiling, and
  all repositories refresh concurrently: one unreachable remote cannot stall
  every other repository's upkeep, nor the scheduler arming at launch.
- The password is passed to the child process through `RESTIC_PASSWORD`, so it is
  visible to another process running as the same user via `ps -E`. Acceptable on
  a single-user Mac; a password-command or file-descriptor handoff would close it.
- Grant **Full Disk Access** in System Settings › Privacy & Security. Without it
  macOS silently withholds `~/Documents`, `~/Desktop` and similar folders, and
  restic records them as unreadable rather than failing loudly.
- Keychain calls are made off the main actor. They block, and macOS can put an
  authorisation dialog in front of them; on the main actor that would freeze the
  UI *and* stop the scheduler until the dialog is answered.
- Hook output is treated as potentially sensitive: kept to a first line, stored
  apart from restic's warnings, and never sent to an external channel.

## Locking

restic's locks shape most of the scheduling. `backup` takes a shared lock;
`forget`, `prune` and `check` take exclusive ones. So:

- A repository with a backup or maintenance job in flight counts as **busy**, and
  a plan targeting it is **held back rather than skipped** — it is still overdue
  on the next tick, so nothing is silently lost.
- `prune` is ordered ahead of `check` when both fall due, and a launch reads the
  repositories before arming the scheduler, so the app does not race itself.
- If retention still loses a lock race, the snapshot already exists: the run is
  recorded as *completed with errors* with the reason, never as a failure.

## Hooks

Hooks run through `/bin/sh -c` with the app's own — unsandboxed — privileges, a
configurable timeout, and no terminal. They are told about the run through
environment variables rather than a template language:

```sh
# after success
curl -fsS -X POST "$WEBHOOK" \
  -d "plan=$SWIFTRESTIC_PLAN_NAME&snapshot=$SWIFTRESTIC_SNAPSHOT_ID&added=$SWIFTRESTIC_DATA_ADDED"
```

`SWIFTRESTIC_SNAPSHOT_ID` and `SWIFTRESTIC_ERROR` are *absent* rather than empty
when they do not apply, so `[ -n "$SWIFTRESTIC_ERROR" ]` works. A failing hook
marks the run as *completed with errors* but never turns a written snapshot into
a failed run. Only a before hook can be set to cancel the run.

Repositories have hooks of their own, in the repository editor, around `check`
and `prune`: *before*, *after success*, *after failure* and *after every*.
They get the same variables — the plan ones are present but empty, since
there is no plan — never the snapshot one, plus
`SWIFTRESTIC_TASK` (`check` or `prune`). A check that finds errors counts as a
failure for hook purposes — that is the outcome a repository hook exists to
report — and a before hook set to cancel still stamps the schedule, so a hook
that always refuses does not turn into a retry every minute.

**A hook's output stays on this Mac.** It is an arbitrary script and can print
anything — a verbose `curl` echoes its own `Authorization` header — so only the
first line of a failing hook's output is kept, it is stored separately from
restic's own warnings, and it is never included in what goes out to a webhook or
chat channel.

`forget` has no hooks of its own: it runs inside the backup that triggered it,
so the plan's after-backup hooks cover it.

## Alerts

Webhook (generic JSON), Slack, Discord and Healthchecks.io. Healthchecks is the
one worth setting up: it is a dead-man's switch, so it catches the failure mode
none of the others can — a Mac that never wakes up and therefore never reports
anything. SwiftRestic pings `…/start` before a backup, the bare URL on success and
`…/fail` on failure — and also on a run you cancelled, because from a monitor's
point of view that is still a backup that did not happen. Chat channels stay
quiet about cancellations, since whoever cancelled already knows. Quitting the
app waits for an in-flight start ping rather than dropping it. A notification
that cannot be delivered is shown to you but never written into the run history.

## Behaviour worth knowing

- **A new plan backs up almost immediately.** A plan on an interval, daily or
  weekly schedule that has never run counts as due, so creating one starts a backup
  within a minute. Pick "Manually" if that is not what you want.
- **A repository with no saved password is skipped, not retried.** Maintenance
  is not scheduled for it and no failure is recorded — the repository screen says
  it is waiting for a password instead.
- **A development build asks for Keychain access on every rebuild.** The app is
  ad-hoc signed, so its signature changes each time it is built and macOS treats
  it as a new application. Choose *Always Allow*, or expect the prompt again after
  the next build. A Developer ID signature makes this go away.
- **A newly added repository is not checked immediately.** Maintenance counts
  from when the repository was added, so adding one does not kick off a long
  prune straight away.
- **`prune` has no JSON output** in restic 0.19.1, so its plain-text report is
  captured verbatim onto the run record rather than parsed.
- **rclone repositories need the `rclone` binary** (`brew install rclone`) and a
  remote already configured with `rclone config`; SwiftRestic checks for it when
  you test the connection rather than letting the failure surface from inside
  restic.

## Known limits

- Scheduled runs need the app to be running. There is no LaunchAgent or daemon,
  so backups do not fire when SwiftRestic is quit. Turn on *Start at login* in
  Settings. Closing the window never quits the app — that is what keeps it
  resident, not the menu bar item — but keep the item on: it is the only way
  back into the UI. The
  toggle refuses to register while the app is running out of a build folder — a
  login item registered from DerivedData points at a bundle the next compile
  replaces, and that stale entry outlives the build. Move the app to
  `/Applications` first. On an ad-hoc-signed build macOS may still ask for
  approval in System Settings; the toggle catches up when you come back to the
  app.
- SFTP repositories do not inherit `SSH_AUTH_SOCK` from a GUI launch, so a
  passphrase-protected key cannot be unlocked. Use a passphrase-less key or an
  `~/.ssh/config` entry with an explicit `IdentityFile`.
- No cron expressions: the schedule covers manual, every N hours, daily and
  weekly. No rclone-style remote *management* either — configure remotes with
  rclone itself.
- restic is not downloaded or updated by the app. That is Homebrew's job;
  fetching executables from a GUI is a signing and quarantine mess.
- The build is ad-hoc signed with the hardened runtime off. Distribution would
  need a Developer ID, hardened runtime and notarization — and note that
  re-signing changes which Keychain items the app can read.
- *Compare* keeps the first 20,000 changed paths and says so when it stopped;
  the totals in the tiles come from restic's own statistics line and are always
  complete. Metadata-only changes (permissions, owner, timestamps) are hidden
  unless *Include metadata changes* is on, matching `restic diff --metadata`.
  Comparing snapshots of different folders or hosts is allowed but mostly shows
  everything as added and removed; the sheet says so when you pick one.
- *Find files* with **Latest snapshot only** means the newest snapshot in the
  repository, not the newest per plan. If two Macs write to one repository the
  latest snapshot may belong to the other one — search all snapshots there.
- The UI is English only. Two strings (the find-pattern placeholder and the
  /bin/sh note that mentions `SWIFTRESTIC_*`) are `Text(verbatim:)` because
  SwiftUI parses literal titles as Markdown and ate the `*` in the glob
  example; those would need rewording if the app were ever localized.
