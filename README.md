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
master, so strokes stay crisp at 16pt. The two-plate stack in the middle is the
same construction at every size — the same numbers the menu bar's icon draws —
so the Dock icon and the tray read as one mark. The 16 and 32 pixel renditions
still deliberately draw a coarser glyph: a heavier stroke, wider arrow angles,
and no shadow, since at that size the large rendition's thin stroke falls below
a pixel and smudges. The variant is chosen by pixel count, so 16pt@2x and 32pt@1x render
identically.

Re-run the generator after editing `Tools/GenerateAppIcon.swift`; the PNGs are
checked in so a normal build does not need it.

## What it does

- **Repositories in the sidebar** — each repository is a row with its backup
  plans always in view beneath it, and each plan folds open to the backups it
  made there; a repository with no plan yet shows *New Backup Plan…* where
  its plans would be. Backups no plan of the repository made — from another
  Mac or the restic console, a deleted plan, or a plan that now backs up to
  another repository — sit under *Other backups*, grouped by the plan that
  made them (its `swiftrestic-plan-` tag says which, so a deleted plan's
  history stays one group); backups no plan made stay grouped by the folders
  and Mac they came from (restic's own `host,paths` grouping). Each group's
  caption says which kind it is — *not set up here*, *now backs up to
  “Offsite”*, *outside SwiftRestic* — and names the Mac its newest backup
  came from when that isn't this one. A plan's row caption gives its last
  backup (*“Last backup 1 hour ago”*); the plan's page, the tray and
  Settings say when it runs next. A
  repository wears a warning while one of its plans is not protected — its
  backups cannot be read, a plan has no backup, or a plan's last backup
  failed; the warning's tooltip names the plan.
- **A plan-UUID group is a page** — a group's row selects like a plan's
  (the chevron ahead of it folds), and the page says what the history is:
  a plan not set up in SwiftRestic — deleted here, or still running on
  another Mac — or a plan that now backs up elsewhere, with *Open the
  “Music” Plan* to go to it. The page's Backups card brackets the history
  (newest, oldest), names the Macs it was made from and lists each folder
  set it spans, carries the exclude patterns and user tags, and shows the
  plan tag itself — selectable, the one honest identifier. *Restore
  Files…* opens the group's newest backup and *Browse Folders…* walks its
  folders through every backup, from the page and the group's context
  menu; an untagged lineage's menu carries *Restore Files…* alone.
- **Adopting** — a group no plan anywhere carries the ID of can be adopted
  back into one: *Adopt as a Backup Plan…*, from the page's explanation
  card, the group's context menu, and an *Other backups* card on the
  repository's page that lists each adoptable group while there is one,
  opens the plan editor with the
  group's own name and, from the newest backup this Mac made — or the
  newest of all, when another Mac made them all — its folders, exclude
  patterns and user tags, with the repository locked to the one the
  backups live in, the schedule set to Daily only when every prefilled
  folder exists here, and retention off. Adopting writes one plan whose ID is the group's UUID and
  nothing else: no snapshot is retagged, nothing is written to the
  repository, and the records move under the new plan by themselves. A
  group with a backup from another Mac, or one less than 48 hours old, is
  asked once more before adopting; deleting a plan says its snapshots stay
  under Other backups and can be adopted back. Moving a plan to another
  repository in the editor says what stays behind — the backups are never
  thinned, and retention runs against the plan's current repository only.
- **A repository's page is its overview** — a *Protection* line (“2 of 2
  plans protected · Last backup 1 hour ago”; with no plans yet, the count
  of backups from no plan here), which carries the hold's own words while
  backups are held app-wide and a *Resume* button while the hold is your
  own *Pause Backups*; an *Other backups* card listing each adoptable
  group while there is one; the week's problems against it; then where it
  is, how big it is, and its maintenance. *New Backup Plan…* is in the
  page's toolbar, and the Protection card carries it as a button while
  the repository has no plan. The *Snapshots* row splits the backups no
  plan of the repository made (“11 · 6 from no plan here”, or “all” when
  none of them is a plan's). A repository whose
  first listing finds no plans and adoptable history opens its *Other
  backups* shelf so the groups are in view; no modal, no wizard.
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
- **Pause** — *Pause Backups* in the menu bar holds every scheduled backup,
  check and prune for an hour, until tomorrow or until resumed; *Pause and Stop
  Running Backups* also stops backups in flight, which start over when the
  pause ends — restic cannot resume a backup. A plan's own *Pause Schedule*
  takes the same lengths. With *Pause scheduled backups on battery power* on,
  the menu bar, the repository pages and Settings say that backups wait for power
  instead of announcing runs that will not start.
- **Browsing and restore** — every *Browse*, *Restore Files…* and *Show in
  Restore* opens the one browser, at that backup in the sidebar: a
  backup's folders as a tree, with a Change column and search, and three ways
  to restore — drag an item to Finder, select one and choose *Restore…*, or
  *Restore Entire Backup…*, which recreates its folders under their full
  original paths inside the folder you choose. Per-node restores land in the
  chosen folder with no absolute path rebuilt above them. ⌘- or ⇧-click
  selects several items, and *Restore…* (or Return) restores them together:
  one `restic restore` per folder they come from rather than one per item —
  each restic run reloads the repository's index — with an item inside a
  selected folder left to the folder (the sheet says so), and two items of
  the same name allowed back to their original locations but never into one
  folder. → and ← open and close every selected folder. *Restore…* and
  *Restore Entire Backup…* ask where — the Desktop, another folder, or an
  item's original location — and whether files already there are kept (the
  default: restic's `--overwrite never`, which still replaces a file standing
  where the backup has a folder of that name, and gives folders that already
  exist the backed-up permissions and dates) or replaced (`--overwrite
  always`, which compares contents rather than trusting size and date),
  confirming first when something is actually there to replace. restic before
  0.17 has no `--overwrite`; with such a restic, keeping restores a folder or a
  whole backup only where nothing is there yet, and refuses otherwise. The
  file list's Change column compares each backup with the previous one of the
  same folders from the same Mac — not merely the row below it, which for a
  plan whose folders changed is a backup of other folders; the pane's header
  names the open backup and says what its Change column is compared with, or
  that it is the first of its folders. On a plan's page, *Browse
  Folders…* walks one folder through every snapshot that contains it. The file
  list answers Finder's outline keys: → opens a folder, ← closes it or steps to
  the folder that holds the selection. Its search covers the open backup and
  says how many matches only other backups hold; *Search All Backups…* carries
  the search on in Find Files.
