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

The icon is drawn in code: `swift Tools/GenerateAppIcon.swift` writes all ten
renditions plus `Contents.json` into
`Sources/SwiftRestic/Assets.xcassets/AppIcon.appiconset/`, each rendered
natively from vectors so strokes stay crisp at 16pt. The two-plate stack is
the same construction at every size, with the numbers the menu bar's icon
draws, so the Dock icon and the tray read as one mark. The 16 and 32 pixel
renditions draw a coarser glyph — heavier stroke, wider arrow angles, no
shadow — since the large rendition's thin stroke falls below a pixel there;
the variant is chosen by pixel count, so 16pt@2x and 32pt@1x match. Re-run
the generator after editing it; the PNGs are checked in.

## What it does

- **Repositories in the sidebar** — each repository is a row with its plans
  always in view beneath it (or *New Backup Plan…* while it has none), and
  each plan folds open to its backups there. → and ← on a plan's row show and
  hide them; on a backup row ← goes to the row its fold hangs from (a plan's
  or a group's) and a second ← folds it, and the row's menu offers *Hide This
  Plan's Backups*. Backups no plan of the repository made — from another Mac
  or the restic console, a deleted plan, a plan that now backs up elsewhere —
  sit under *Other backups*, grouped by the plan that made them (its
  `swiftrestic-plan-` tag, so a deleted plan's history stays one group), or,
  for backups no plan made, by restic's own `host,paths` grouping. Each
  group's caption says which kind — *not set up here*, *now backs up to
  “Offsite”*, *outside SwiftRestic* — and names the Mac its newest backup came
  from when that isn't this one. A plan's row gives its last backup (*“Last
  backup 1 hour ago”*); its page, the tray and Settings say when it runs next,
  and the tray's menu carries each repository's Protection line (*“Home NAS —
  3 of 3 plans protected · Last backup 3 hours ago”*), so the window need not
  open. A repository wears a warning, its tooltip naming the plan, while a
  plan is not protected — backups unreadable, none yet, or the last one
  failed.
- **Overview | Files** — a plan's page has both in the window toolbar.
  Overview is its cards. Files is a tree on the left (drag its edge to widen
  it) of the folders and files of every backup the plan made, from the
  snapshot index — filling in while the index still reads, the newest backup
  alone for a plan it holds nothing of yet — and the picked item on the
  right; a first visit opens at the plan's first folder. Items the newest
  backup no longer holds are dimmed with the day they were last backed up
  (*until Oct 2*) where the whole name fits beside it; the tooltip and the
  pane's header say it in full. A folder lists at most 200 items in the tree,
  then a row that opens it in the pane. Each page keeps its tab, open folders
  and selection while the app runs, and opens on Overview after a launch.
  - *A folder* lists as a backup held it, each file with its size. *As
    backed up* picks which backup, newest first, grouped by month once they
    span more than one — as the Compare sheet's picker and the sidebar's
    backups are (an inert month caption above each month's rows; past three
    months both pickers fold each older month into a submenu, the newest
    month staying in reach, while the sidebar keeps its captions). One line
    says what changed in the folder itself since the backup before that
    holds it (*Since Oct 1, 2026 at 9:15 AM, in this folder: 2 modified*),
    naming what is gone and marking each item *Added*, *Modified* or *May
    have changed* — from the index's record of the diffs, no restic, and
    nothing of its subfolders or of metadata alone. Items select several at
    a time and restore together, drag to Finder, or open in the tree with a
    double-click, keeping the chosen time where they existed then; with
    nothing selected, *Restore Folder…* restores the whole folder.
  - *A file* lists its versions, from the index: a version starts where
    restic's diff said the file changed, or where no diff compared two
    backups or the file was absent between them. A row gives its
    modification time and size, the size's move from the version below
    (*+17 bytes*, *Same size*, or *May be identical* where no diff split the
    two and the sizes cannot), and for a content several backups held, which
    (*In 4 backups · Oct 2 – Oct 4, 2026*). Past one month they group by
    month, each under the month of the first backup that held it — the one
    after its change, so its *Modified* month give or take one interval.
    Time and size come from one `restic find` of the exact path (glob
    characters escaped) per backup, kept by the index, so a file revisited
    — after a relaunch too — runs no restic; an opened folder's files are
    read ahead in one `find` once the index has read every backup. Above
    the versions, for a file this Mac backed up by its own path, one line
    says what the copy here is: *the same as the newest version*, the same
    as an older one, none of them (with its own date and size), or *Not on
    this Mac* — one `lstat`, compared by size and modification time to
    restic's millisecond, read again when a restore ends. *Restore…* or
    Return restores the chosen version, confirming "the version modified Sep
    17, 2026 at 9:00 PM, from the backup of Sep 17, 2026 at 11:00 PM"; a row
    drags to Finder. *Preview* shows it in Quick Look: `restic dump` copies
    it, read-only, into a temporary folder of its own, deleted when the
    preview closes, another version is chosen or the pane goes (a quit
    leaves it to the next launch's sweep); it waits for the size and stops
    at 1 GB. *Show in Backups* opens the chosen backup at that place under
    its plan in the sidebar, scrolling a fold sixteen months long to its
    row, as the tree scrolls to a revealed item.
  - *The search field* heading the tree lists, in its place, the items of
    this plan's (or group's) backups whose names have words starting like
    the query — from the index, instant, dropped items dimmed as in the
    tree — each under its folder. A hit selects as a tree row does; Return
    or Esc ends the search on the tree with the hit's folders opened and
    its row in view. While the index still reads, the search says older
    backups may be missing, and one with no match offers *Search All
    Backups…*, Find Files over the whole repository.
- **A group under Other backups is a page** — its row selects like a plan's
  (the chevron folds), with the same Overview | Files. Overview says what
  the history is: a plan not set up here (deleted, or running on another
  Mac), a plan that now backs up elsewhere (*Open the “Music” Plan*), or
  backups no plan made, which can't be adopted. Its Backups card brackets
  the history (newest, oldest), names the Macs and folder sets, carries the
  exclude patterns and user tags, and shows the plan tag when there is one —
  selectable, the one honest identifier. *Restore Files…* opens the newest
  backup; the context menu has it and *Show Files*. An untagged lineage's
  files come from the index's chain of its host and folders. A folder
  backed up by a relative path (`restic backup Documents` from the console,
  in the home folder) shows where restic put it, `/Documents`, though the
  backup names `/Users/…/Documents`.
- **Adopting** — a group whose ID no plan anywhere carries can be adopted:
  *Adopt as a Backup Plan…* (the page's explanation card, the group's
  context menu, or the repository page's *Other backups* card, listing each
  adoptable group while there is one) opens the plan editor with the group's
  name and, from the newest backup this Mac made — or the newest of all when
  another Mac made them all — its folders, exclude patterns and user tags;
  the repository is locked to the backups' own, the schedule is Daily only
  when every prefilled folder exists here, and retention is off. Adopting
  writes one plan whose ID is the group's UUID and nothing else: no snapshot
  retagged, nothing written to the repository; the records move under the
  plan by themselves. A group with a backup from another Mac, or one less
  than 48 hours old, is asked once more. Deleting a plan says its snapshots
  stay under Other backups and can be adopted back; moving one to another
  repository says what stays behind — never thinned, since retention runs
  against the plan's current repository only.
- **A repository's page is its overview.** A *Protection* line (“2 of 2
  plans protected · Last backup 1 hour ago”; with no plans, the count of
  backups from no plan here) carries the hold's words while backups are held
  app-wide, and a *Resume* button while the hold is your own *Pause
  Backups*. Under it each unprotected plan is named with its warning, and
  each protected plan that will not run by itself — paused, or "Not
  scheduled" for an incomplete setup — with a pause glyph in the sidebar's
  words ("Photos: Paused — Sunday at 03:00"), so "2 of 2 plans protected"
  cannot hide a stopped plan (a manual plan gets no line). The card carries
  *New Backup Plan…* while the repository has no plan; after that a plan
  starts from the sidebar's + or ⌘N (into the repository on screen) or the
  repository row's menu. Then the *Other backups* card; the week's problems
  — a repeating cause (one unreadable file every run) is one row with its
  count ("7 times · 19 hours ago") opening the newest, and past five rows a
  last "… and N more in Activity" row opens Activity's Problems; then
  location, size and maintenance. The *Snapshots* row splits off backups no
  plan here made (“11 · 6 from no plan here”, or “all”) and says how far
  back the history reaches (“509 · 3 from no plan here · since Jun 1, 2025”,
  the oldest backup's moment in the tooltip), as a plan page's does for its
  own, so whether last March can be reached is answered before browsing. A
  repository whose first listing finds no plans but adoptable history opens
  its *Other backups* shelf — no modal, no wizard.
- **Repositories** — local disk, SFTP, S3-compatible, Backblaze B2, Azure Blob
  Storage, Google Cloud Storage, an rclone remote, or a restic REST server.
  The editor asks *Where is it?* — on this Mac, on another machine, in the
  cloud, through a gateway — and groups the kinds that way. Creating one runs
  `restic init`; a repository that cannot be reached is not saved. *Test
  Connection* on a path with no repository says what Save will do: create
  one for a new repository; for an existing one nothing — "backups to it
  would fail until one is created", so point it at the folder that holds it.
  The answer shows above the buttons on either tab, a new repository's empty
  location as information, not the red of a failure. An edit's *Save* that
  changes what reaches restic — location, a credential, the extra
  environment, the password — runs the same check and saves only on
  "Connected", else says why and offers *Save Anyway* (for a server down
  while its path is being fixed); the form waits during either check, so
  Save stores what was checked. A rename, a maintenance setting or a hook
  saves at once. The check gives up after 60 seconds: against a REST server
  refusing connections, restic 0.19.1 retried for over ten minutes. A REST
  server's login goes in *User* and *Server password* (Keychain, like every
  backend secret) and reaches restic as
  `RESTIC_REST_USERNAME`/`RESTIC_REST_PASSWORD`, so the stored and shown URL
  holds no password; a pasted URL sheds its login into those fields, and one
  saved with it keeps working, since restic prefers a URL's own credentials.
  *Change Password…* runs `restic key passwd` with the stored password, the
  new one in a file only this user can read, deleted when restic ends; only
  then does the Keychain take it. It asks first — the old password stops
  working everywhere — and waits while a backup or maintenance job holds the
  repository, since restic fails at once under another lock (exit 11, restic
  0.19.1). A refused change (exit 12: the stored password does not open it)
  stores nothing; a new password with spaces at its ends is refused, since
  restic trims them from a file and the Keychain would disagree. A
  repository this Mac holds no password for — a configuration carried to
  another Mac (secrets never live in it), a Keychain item removed — says so
  in the editor's Encryption caption: "No password is stored for the
  repository “Home NAS”. Enter it here to read it and back up to it."; *Save*
  and *Test Connection* wait, the reason beside them, as the listing and the
  Maintenance card already report. restic is never handed an empty password
  (its refusal and `--insecure-no-password` advice are for a terminal), and
  until one is entered the repository cannot be renamed or re-hooked, by
  design.
- **Backup plans** — a set of folders, exclude patterns, a schedule and a
  retention policy, pointed at one repository. Each plan stamps its snapshots
  with a private tag so retention can only ever touch its own. A plan's page
  is three cards, each with its verb in its corner, all also in the Plan
  menu and the row's menu: *Backups* (last backup, count, retention) with
  *Back Up Now* — *Stop* while it runs; *Schedule* (and when it runs next)
  with *Pause Schedule*, its arrow offering the lengths, or *Resume Schedule*
  (none for a manual plan); *Configuration* (folders, exclude patterns,
  hooks) with *Edit*. While the newest backup failed or completed with
  errors and none succeeded since, a problem card sits under *Backups*: the
  outcome, the week's count ("3 times · 2 days ago"), restic's message, the
  facts, the drawer's diagnosis, and up to five unreadable items with the
  drawer's *Reveal in Finder* and *Exclude from “Documents”…* menu, then "…
  and N more in Activity"; *Show in Activity* opens the run. The editor
  preselects the repository only when there is just one, says when a folder
  is not on this Mac, takes excludes chosen in a panel or dropped from Finder
  as their own paths (glob characters escaped), and shows *Next backup* for
  the schedule being chosen, as Save would store it. *Skip online-only cloud
  files (iCloud Drive, OneDrive)* passes restic's `--exclude-cloud-files`: on
  for new plans, off for plans saved before the option (their backups do not
  change under it), and only with restic 0.19 or later, which brought the
  flag to macOS (restic's changelog) — the editor says when this restic is
  older. What restic does with an online-only file without the flag was not
  tried: it would mean reading a real iCloud Drive file.
- **Skipped backups** — when every folder of a plan is missing, restic writes
  nothing (exit 1, "Fatal: all source directories/files do not exist",
  restic 0.19.1). The run is recorded as *Skipped*, its reason in Activity's
  Detail column, the drawer and Copy Details: "“Archive SSD” is not
  connected." when the folders live on volumes, else "None of its folders
  are on this Mac." It is no failure — no dot, notification, banner or
  problem row (a channel with a start ping hears a fail, as for a cancel) —
  and it stamps the slot, so an hourly plan does not retry every minute. A
  scheduled *Skipped* posts nothing, but a *Back Up Now*, which ends in
  milliseconds, gets a passing banner: "“Documents” skipped — “Travel SSD” is
  not connected." When a volume mounts, each scheduled plan whose newest
  backup was skipped and whose folders are all back runs at once (a disk
  image attached with `-nobrowse` counted); if the drive stays away the
  quiet-plan alert speaks.
  - *Repeats merge.* A skip that continues the plan's last one — same
    reason, both writing a snapshot of the other folders or neither, same
    stored lines, the earlier without a hook's complaint — replaces it and
    its log: one record reading "“Archive SSD” is not connected. Skipped 24
    times since …", with a *Since* row in the drawer and a "Skipped since:"
    line in Copy Details; the earlier runs' snapshots still resolve to it,
    keeping their incomplete mark. A week away is one row, not 168, and
    "Keep runs" stays for real runs.
  - *Partial skips.* Some folders missing is restic's exit 3 with a snapshot
    of the rest. When every folder skipped is on an unmounted volume and
    everything else was read, the run is Skipped too — "“Archive SSD” is not
    connected; the other folders were backed up." — keeping its snapshot,
    numbers and *Last backup*: it heals an older failure, pings Healthchecks
    alive, and the mount reruns it in full. It is not a whole backup: the
    quiet-plan alert counts from the last backup that read every folder, so
    it still speaks for the away drive — "“Archive SSD” has not been backed
    up in 14 days — the last backup that included it was …; the plan's other
    folders are still backed up." — and the repository page's Protection
    card names the standing skip under its count with Activity's skip glyph.
    A plan stamped only before this build counts from its last backup until
    its next whole one. A skipped folder whose drive is here, or any other
    unreadable item, keeps the run *Completed with errors*, every skipped
    folder among its items.
  - *The repository's side.* A backup to a local repository under /Volumes
    whose volume is not mounted (checked after the before-backup hooks,
    which may mount it) is Skipped with "“Travel SSD” is not connected."
    without asking restic, and runs when the volume mounts. restic cannot
    tell that from a moved folder — both exit 10, "Fatal: repository does
    not exist: unable to open config file" (restic 0.19.1) — so a folder
    under /Volumes counts only while it is the root of a mounted volume; with
    the volume here and the folder gone the run fails, fixed by *Edit
    Repository…*. The listing follows the same check: with the volume away
    restic is not asked, no banner posts, and the sidebar row reads "“Travel
    SSD” is not connected." and the caveat "Can't read snapshots — “Travel
    SSD” is not connected.", earlier rows staying. A skipped run shows on the
    listing at once, and a mount re-reads the listings of the repositories
    on it, paused or not.
- **Scheduling** — hourly / daily / weekly, checked once a minute; a daily
  window missed asleep runs on waking. While restic cannot be found the
  scheduler starts nothing (no Failed record, banner or notification per
  slot), the menu bar's menu leads with "restic is missing — backups are on
  hold." and promises no next run, each grey *Back Up* row says "restic is
  missing.", and the quiet-plan alert still names plans left unprotected.
  *Re-detect* in Settings, or a relaunch, lets the due plans run.
- **Pause** — *Pause Backups* in the menu bar holds every scheduled backup,
  check and prune for an hour, until tomorrow or until resumed; *Pause and
  Stop Running Backups* also stops backups in flight, which start over when
  the pause ends (restic cannot resume one). A plan's *Pause Schedule* takes
  the same lengths. With *Pause scheduled backups on battery power* on, the
  menu bar, repository pages and Settings say backups wait for power rather
  than announce runs that will not start. *Pause scheduled backups on a
  metered network* (off by default) does the same while `NWPathMonitor`
  reports the network expensive (macOS's documentation names cellular) or
  constrained — the hold checked with a debug override, the detection on a
  real hotspot not. While a backup, check or prune runs, SwiftRestic holds
  off idle sleep (`pmset -g assertions` lists "SwiftRestic is running a
  backup"); the display may still sleep, and a closed lid sleeps the Mac.
- **Browsing and restore** — every *Browse*, *Restore Files…* and *Show in
  Backups* opens the one browser at that backup in the sidebar: its folders
  as a tree with a Change column and search. Restore by dragging to Finder,
  by *Restore…* (or Return) on a selection, or by *Restore Entire Backup…*,
  which recreates the full original paths inside the chosen folder;
  per-node restores land in the chosen folder with no path rebuilt above
  them. ⌘- or ⇧-click selects several, restored with one `restic restore`
  per folder they come from (each run reloads the repository's index), an
  item inside a selected folder left to the folder (the sheet says so), and
  two items of one name allowed back to their original locations but never
  into one folder. The list answers Finder's outline keys: → opens a folder,
  ← closes it or steps to the folder holding the selection, both on every
  selected folder. Both restores ask where — the Desktop, another folder, or
  the original location — and whether files there are kept (the default,
  `--overwrite never`, which still replaces a file standing where the backup
  has a folder of that name and gives existing folders the backed-up
  permissions and dates) or replaced (`--overwrite always`, comparing
  contents rather than size and date), confirming when something is there
  to replace. restic before 0.17 has no `--overwrite`; keeping then restores
  a folder or whole backup only where nothing is there yet.
  - *The Change column* compares with the previous backup of the same
    folders from the same Mac — not the row below, which for a plan whose
    folders changed is a backup of other folders; the header names the open
    backup and what it is compared with, or that it is the first of its
    folders. A folder the diff names only inside carries “N inside” (the
    tree root's equal to the header's count, the kinds in its tooltip), so a
    collapsed root does not read as unchanged. Under a finished comparison
    the header names what the previous backup held and this one does not
    ("Removed: old.txt, sub" — a removed folder once, not its contents), the
    full paths in its tooltip; each name there and in a Files folder's
    "Removed:" line links to the previous backup's copy on the Files tab.
  - *Into the Files view.* *Show Versions*, in an item's right-click menu
    here and on Find Files' results, opens it on the Files tab of the plan
    or group the backup belongs to, at that backup; on Find Files' index
    results the version count ("of 12 ›") is a button to the same place.
    The search covers the open backup, says how many matches only other
    backups hold, and *Search All Backups…* carries it on in Find Files; a
    hit drags to Finder as a row does. A file's right-click menu here, in its
    hits and on Find Files' results has the Files tab's *Preview*, gated by
    the same size (a hit, which the index keeps no size for, is listed by
    restic first).
- **Find files across snapshots** — search every snapshot for a name or glob
  when you do not know which backup still has the file, then restore the
  match (while the index still reads, a word with no glob character is
  looked for inside names, as `*word*`). *Repository › Find Files in
  Snapshots…* (⇧⌘F) opens it on the repository in view — the selected
  repository's or backup record's, else the first (Activity, the console,
  nothing) — or on the repository a *Search All Backups…* handed over (the
  Restore pane's, or a Files tab's with no match). On a plan's or group's
  page ⇧⌘F instead turns the page to Files and focuses its search field.
  Each path is one row at the newest backup holding it, with how many
  backups of that backup's plan or group do ("of 4 ›", Show Versions) — the
  count its Files tab lists, so a copy a Home plan holds beside a Documents
  plan's is that plan's to list — whether the index or `restic find`
  answered; a latest-snapshot-only search says "this one". Before the
  listing lands, rows name their backup by short ID in the Snapshot column,
  times filled in when it lands without moving the rows. ⌘- or ⇧-click
  selects several, and *Restore Selected…* (Return) restores them in one
  destination sheet, each from its own row's backup ("from 2 backups, each
  item from the one it was found in"), an item inside a selected folder of
  the same backup left to the folder. A folder comes back as its own backup
  holds it, so a file found in an older backup than its folder's (deleted
  since) restores on its own: beside the folder in a chosen folder, back
  inside it at the original location.
- **Compare snapshots** — *Compare with Previous…* on a backup run in Activity
  runs `restic diff` against the previous snapshot of the same folders from
  the same Mac (any earlier one can be chosen) and lists what was added,
  removed or modified, filterable by kind and path, with restic's byte
  totals, under a header naming the repository: "what did last night's
  backup actually pick up?" without restoring anything. A row's right-click
  menu has *Show Versions* (also a double-click), closing the sheet onto its
  Files tab, and *Restore “…”…* — both from whichever of the two backups
  holds the item (the newer for added or changed, the older for removed);
  the restore lists the node with restic first, since a diff names only a
  path and a kind. Several rows restore together as in Find Files:
  *Restore Selected…* (Return) or the right-click *Restore N Items…*, one
  sheet and one run ("from 2 backups, each item from the one it was found
  in"), a row inside a selected folder of the same backup coming with the
  folder (the sheet says so), while a file the newer backup removed
  restores on its own. Choosing another backup or including metadata
  changes clears the selection, since the same path may now be held by
  another backup.
- **Start at login** — the scheduler only runs while the app runs, so SwiftRestic
  can register itself as a login item and sit in the menu bar.
- **Maintenance** — scheduled `check` and `prune` per repository, on a day
  interval, plus manual runs, stale lock removal, repository stats, and a
  plan's retention on demand (*Plan › Apply Retention Now…* previews with
  `restic forget --dry-run --no-lock`, then asks). The repository page's
  *Last check* and *Last prune* read the newest such run in Activity and say
  how it ended when it did not succeed ("3 days ago · failed", "·
  cancelled", or a check's own verdict, "· 2 errors — `restic repair` can
  recover some damage" — the words Activity's Detail column and the Recent
  problems row show, derived once from the record); the row leads to the run,
  whose drawer holds the log, Copy Details and, for a failed check or prune
  or a check that found errors, *Check Again…* or *Prune Again…* — the
  Repository menu's command, same confirmation, grey while the repository is
  busy. The scheduler's own stamp, written for every attempt so a failing
  check is not retried every minute, is read only when the history holds no
  run as new. A repository added from 2026-10-09 on prunes by default, every
  30 days starting 30 days after it is added, since retention runs after
  every backup and only a prune frees the space; one saved before keeps its
  setting. With prune off the Maintenance card says "Prune — Off — the data
  retention removes stays in the repository until a prune" rather than
  hiding its rows.
- **restic's cache** — restic keeps a cache folder per repository it has
  opened here (`~/Library/Caches/restic`), keeps it after the repository is
  removed, and never cleans up: past 30 days unused it only prints, at the
  start of a command nobody sees, that `restic cache --cleanup` would remove
  it. Settings › restic measures it (`restic cache`: size, folder count, how
  many unused) and offers *Remove Caches Unused for 30 Days…*, behind a
  confirmation stating the cost: a repository still set up here that went
  unused that long loses its cache too, rebuilt when restic next opens it —
  over the network for a remote one. Nothing inside a repository is
  touched, and nothing runs on its own.
- **Hooks** — shell commands before a backup and after success, warnings or
  failure, and per repository before and after a check or prune. Context arrives
  as `SWIFTRESTIC_*` environment variables; a before hook can be set to call the
  run off.
- **Alerts** — webhooks, Slack, Discord and Healthchecks.io, per run outcome.
  Locally, a notification per failed or warning backup (*Notify when a
  backup fails or finishes with warnings*, the channels' own event words),
  optionally per successful one, and one for a scheduled plan gone quiet:
  *Notify when a scheduled plan has not backed up for* 3, 7 (the default) or
  14 days, or never (Settings › General) — a drive unplugged at every slot,
  or slots slept through, write no failed run, so nothing else would say it.
  It names each plan once per quiet stretch ("No successful backup in 8 days
  — the last one was …", the mark saved on the plan), re-armed by its next
  success; clicking it opens the plan. Only plans the scheduler would start
  count — never paused, manual, incomplete or running ones, nor anything
  under Pause Backups or the battery hold — checked on the minute tick after
  it starts what is due, so a lapsing pause or a long sleep does not name a
  plan whose overdue backup is starting, and a Mac asleep throughout hears
  at its first tick awake. The window is the setting or one schedule
  interval and a day, whichever is longer, so a weekly plan is not named the
  hour before each run. The menu bar's exclamation mark and problem line
  stay run-driven.
- **restic console** — run any restic command against a repository and read its
  own output, for what the UI does not cover (*Repository › restic
  Console…*). A command that may change the backups — the ones it confirms
  first, plus `tag` and `copy` — re-reads the listing when it ends, so the
  sidebar, Files tabs and counts drop what a `forget` removed at once. A
  check that found errors advises "`restic repair` can recover some
  damage."; its Activity drawer and the Maintenance card offer *Open in
  Console*, opening the console on that repository with its password and
  typing nothing: `repair` stays a command the user writes, confirmed first.
- **Activity** — every run with its outcome, repository, duration, bytes
  added, the files restic could not read, and a plain-text log (Show Log…,
  Copy Details); the drawer opens its plan or repository, and restores
  record which backup, which item and where it went. A failure the drawer
  offers a fix for says the fix in its own words, so the banner and
  notification do too — exit 12 "The password doesn't open this repository
  — check it in the repository settings.", exit 10 "No repository is at its
  saved path — point it at the folder that holds the repository." (*Edit
  Repository…*), exit 11 "The repository is locked — if no other Mac is
  using it, remove the stale locks." (*Remove Stale Locks…*) — each followed
  by restic's first sentence. Every surface naming a run names its
  repository too: the log sheet's header, notifications and failure alerts,
  the menu bar, Settings. The history keeps the newest *Keep runs* records
  (Settings › General › History), trimming the oldest with their logs —
  except what a standing problem reads: each plan's newest failed or
  completed-with-errors backup until a later success (its caption and dot
  read it however old), and any other run's problem for the week the Recent
  problems card, the Activity badge and the menu bar count.
- **Menus** — *Plan* and *Repository* act on the sidebar's selection: a
  plan, a repository, or the repository a selected plan, backup record or
  Other-backups group belongs to; items with nothing to act on are grey.
  ⌘B backs up the selected plan, ⌘. stops it, ⇧⌘B backs up every plan, ⇧⌘F
  finds files, ⌘R refreshes every repository's snapshots; *Pause Backups* is
  there as well as in the menu bar. While a sheet is up, a command that
  opens a sheet or the console, or acts on the selected plan or repository,
  beeps and does nothing; *Back Up All Plans Now*, *Pause Backups*, *Resume
  Backups*, *Pause and Stop Running Backups* and *Refresh All Snapshots*
  still act, since no sheet holds a draft of what they change.

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
- **The snapshot index is a cache of what restic cannot answer quickly**:
  which snapshots hold a path, and a name search across all of them (the
  Files view, Find Files, the Restore pane's search), plus cached folder
  listings, diffs and a file's `restic find` answer per backup. One SQLite
  file per repository, `index/<repository UUID>.sqlite` in the configuration
  folder, stores every path once as a tree of names and, per plan (or
  restic `host,paths` group for backups no plan made), the ranges of
  snapshots each path exists in, so a backup writes only what changed. It
  reads a group's newest snapshot with `restic ls` and, as a rule, each
  other with a `restic diff` against a neighbour already read, keeping what
  the diff says changed (`M`) — so a file's versions are the backups where
  its content changed; a neighbour read in full instead is marked as a step
  that may have changed anything. Its failure never fails a refresh or
  backup: an unusable file is deleted and read again (*Rebuild Search
  Index…* does so on request), and until every snapshot is read Find Files
  searches through restic. Only the `SnapshotIndex*.swift` files touch GRDB.
  At launch, after a clean configuration load, index files of repositories
  no longer configured are deleted — only inside `index/`; the
  `<uuid>.sqlite` files earlier builds left directly in the configuration
  folder are never opened, swept or deleted.

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

All of it is `#if DEBUG`, and needs a logged-in GUI session — not a
headless SSH box. The capture path activates the app at launch on purpose,
since SwiftUI defers the main window until then, so `open` and launching the
binary directly both work. Capture runs do not arm the scheduler, so a due
plan cannot fire mid-capture.

- `SWIFTRESTIC_CONFIG_DIR` points the app at a throwaway configuration
  instead of your real one; `SWIFTRESTIC_REPO_PASSWORD` (honoured only with
  it) hands repositories a password, so the login Keychain is never read.
  Writes are not redirected: saving a repository editor or a Change Password
  writes to the login Keychain.
- `SWIFTRESTIC_CAPTURE` writes a PNG of the front window and quits.
- `SWIFTRESTIC_CAPTURE_PANE` picks the screen: `plan`, `repository`,
  `restore`, `activity`, `find`, `console`; `files` — the first plan's page
  on its Files tab, its first source open and selected, or the item
  `SWIFTRESTIC_CAPTURE_ITEM` names (an absolute path under that source, a
  folder with a trailing `/`) with every folder above it open, and with
  `SWIFTRESTIC_CAPTURE_SEARCH` that query in its search field; `orphanGroup`,
  `movedGroup`, `lineage` — the page of the first adoptable group, moved
  plan's group or untagged lineage, its sidebar fold open (all three wait
  for the listing that builds group rows, as `restore` does); `findMoved` —
  Find Files on the page of the first plan whose repository is not the
  first, so the picker shows it starting on the selection's repository (a
  configuration without one stops the run); `filesSearch` — ⇧⌘F's route on
  the first plan's page, the Files tab with its search field focused
  (`SWIFTRESTIC_CAPTURE_VERBOSE=1` logs each window's first responder);
  `all` — every pane in one run, `SWIFTRESTIC_CAPTURE` naming a directory,
  each pane as `pane-<name>.png`, `SWIFTRESTIC_CAPTURE_DELAY` the settle
  time per pane. The sweep is the whole-window regression check: a defect
  like macOS 26's floating title-bar material shows on every pane, including
  the ones nobody was looking at.
- `SWIFTRESTIC_CAPTURE_TAB=files` puts the plan or group page a run selects
  on its Files tab.
- `SWIFTRESTIC_CAPTURE_SHEET` opens a sheet: `diff`, Activity's compare sheet
  (with pane `activity`); `retention`, the plan editor on its Retention tab;
  `adopt`/`adoptRetention`, the first adoptable group's adopt sheet (with
  pane `orphanGroup`, the latter on its Retention tab).
- `SWIFTRESTIC_CAPTURE_FIND` runs a search on arrival in the first
  repository (with pane `find`).
- `SWIFTRESTIC_APPEARANCE` (`light`/`dark`) pins the appearance.
- With `SWIFTRESTIC_CONFIG_DIR` only: `SWIFTRESTIC_POWER_SOURCE`
  (`battery`/`ac`) stands in for the power adapter at each scheduler tick —
  so in a normal launch, since a capture run never arms the scheduler — to
  look at the battery hold on a plugged-in Mac; `SWIFTRESTIC_NETWORK`
  (`metered`/`unmetered`) stands in for the network path;
  `SWIFTRESTIC_LOGIN_ITEM_INSTALLABLE=1` makes the start-at-login offers
  treat a build-folder copy as installed, so their *Start at Login* button
  can be looked at — registering still refuses from a build folder, so a
  click shows that refusal and registers nothing.

Captures prefer ScreenCaptureKit, which renders Tahoe's glass materials
correctly but needs a one-time grant (System Settings → Privacy & Security →
Screen Recording → SwiftRestic); without it they fall back to
`cacheDisplay`, which draws those materials black on macOS 26, and each
capture logs which backend it used. Keep the session unlocked: on macOS 26 a
locked screen hid the window from this capture entirely (2026-09-14); on
macOS 27.0.1 `screencapture -l` still photographed a window by its ID while
locked, a region capture (`-R`) failed, and this capture was not tried
(2026-10-09).

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
- Grant **Full Disk Access** in System Settings › Privacy & Security. Without
  it macOS silently withholds `~/Documents`, `~/Desktop` and the like, and
  restic writes an *incomplete* snapshot (exit code 3), marked with a warning
  triangle in the sidebar and Activity's drawer; the Restore pane lists what
  could not be read. The grant is detected at launch, on activation and
  after every backup, and shown first in Settings › General; an
  ad-hoc-signed build (Release) may need it again after each rebuild or
  update. "operation not permitted" on an item is macOS withholding it,
  which the grant fixes; "permission denied" is the file's own permissions,
  which it does not.
- Keychain calls are made off the main actor. They block, and macOS can put an
  authorisation dialog in front of them; on the main actor that would freeze the
  UI *and* stop the scheduler until the dialog is answered.
- Hook output is treated as sensitive (see Hooks).
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
a failed run. Only a before hook can be set to cancel the run; one that does
still stamps the schedule, so a hook that always refuses is not retried every
minute. Repositories have hooks of their own around `check` and `prune`
(*before*, *after success*, *after failure*, *after every*), with the same
variables — the plan ones present but empty, never the snapshot one — plus
`SWIFTRESTIC_TASK` (`check` or `prune`). A check that finds errors counts as
a failure for them, the outcome they exist to report, and a failing hook
turns the run record amber as a backup's does.

**A hook's output stays on this Mac.** An arbitrary script can print
anything — a verbose `curl` echoes its own `Authorization` header — so only
the first line of a failing hook's output is kept, stored apart from
restic's warnings, and never sent to a webhook or chat channel.

`forget` runs inside the backup that triggered it, so the plan's after-backup
hooks cover it. *Apply Retention Now…* runs no hooks and sends no alerts: the
banner and Activity announce it, and a Healthchecks ping would reset the
dead-man's switch for a run that backed nothing up.

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
  (`project.yml`, the Debug configuration), not ad hoc: an ad-hoc
  signature's designated requirement is the build's cdhash, so every rebuild
  was a new application to the Keychain and asked for the passwords again,
  while the certificate's — bundle ID and certificate name — stays the same.
  The first launch asks once: choose *Always Allow*. Another Mac needs its
  own certificate, or `CODE_SIGN_IDENTITY=-` for an ad-hoc build. Release
  stays ad hoc.
- **The menu bar's exclamation mark goes once the next backup works.** A
  failed or warned backup puts an exclamation mark where the icon's snapshot
  stack sits — Time Machine's sign, in the bar's own ink, every face being a
  template image — and a line naming it in the menu; the plan's next
  successful backup clears both, and its failure row. A failed check, prune,
  retention run or restore keeps the mark seven days, since a backup fixes
  none of them. Activity's badge and Recent problems keep the week either
  way.
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

- Scheduled runs need the app running: there is no LaunchAgent or daemon.
  Turn on *Start at login* in Settings; the plan editor offers *Start at
  Login* when a save turns a schedule on. Closing the window never quits the
  app — that, not the menu bar item, keeps it resident — but keep the item
  on: it is the only way back into the UI. The toggle refuses to register
  from a build folder (a login item registered from DerivedData points at a
  bundle the next compile replaces, and the stale entry outlives the build):
  move the app to `/Applications` first. On an ad-hoc-signed build macOS may
  still ask for approval in System Settings; the toggle catches up when you
  return. SwiftRestic's own Quit — the app menu, ⌘Q or the menu bar item —
  while a plan is scheduled and start at login is off names the run that
  will be missed; a quit from the Dock, AppleScript, a logout, restart or
  shutdown never waits on that question.
- SFTP repositories do not inherit `SSH_AUTH_SOCK` from a GUI launch, so a
  passphrase-protected key cannot be unlocked: use a passphrase-less key or
  an `~/.ssh/config` entry with an explicit `IdentityFile`. Nor can SSH ask
  to accept a server's key without a terminal: connect once with `ssh`
  first. A refused host key (`Host key verification failed`, which restic
  0.19.1 prints only as a `subprocess ssh:` stderr line beside its JSON
  error) is named in the failure with its fix — new server or changed key.
  A port other than 22 goes in *Port*: only restic's URL form carries one
  (`sftp://user@host:2222//absolute/path`, path percent-encoded), while the
  colon form cuts the host at its first colon, so the editor refuses a port
  typed into *Host*, which would be dialed as 22 with the port read as the
  path.
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
- *Find files* with **Latest snapshot only** means the repository's newest
  snapshot, not each plan's — with two Macs writing to one repository, maybe
  the other one's (search all snapshots there). The box shows only once the
  search will walk snapshots with restic, never while the index, which
  covers every snapshot, answers.
- The UI is English only. Two strings (the find-pattern placeholder and the
  /bin/sh note that mentions `SWIFTRESTIC_*`) are `Text(verbatim:)` because
  SwiftUI parses literal titles as Markdown and ate the `*` in the glob
  example; those would need rewording if the app were ever localized.
