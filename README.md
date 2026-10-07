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
- **Overview | Files** — a plan's page has both, in the window toolbar.
  Overview is its cards; Files lists its folders and files across every
  backup it made, items its newest backup no longer holds included, dimmed
  and wearing the day they were last backed up (*until Oct 2*) where the
  whole name fits beside it — the name never shortens for the day, which
  the row's tooltip and the pane's header say in full: the tree on the left, starting at the page's edge (drag that edge
  to widen it), the folder or file picked in it on the right. A first visit
  opens at the plan's first folder. The tree comes from the snapshot index;
  while the index is still reading a repository it fills in as it goes, and
  a plan the index holds nothing of yet lists its newest backup. A folder
  lists at most 200 items in the tree, then one row that opens the folder in
  the pane. Picking a folder lists it as a backup held it, each file with its
  size — *As backed up* picks which of the backups holding it, by its
  moment, newest first, grouped by month once they span more than one, as
  the Compare sheet's picker is and a plan's backups in the sidebar are
  (an inert month caption above each month's rows) — under one line of what changed in the folder
  itself since the backup before that holds it (*Since Oct 1, 2026 at 9:15
  AM, in this folder: 2 modified*), with what is gone named and each item
  marked *Added*, *Modified* or *May have changed*: from the index's record
  of the backups' diffs, no restic, and nothing said of what changed inside
  its subfolders, nor of a change of metadata alone. Its items select
  several at a time and restore together, drag to Finder, or open in the
  tree with a double-click, keeping the chosen time when they existed then;
  with nothing selected, *Restore Folder…* restores the whole folder.
  Picking a file lists its versions — each content it had, from the index: a
  version starts where restic's diff said the file changed, or where no diff
  compared two backups or the file was absent in between. A row says when
  the file was modified and how big it was, how that size moved from the
  version below (*+17 bytes*, *Same size*) — or *May be identical* where no
  diff split the two and their sizes do not tell them apart — and, for a
  content several backups held, which (*In 4 backups · Oct 2 – Oct 4,
  2026*). Above them, for a file this Mac backed up by its own path, one
  line says what the copy here is: *the same as the newest version*, the
  same as an older one, none of them (with its own date and size), or *Not
  on this Mac* — one `lstat`, compared by size and modification time to
  restic's millisecond, read again when a restore ends. Each row's modification time and size come from one `restic
  find` of the file's exact path, its glob characters escaped, asked once
  per backup: the index keeps each answer, so going back to a file — after
  a relaunch too — runs no restic — and an opened folder's files are read
  ahead in one `find` (once the index has read every backup), so a first
  click on one is answered too. A search field heads the tree: typing lists,
  in the tree's place, the items of this plan's backups (or this group's)
  whose names have words starting like the query — from the index, instant,
  items the newest backup dropped included, dimmed with the day they were
  last backed up (*until Oct 2*) — each under the folder that holds it. A
  hit selects as a tree row does, so its versions open beside it; Return or
  Esc ends the search on the tree, the hit's folders opened and its row in
  view. While the index is still reading the repository the search says
  older backups may be missing, and one with no match offers *Search All
  Backups…*, Find Files over the whole repository. Return or
  *Restore…* restores the chosen version, and a row drags to Finder.
  *Preview* shows a file's chosen version in Quick Look before you restore
  it: `restic dump` copies it, read-only, into a temporary folder of its own,
  deleted when the preview closes, another version is chosen or the pane
  goes (a quit leaves it to the next launch's sweep). It waits for the
  version's size and stops at 1 GB — past that, restore it. *Show
  in Backups* opens the chosen backup at that place, under its plan in the
  sidebar. Each page keeps its tab, open folders and selection while the app
  runs — going to a backup and back finds the Files tab as it was left — and
  every page opens on Overview after a launch.
- **A group under Other backups is a page** — a group's row selects like a
  plan's (the chevron ahead of it folds), and the page has the same
  Overview | Files. Overview says what the history is: a plan not set up in
  SwiftRestic — deleted here, or still running on another Mac — or a plan
  that now backs up elsewhere, with *Open the “Music” Plan* to go to it, or
  backups no plan made, which can't be adopted. Its Backups card brackets
  the history (newest, oldest), names the Macs it was made from and lists
  each folder set it spans, carries the exclude patterns and user tags, and
  shows the plan tag itself when there is one — selectable, the one honest
  identifier. *Restore Files…* opens the group's newest backup; the group's
  context menu has it and *Show Files*, which opens the page on Files. An
  untagged lineage's files come from the index's chain of its host and
  folders. A folder backed up by a relative path — `restic backup Documents`
  from the console, inside the home folder — shows where restic put it in
  the backup, `/Documents`, though the backup names `/Users/…/Documents`.
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
  own *Pause Backups*. Under the count, each plan that is not protected is
  named with its warning, and each protected plan that will not run by
  itself — paused, or "Not scheduled" because its setup is incomplete —
  with a pause glyph in the sidebar's words ("Photos: Paused — Sunday at
  03:00"), so "2 of 2 plans protected" cannot hide a plan that has stopped;
  a manual plan never runs by itself and gets no line. Then an *Other
  backups* card listing each adoptable
  group while there is one; the week's problems against it; then where it
  is, how big it is, and its maintenance. The Protection card carries
  *New Backup Plan…* as a button while the repository has no plan; after
  that a plan starts from the sidebar's + or ⌘N, into the repository on
  screen, or from the repository row's menu. The *Snapshots* row splits the
  backups no plan of the repository made (“11 · 6 from no plan here”, or
  “all” when none of them is a plan's). A repository whose
  first listing finds no plans and adoptable history opens its *Other
  backups* shelf so the groups are in view; no modal, no wizard.
- **Repositories** — local disk, SFTP, S3-compatible, Backblaze B2, Azure Blob
  Storage, Google Cloud Storage, an rclone remote, or a restic REST server.
  Creating one runs `restic init`; the app refuses to save a repository it could
  not reach. *Test Connection* on a path with no repository says what Save
  will do: create one, for a new repository; for an existing one, nothing —
  "backups to it would fail until one is created", so point it at the folder
  that holds the repository. The answer shows above the editor's buttons, on
  either tab, and a new repository's empty location reads as information — an
  expected first step, not the red of a failure. The editor asks *Where is it?* — on this Mac, on another machine,
  in the cloud, through a gateway — and groups the kinds that way whether the
  repository is new or being edited. A REST server's login goes in *User*
  and *Server password* — the password in the Keychain like every backend's
  secret — and reaches restic as `RESTIC_REST_USERNAME`/`RESTIC_REST_PASSWORD`,
  so the URL in the configuration file and on the repository page holds no
  password; a URL pasted with its login sheds it into those fields. One saved
  with the login in it keeps working: restic prefers a URL's own credentials.
  An existing repository's *Change
  Password…* runs `restic key passwd` with the stored password, the new one
  handed over in a file only this user can read, deleted when restic ends;
  only then does the Keychain take the new password. It asks first — the old
  password stops opening the repository everywhere — and waits while a backup
  or maintenance job uses the repository: restic needs it to itself and fails
  at once under another lock (exit 11, restic 0.19.1). A refused change
  (exit 12: the stored password does not open it) stores nothing. restic
  trims spaces from the ends of a password it reads from a file, so a new
  password with them is refused rather than left to disagree with the
  Keychain.
- **Backup plans** — a set of folders, exclude patterns, a schedule and a
  retention policy, pointed at one repository. Each plan stamps its snapshots
  with a private tag so retention can only ever touch its own. A plan's page
  is three cards, each with its verb in its corner: *Backups* (its last
  backup, how many it holds and its retention) with *Back Up Now* — *Stop*
  while it runs — *Schedule* (its schedule and when it runs next) with *Pause
  Schedule*, its arrow offering the lengths, or *Resume Schedule* while
  paused (a manual plan has nothing to pause and shows none), and
  *Configuration* (its folders, exclude patterns and hooks) with *Edit*.
  Every one of them is in the Plan menu and the plan row's menu too. The
  plan editor picks the repository for a new plan only when there is just
  one; it says when one of the plan's folders is not on this Mac; its exclude
  list takes items chosen in a panel or dropped from Finder as their own
  paths, glob characters escaped so each matches itself alone; and its
  Schedule tab shows *Next backup* for the schedule being chosen, the plan
  page's own value for the plan as Save would store it. *Skip online-only
  cloud files (iCloud Drive, OneDrive)* passes restic's
  `--exclude-cloud-files`: on for new plans, off for a plan saved before the
  option (its backups do not change under it), and only with restic 0.19 or
  later, which brought the flag to macOS (restic's changelog) — the editor
  says when this restic is older. What restic does with an online-only file
  without the flag was not tried here: it would mean reading one of a real
  iCloud Drive's files.
- **Skipped backups** — when every folder of a plan is missing, restic writes
  nothing and says so (exit 1, "Fatal: all source directories/files do not
  exist", restic 0.19.1). That run is recorded as *Skipped*, with the reason
  in Activity's Detail column, the drawer and Copy Details — "“Archive SSD” is
  not connected." when the folders live on volumes, else "None of its folders
  are on this Mac." It is no failure: no dot, notification, banner or problem
  row (an alert channel with a start ping hears a fail, as for a cancel), and
  it stamps the slot, so an hourly plan does not retry every minute. When a
  volume mounts, each scheduled plan whose newest backup was skipped and whose
  folders are all back runs at once instead of a whole interval later (a disk
  image attached with `-nobrowse` counted). The quiet-plan alert speaks if the
  drive stays away. A skip that continues the plan's last one — the same
  reason, neither writing a snapshot, the earlier one without a hook's
  complaint — replaces it, its log with it: one record whose Detail reads
  "“Archive SSD” is not connected. Skipped 24 times since …", with a *Since*
  row in the drawer and a "Skipped since:" line in Copy Details. An hourly
  plan whose drive is away for a week is one row, not 168, and "Keep runs"
  stays for real runs. Some but not all folders missing is restic's exit 3 with
  a snapshot of the rest. When every folder restic skipped is on a volume
  that is not mounted, and it could read everything else, that run is
  Skipped too — "“Archive SSD” is not connected; the other folders were
  backed up." — with its snapshot, numbers and *Last backup* kept: it heals
  an older failure, pings a Healthchecks channel alive, and the mount runs
  it again in full. Accepted with it: while the other folders keep backing
  up, the quiet-plan alert does not speak for the away one. A skipped folder
  whose drive is here, or any other unreadable item, keeps the whole run
  *Completed with errors*, every skipped folder among its items. The
  repository's side is the
  same: a backup to a local repository under /Volumes whose volume is not
  mounted (checked after the before-backup hooks, which may mount it) is
  Skipped with "“Travel SSD” is not connected." without asking restic, and
  runs when the volume mounts. restic cannot tell that case from a moved
  folder — both are exit 10, "Fatal: repository does not exist: unable to
  open config file" (restic 0.19.1) — so the app looks at the volume itself:
  a folder under /Volumes counts only while it is the root of a mounted
  volume. With the volume here and the folder gone, the run still fails, and
  its fix is *Edit Repository…*.
- **Scheduling** — hourly / daily / weekly, checked once a minute. A daily plan
  whose window passed while the Mac was asleep runs as soon as it wakes rather
  than skipping the day. While restic cannot be found the scheduler starts
  nothing — no backup, check or prune, so no Failed record, banner or
  notification per slot for runs that never began — and the menu bar's menu
  leads with "restic is missing — backups are on hold.", promises no next run,
  and each grey *Back Up* row says "restic is missing." The quiet-plan alert
  still names a plan the absence leaves unprotected. restic found again
  (*Re-detect* in Settings, or a relaunch) lets the due plans run.
- **Pause** — *Pause Backups* in the menu bar holds every scheduled backup,
  check and prune for an hour, until tomorrow or until resumed; *Pause and Stop
  Running Backups* also stops backups in flight, which start over when the
  pause ends — restic cannot resume a backup. A plan's own *Pause Schedule*
  takes the same lengths. With *Pause scheduled backups on battery power* on,
  the menu bar, the repository pages and Settings say that backups wait for power
  instead of announcing runs that will not start. *Pause scheduled backups on a
  metered network* (off by default) holds them the same way while the network
  is one macOS reports as expensive (its documentation names cellular) or
  constrained — read from `NWPathMonitor`; the hold itself was checked with a
  debug override, the detection on a real hotspot was not. While a backup or a
  check or prune runs, SwiftRestic holds off idle sleep (`pmset -g assertions`
  lists "SwiftRestic is running a backup") and lets go when the last one ends;
  the display may still sleep, and a closed lid still sleeps the Mac.
- **Browsing and restore** — every *Browse*, *Restore Files…* and *Show in
  Backups* opens the one browser, at that backup in the sidebar: a
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
  that it is the first of its folders. A removed item has no row to mark, so
  under a finished comparison the header names what the previous backup held
  and this one does not ("Removed: old.txt, sub" — a removed folder once, not
  everything in it), the full paths in its tooltip. Each name there — and in
  a Files folder's "Removed:" line — is a link to the copy the previous
  backup holds: its versions on the Files tab, opening at that backup. The Files view (above) walks one
  folder or file through every backup that holds it: *Show Versions*, in an
  item's right-click menu here and on Find Files' results, opens the item
  there — on the Files tab of the plan or group the backup belongs to, at
  that backup; on Find Files' index results the version count ("of 12 ›") is
  a button to the same place. The file
  list answers Finder's outline keys: → opens a folder, ← closes it or steps to
  the folder that holds the selection. Its search covers the open backup and
  says how many matches only other backups hold; *Search All Backups…* carries
  the search on in Find Files. A hit drags to Finder as a tree row does.
- **Find files across snapshots** — search every snapshot for a name or glob when
  you do not know which backup still has the file, then restore the match
  (while the index still reads, a word with no glob character is looked for
  inside names, as `*word*`). It
  opens on the repository you are looking at — a selected repository's or
  backup record's; the first repository when the selection names none
  (Activity, the console, nothing) — unless a *Search All Backups…* handed a
  search over (the Restore pane's, or a Files tab's with no match), which
  names its own repository. *Repository › Find Files in Snapshots…* (⇧⌘F)
  opens it — except on a plan's or a group's page, where it turns the page
  to its Files tab and puts the keyboard in its search field, which
  searches that page's backups. Each path is one row at the newest backup
  that holds it, with how many backups do ("of 4 ›", Show Versions) —
  whether the index answered or `restic find` did, so a common name does not
  list a row per backup; a search of the latest snapshot only says "this
  one". ⌘- or ⇧-click selects several rows, and *Restore Selected…* (Return)
  restores them together through the destination sheet, each from its own
  row's backup ("from 2 backups, each item from the one it was found in"),
  an item inside a selected folder left to the folder.
- **Compare snapshots** — *Compare with Previous…* on a backup run in Activity
  runs `restic diff` against the previous snapshot of the same folders from the
  same Mac (any earlier one can be chosen) and lists what was added, removed or
  modified, filterable by kind and path, with restic's byte totals, under a
  header that names the repository the diff ran against. Answers
  "what did last night's backup actually pick up?" without restoring anything.
  A row leads on: its right-click menu has *Show Versions* (also a
  double-click), which closes the sheet onto the item's Files tab, and
  *Restore “…”…* through the destination sheet — both from the backup of the
  two that holds the item, the newer for an added or changed one, the older
  for a removed one. The restore lists the item's node with restic first, as
  Find Files does for an index hit: a diff names a path and a kind, never a
  node.
- **Start at login** — the scheduler only runs while the app runs, so SwiftRestic
  can register itself as a login item and sit in the menu bar.
- **Maintenance** — scheduled `check` and `prune` per repository, on a day
  interval, plus manual runs, stale lock removal and repository stats, and a
  plan's retention applied on demand (*Plan › Apply Retention Now…* previews
  with `restic forget --dry-run --no-lock`, then asks). The repository page's
  *Last check* and *Last prune* read the newest such run in Activity and say
  how it ended when it did not succeed ("3 days ago · failed", "· errors
  found", "· cancelled"); the stamp the scheduler keeps — written for every
  attempt, so a failing check is not retried every minute — is read only
  when the history holds no run as new as it.
- **Hooks** — shell commands before a backup and after success, warnings or
  failure, and per repository before and after a check or prune. Context arrives
  as `SWIFTRESTIC_*` environment variables; a before hook can be set to call the
  run off.
- **Alerts** — webhooks, Slack, Discord and Healthchecks.io, per run outcome.
  Locally, besides a notification per failed or warning backup (*Notify when
  a backup fails or finishes with warnings*, the alert channels' own event
  words) and, if wanted, per successful one, one for a scheduled plan gone quiet: *Notify when a scheduled plan
  has not backed up for* 3, 7 (the default) or 14 days, or never, in Settings ›
  General. A plan whose drive is unplugged at every slot, or whose slots the
  Mac sleeps through, writes no failed run, so nothing else would say it. It
  names each plan once per quiet stretch — "No successful backup in 8 days —
  the last one was …", the mark saved on the plan — and that plan's next
  success re-arms it; clicking it opens the plan. Only plans the scheduler
  would start count: paused, manual, incomplete or running plans never, nor
  anything while Pause Backups or the battery hold is on. The window is the
  setting or one schedule interval and a day, whichever is longer, so a
  weekly plan is not named the hour before each run. It is checked on the
  scheduler's minute tick: a Mac asleep the whole time hears at its first
  tick after waking. The menu bar's dot and problem line stay run-driven.
- **restic console** — run any restic command against a repository and read its
  own output, for the things the UI does not cover (*Repository › restic
  Console…*). A command that may change the backups — the ones it confirms
  first, and `tag` and `copy` — re-reads the repository's listing when it
  ends, so the sidebar, the Files tabs and the counts drop what a `forget`
  removed without waiting for the next refresh.
- **Activity** — every run recorded with its outcome, its repository, duration,
  bytes added, the files restic could not read, and a plain-text log of what
  restic printed (Show Log…, Copy Details); the drawer below a selected run
  opens its plan or its repository, and restores record which backup, which
  item and where it went. Run names carry their repository on every surface
  that names a run — the log sheet's header, notifications and failure
  alerts, the menu bar and Settings. The history keeps the newest *Keep runs*
  records (Settings › General › History) and trims the oldest with their
  logs, except what a standing problem still reads: each plan's newest
  failed or completed-with-errors backup until a later success fixes it — its
  caption and dot read it however old — and any other run's problem for the
  week the Recent problems card, the Activity badge and the menu bar count.
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
  snapshots hold a path, and a name search across all of them — for the Files
  view's tree and versions, Find Files and the Restore pane's search — plus cached
  folder listings, diffs and a file's `restic find` answer per backup. One
  SQLite file per repository,
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
`activity`, `find`, `console`), plus `files` — the first plan's page on its
Files tab, its first source open and selected, or the item
`SWIFTRESTIC_CAPTURE_ITEM` names (an absolute path under that source, a folder
spelled with a trailing `/`) with every folder above it open, and with
`SWIFTRESTIC_CAPTURE_SEARCH` its search field holding that query — and
`orphanGroup`, `movedGroup` and `lineage` — the page of the first adoptable
group under Other backups, of the first moved plan's group, or of the first
untagged lineage, with its sidebar fold open. All three wait for the snapshot
listing that builds group rows, like `restore` does.
`SWIFTRESTIC_CAPTURE_TAB=files` puts the page a run selects — a plan's or a
group's — on its Files tab. `findMoved` opens Find Files on the page of the
first plan's repository that is not the first, so a shot shows the picker
starting on the selection's repository rather than the landing pane's (a
configuration without such a plan stops the run). `filesSearch` asks ⇧⌘F's
route on the first plan's page: the Files tab with its search field focused
(`SWIFTRESTIC_CAPTURE_VERBOSE=1` logs each window's first responder). `all` instead photographs
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
on its Retention tab), `SWIFTRESTIC_CAPTURE_FIND` runs a search on arrival
in the first repository (with `SWIFTRESTIC_CAPTURE_PANE=find`),
and `SWIFTRESTIC_REPO_PASSWORD` hands repositories a password directly (only
honoured together with `SWIFTRESTIC_CONFIG_DIR`), so capture runs never read
the login Keychain for a password. Writes are not redirected: saving a
repository editor or a Change Password in such a run writes to the login
Keychain. Capture runs also do not arm the scheduler, so a due plan
cannot fire mid-capture. `SWIFTRESTIC_POWER_SOURCE` (`battery`/`ac`, debug
builds only, honoured only with `SWIFTRESTIC_CONFIG_DIR`) stands in for the
power adapter at each scheduler tick, so the battery hold can be looked at on
a Mac that stays plugged in — in a normal launch, since a capture run never
arms the scheduler and so never reads it. `SWIFTRESTIC_NETWORK`
(`metered`/`unmetered`, the same gates) stands in for the network path, for the
metered-network hold. `SWIFTRESTIC_LOGIN_ITEM_INSTALLABLE=1`
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
  and shows it first in Settings › General; an ad-hoc-signed build (Release)
  may need it granted again after each rebuild or update. A run's unreadable items
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
  on the next tick, so nothing is silently lost. Plans due on one repository
  in the same minute start one at a time, the most overdue first: started
  together, one's retention lost the lock to the other's.
- `prune` is ordered ahead of `check` when both fall due, so the app does not
  race itself. A launch reads the repositories before arming the scheduler.
- If retention still loses a lock race, the snapshot already exists: the run is
  recorded as *completed with errors* with the reason, never as a failure.
- A file's `find`, a folder's `ls`, *Compare with Previous*'s `diff`, the
  refresh's listing and `stats`, and the index's walks run with `--no-lock`.
  Locked, each paid restic's 200 ms wait after writing its lock; while `forget`
  or `prune` held the exclusive lock it failed at once (exit 11); and a
  `forget` starting while it held its lock failed the same way.

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
- **Debug builds are signed with an Apple Development certificate**
  (`project.yml`, the Debug configuration), not ad hoc. An ad-hoc signature's
  designated requirement is the build's cdhash, so every rebuild was a new
  application to the Keychain and asked for the repository passwords again;
  the certificate's requirement — the bundle ID and the certificate's name —
  is the same from build to build. The first launch under it asks once:
  choose *Always Allow*. Building on another Mac needs that Mac's own
  certificate there, or `CODE_SIGN_IDENTITY=-` for an ad-hoc build. Release
  stays ad hoc.
- **The menu bar's dot goes once the next backup works.** A failed or warned
  backup puts a dot on the menu bar icon and a line naming it in its menu;
  the same plan's next successful backup clears both, as it clears the plan's
  own failure row.
  A failed check, prune, retention run or restore keeps the dot for seven days,
  since a backup going through fixes none of them. Activity's badge and a
  repository's Recent problems keep the week's record either way.
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
  `~/.ssh/config` entry with an explicit `IdentityFile`. Nor can SSH ask to
  accept a server's key without a terminal: connect once with `ssh` in
  Terminal first. A refused host key (`Host key verification failed`, which
  restic 0.19.1 prints only as a `subprocess ssh:` stderr line beside its JSON
  error) is named in the failure, with the way to fix it — new server or
  changed key. A server on a port other than 22 takes it in *Port*: only
  restic's URL form carries one (`sftp://user@host:2222//absolute/path`, its
  path percent-encoded), while the colon form cuts the host at its first
  colon, so a port typed into *Host* would be dialed as 22 with the port read
  as the start of the path — the editor refuses it there.
- No cron expressions: the schedule covers manual, every N hours, daily and
  weekly. No rclone-style remote *management* either — configure remotes with
  rclone itself.
- restic is not downloaded or updated by the app. That is Homebrew's job;
  fetching executables from a GUI is a signing and quarantine mess.
- Release builds are ad-hoc signed, with the hardened runtime off. Distribution would
  need a Developer ID, hardened runtime and notarization — and note that
  re-signing changes which Keychain items the app can read.
- *Compare* keeps the first 20,000 changed paths and says so when it stopped;
  the totals in the tiles come from restic's own statistics line and are always
  complete. Metadata-only changes (permissions, owner, timestamps) are hidden
  unless *Include metadata changes* is on, matching `restic diff --metadata`.
  Comparing snapshots of different folders or hosts is allowed but mostly shows
  everything as added and removed; the sheet says so when you pick one.
- *Find files* with **Latest snapshot only** means the newest snapshot in the
  repository, not the newest per plan. The box shows only once the sheet knows
  the search will walk snapshots with restic, never while it is still asking
  the index, whose search covers every snapshot anyway. If two Macs write to one repository the
  latest snapshot may belong to the other one — search all snapshots there.
- The UI is English only. Two strings (the find-pattern placeholder and the
  /bin/sh note that mentions `SWIFTRESTIC_*`) are `Text(verbatim:)` because
  SwiftUI parses literal titles as Markdown and ate the `*` in the glob
  example; those would need rewording if the app were ever localized.