- **Find files across snapshots** — search every snapshot for a name or glob when
  you do not know which backup still has the file, then restore the match. It
  opens on the repository you are looking at — a selected plan's, backup
  record's or group's; the first repository when the selection names none
  (Activity, the console, nothing) — unless the Restore pane's *Search All
  Backups…* handed a search over, which names its own repository. The
  toolbar's magnifier, or ⇧⌘F.
- **Compare snapshots** — *Compare with Previous…* on a backup run in Activity
  runs `restic diff` against the previous snapshot of the same folders from the
  same Mac (any earlier one can be chosen) and lists what was added, removed or
  modified, filterable by kind and path, with restic's byte totals, under a
  header that names the repository the diff ran against. Answers
  "what did last night's backup actually pick up?" without restoring anything.
- **Start at login** — the scheduler only runs while the app runs, so SwiftRestic
  can register itself as a login item and sit in the menu bar.
- **Maintenance** — scheduled `check` and `prune` per repository, on a day
  interval, plus manual runs, stale lock removal and repository stats, and a
  plan's retention applied on demand (*Plan › Apply Retention Now…* previews
  with `restic forget --dry-run --no-lock`, then asks).
- **Hooks** — shell commands before a backup and after success, warnings or
  failure, and per repository before and after a check or prune. Context arrives
  as `SWIFTRESTIC_*` environment variables; a before hook can be set to call the
  run off.
- **Alerts** — webhooks, Slack, Discord and Healthchecks.io, per run outcome.
- **restic console** — run any restic command against a repository and read its
  own output, for the things the UI does not cover (*Repository › restic
  Console…*).
- **Activity** — every run recorded with its outcome, its repository, duration,
  bytes added, the files restic could not read, and a plain-text log of what
  restic printed (Show Log…, Copy Details); the drawer below a selected run
  opens its plan or its repository, and restores record which backup, which
  item and where it went. Run names carry their repository on every surface
  that names a run — the log sheet's header, notifications and failure
  alerts, the menu bar and Settings.
- **Menus** — the *Plan* and *Repository* menus act on what the sidebar has
  selected: a plan, a repository, or the repository a selected plan, backup
  record or Other-backups group belongs to. Items with nothing to act on are
  greyed out. ⌘B backs up the selected plan, ⌘. stops it, ⇧⌘B backs up every
  plan, ⇧⌘F finds files and ⌘R refreshes every repository's snapshots;
  *Pause Backups* is there as well as in
  the menu bar. While a sheet is up, a command that opens a sheet or the
  console, or acts on the selected plan or repository, beeps and does nothing;
  *Back Up All Plans Now*, *Pause Backups*, *Resume Backups*, *Pause and Stop
  Running Backups* and *Refresh All Snapshots* still act, since no sheet holds a
  draft of what they change.

## Architecture

```
Core/       ResticBinary   locate the executable (GUI apps get a bare PATH)
            ResticRunner   actor: spawn, stream NDJSON, cancel, time out,
                            stall-cap (idle watchdog), map exit codes
            ResticMessage  decode restic's --json union; malformed known
                            messages are counted, never silently dropped
Models/     Repository, MaintenancePolicy, BackupPlan, Schedule, RetentionPolicy,
            BackupHook, NotificationChannel, Snapshot, RunRecord
Services/   ResticService     typed restic commands (idle caps on the streaming ones)
            HookRunner        shell hooks, on the same process machinery
            NotificationPoster + payload builders per provider
            OverviewMetrics   protection rows and recent problems, kept pure
            SecretStore       Keychain, injectable so tests never touch yours
            ConfigStore, Scheduler, KeychainStore
  Index/    SnapshotIndex     per repository, one SQLite file: which snapshots
                              hold a path and where its content changed,
                              basename search, browse caches
            IndexCoordinator  actor: reconcile each listing, backfill by
                              restic diff or ls, housekeeping, orphan sweep
            FileTree          the restore browser's lazily loaded tree
App/        AppModel       @MainActor @Observable — configuration, run state,
                            banners; the facade the views and scheduler call
            AppRouter      view state and window intents (selection, sheets
                            asked for by menus/tray, the Activity focus flags)
            RunEngines     BackupRunEngine + MaintenanceRunEngine: the run
                            lifecycles over sink protocols, unit-testable
            TaskRegistry   the in-flight task census shutdown drains
            ConsoleModel   the console pane's state (dependencies injected)
Views/      NavigationSplitView UI, the sidebar and the repository page's
            cards, restic console;
            the root composes SidebarView + RootDetailView child views
```

Everything runs under Swift 6 strict concurrency. restic executes on the
`ResticRunner` actor and reports progress back by hopping to the main actor.
The few places Foundation forces the issue — `Process`, its exit handler and
file handles — use small lock-guarded `@unchecked Sendable` wrappers
(`ProcessBox`, `ExitWaiter` and `FileHandleBox` in `ResticRunner`,
`DiffCollector` in `ResticService`).

A few seams worth knowing by name:

- **`ResticClient`** is the engine boundary; `AppModel.service()` is the one
  place the concrete binary-backed implementation is chosen. Tests substitute
  it two ways: a scriptable mock (`MockResticClient`, for the run engines)
  and a fake shell-script restic (fault paths: hangs, torn writes, exit codes).
- **Resolved contexts are cached** per repository (`AppModel.resolvedContexts`)
  so a restic call does not re-read the Keychain; the key covers the
  repository value and rate limits, secret edits invalidate in `upsert`, and
  exit 12 — or exit 1, which is how a rejected provider secret surfaces —
  drops the entry so a fixed password takes effect without a restart.
- **Streaming commands wear an idle stall cap** (15 min with no output at all
  ends the run as hung) — measured on `systemUptime`, so a closed lid is not
  "silence". Legitimately quiet commands (`prune`, `forget`, `dump`, the
  console) wear none. When a child dies, its pipes are abandoned two seconds
  later whatever still holds them: a hook that backgrounds a long-lived
  command cannot hang the run, its timeout, or the quit that drains it.
- **Menu commands and the tray ask the router** (`router.request(...)`) for
  typed intents; the root view consumes them on appear-or-change, and every
  window-targeting command also opens the window so no ask is parked unheard.
- **The snapshot index is a cache of what restic cannot answer quickly**: which
  snapshots hold a path, and a name search across all of them — for Browse
  Folders' version list, Find Files and the Restore pane's search — plus cached
  folder listings and diffs. One SQLite file per repository,
  `index/<repository UUID>.sqlite` in the configuration folder, stores every
  path once as a tree of names and, per plan (or per restic `host,paths` group
  for backups no plan made), the ranges of snapshots each path exists in, so a
  backup writes only what changed. It reads a group's newest snapshot with
  `restic ls` and, as a rule, each other one with a `restic diff` against a
  neighbour already read, keeping the files that diff says changed (`M`) — so
  a file's versions are the backups where its content changed, not every
  backup that holds it; a neighbour read in full instead is marked as a step
  that may have changed anything. Its failure never fails a refresh or a backup: a file
  it cannot use is deleted and read again, *Rebuild Search Index…* does the same
  on request, and until it has read every snapshot Find Files searches through
  restic instead. Only the `SnapshotIndex*.swift` files touch GRDB. At launch,
  after a clean configuration load, index files of repositories no longer
  configured are deleted — only inside `index/`; the `<uuid>.sqlite` files
  earlier builds left directly in the configuration folder are never opened,
  swept or deleted.

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
backup; 10 is a missing repository, 11 a lock, 12 a wrong password. `check`
gets its own reading of 1 — that is restic's verdict that the repository is
damaged, and the summary's error count arrives with it, so the record says
what was found rather than that the command failed.

## Tests

```sh
./build.sh test
```

Five layers:

- **Decoding** — restic's JSON pinned against output captured verbatim from
  restic 0.19.1, plus scheduling, retention and repository-string logic.
- **`ResticService` against real restic** — a throwaway local repository is
  created, backed up, listed, browsed, restored (file, subtree and whole
  snapshot), diffed, pruned and checked; wrong passwords, missing repositories
  and cancellation are asserted on their real exit codes. Skipped when restic is
  not installed.
- **The run engines** — `BackupRunEngine`/`MaintenanceRunEngine` sequencing and
  outcome mapping against a scriptable `MockResticClient` (no process per
  case), plus the stub-binary fault paths: hangs, torn writes, mid-run deaths.
- **`AppModel`** — the glue: the scheduler starting a due plan unprompted, the
  run history, retention after a backup, hooks firing around a real backup and a
  real check, and that a failed run is recorded rather than dropped. Secrets are injected
  (`SecretStore.inMemory`) so tests never touch the login Keychain.
- **The snapshot index** — file-backed, in temporary folders: scripted
  scenarios, a seeded differential test against a model of the listings, the
  query plan of every statement, and scale gates that bound rows changed and WAL
  bytes written per backup at a thousand snapshots. Two environment variables
  scale them up — `SWIFTRESTIC_INDEX_PROPERTY=40,30` (seeds, rounds) and
  `SWIFTRESTIC_INDEX_BENCH=1` (2M paths and 10k snapshots, with timings) — and
  reach the tests through xcodebuild with a `TEST_RUNNER_` prefix.
  `Tools/sqlite-floor.sh` runs the plan and differential tests on SQLite 3.43.2,
  what macOS 15 ships, built from the official amalgamation.

Plus the pure layers that are easy to get quietly wrong: notification payloads
per provider, the protection rows and the Protection line, console argument
tokenising, and
that configuration written by an older build still decodes.

### Looking at the app

Debug builds can photograph themselves, which is how the screens here were
checked:

```sh
open --env SWIFTRESTIC_CONFIG_DIR=/tmp/demo \
  --env SWIFTRESTIC_CAPTURE=/tmp/repository.png \
  --env SWIFTRESTIC_CAPTURE_PANE=repository \
  SwiftRestic.app
```

`SWIFTRESTIC_CONFIG_DIR` points the app at a throwaway configuration instead of
your real one. `SWIFTRESTIC_CAPTURE` writes a PNG of the front window and quits;
`SWIFTRESTIC_CAPTURE_PANE` picks which screen (`plan`, `repository`, `restore`,
`activity`, `find`, `console`), plus `orphanGroup` and `movedGroup` — the page
of the first adoptable group under Other backups, or of the first moved plan's
group, with its sidebar fold open. Both wait for the snapshot listing that
builds group rows, like `restore` does. `findMoved` opens Find Files on the
first plan whose repository is not the first, so a shot shows the picker
starting on the selection's repository rather than the landing pane's (a
configuration without such a plan stops the run). `all` instead photographs
every pane in one run — `SWIFTRESTIC_CAPTURE` names a directory, each pane
lands as `pane-<name>.png`, and `SWIFTRESTIC_CAPTURE_DELAY` becomes the settle
time per pane. The sweep is the whole-window regression check: a defect like macOS 26's
floating title-bar material shows up on every pane, including the ones nobody
was just then looking at. Captures prefer ScreenCaptureKit, which renders
Tahoe's glass materials correctly but needs a one-time grant (System Settings
→ Privacy & Security → Screen Recording → SwiftRestic); without it the shots
fall back to `cacheDisplay`, which draws those materials black on macOS 26,
and each capture logs which backend produced it. Either way the session must
be unlocked — a locked screen hides the window from capture entirely. All
of it is `#if DEBUG`. SwiftUI defers creating the main window until the app is
activated; the capture path activates the app on purpose at launch for exactly
that reason, so launching through `open` (as above) and launching the binary
directly both work:

Three more environment variables shape a capture run: `SWIFTRESTIC_APPEARANCE`
(`light`/`dark`) pins the appearance instead of following the system,
`SWIFTRESTIC_CAPTURE_SHEET` opens a sheet — `diff` on Activity's compare sheet
(with `SWIFTRESTIC_CAPTURE_PANE=activity`), `retention` lands the plan editor
on its Retention tab, and `adopt`/`adoptRetention` open the adopt sheet of the
first adoptable group (with `SWIFTRESTIC_CAPTURE_PANE=orphanGroup`, the latter
on its Retention tab),
and `SWIFTRESTIC_REPO_PASSWORD` hands repositories a password directly (only
honoured together with `SWIFTRESTIC_CONFIG_DIR`), so capture runs never touch
the login Keychain. Capture runs also do not arm the scheduler, so a due plan
cannot fire mid-capture. `SWIFTRESTIC_POWER_SOURCE` (`battery`/`ac`, debug
builds only, honoured only with `SWIFTRESTIC_CONFIG_DIR`) stands in for the
power adapter at each scheduler tick, so the battery hold can be looked at on
a Mac that stays plugged in — in a normal launch, since a capture run never
arms the scheduler and so never reads it. `SWIFTRESTIC_LOGIN_ITEM_INSTALLABLE=1`
(debug builds only, honoured only with `SWIFTRESTIC_CONFIG_DIR`) makes the
start-at-login offers treat a build-folder copy as installed, so their *Start
at Login* button can be looked at; it changes only what they offer —
registering still refuses from a build folder, so a click shows that refusal
and registers nothing. This all needs a logged-in GUI session on the Mac — not
a headless SSH box.

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
  restic records them as unreadable rather than failing loudly — the run still
  writes a snapshot, but an *incomplete* one (restic's exit code 3), which
  SwiftRestic marks with a warning triangle in the sidebar and in Activity's run
  drawer; the Restore pane lists what could not be read. SwiftRestic detects
  the grant — at launch, whenever it becomes active, and after every backup —
  and shows it first in Settings › General; the build is ad-hoc signed, so a
  rebuilt or updated copy may need it granted again. A run's unreadable items
  say which cause is which: "operation not permitted" is macOS withholding the
  item, which the grant fixes, while "permission denied" is the file's own
  permissions, which it does not.
- Keychain calls are made off the main actor. They block, and macOS can put an
  authorisation dialog in front of them; on the main actor that would freeze the
  UI *and* stop the scheduler until the dialog is answered.
- Hook output is treated as potentially sensitive: kept to a first line, stored
  apart from restic's warnings, and never sent to an external channel.
- The snapshot index, `index/<repository UUID>.sqlite` beside `config.json`,
  holds the path of every file in every backup it has read, unencrypted — names
  restic itself keeps encrypted in the repository. It is deleted with its
  repository, and *Rebuild Search Index…* deletes and re-reads it; the
  repository never depends on it.
- Each run's log is kept beside `config.json` in `Logs/<run-id>.log` and deleted
  with its run record. It holds the restic command lines (which name your source
  folders) and restic's own messages (which can name the repository's location,
  with any password in it masked) — never the password or repository
  credentials, which travel in the environment, and never a hook's command or
  output.

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
report — and a failing hook turns the run record itself amber, the same way a
backup's does. A before hook set to cancel still stamps the schedule, so a hook
that always refuses does not turn into a retry every minute.

**A hook's output stays on this Mac.** It is an arbitrary script and can print
anything — a verbose `curl` echoes its own `Authorization` header — so only the
first line of a failing hook's output is kept, it is stored separately from
restic's own warnings, and it is never included in what goes out to a webhook or
chat channel.

`forget` has no hooks of its own: it runs inside the backup that triggered it,
so the plan's after-backup hooks cover it — nor does *Apply Retention Now…*,
which runs no hooks and sends no alerts: the banner and Activity announce it,
and a Healthchecks ping would reset the dead-man's switch for a run that backed
nothing up.

## Alerts

Webhook (generic JSON), Slack, Discord and Healthchecks.io. Healthchecks is the
one worth setting up: it is a dead-man's switch, so it catches the failure mode
none of the others can — a Mac that never wakes up and therefore never reports
anything. SwiftRestic pings `…/start` before a backup, the bare URL on success and
`…/fail` on failure — and also on a run you cancelled, because from a monitor's
point of view that is still a backup that did not happen. Chat channels stay
quiet about cancellations, since whoever cancelled already knows. Quitting the
app waits for an in-flight start ping rather than dropping it. A notification
that cannot be delivered is shown to you but never written into the run
history, and that holds for the local system notification too: denied
permission or a failed delivery names itself in a banner, once per failing
stretch.

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
  app. The plan editor offers *Start at Login* when a save turns a schedule on.
  Quitting from SwiftRestic's own Quit — the app
  menu, ⌘Q or the menu bar item — while a plan is scheduled and start at login
  is off names the run that will be missed; a quit asked for by the Dock,
  AppleScript, a logout, restart or shutdown never waits on that question.
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
