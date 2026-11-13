# SwiftRestic

Agents write this project entirely. It is fully optimized for agent vibe
coding, debugging and RSI (recursive self-improvement): this README is the
only file written for humans. Everything else, code, comments and tests, is
written by agents for agents, and the code itself is the documentation.

SwiftRestic is a native macOS backup app in the spirit of Arq, with
[restic](https://restic.net) doing the work underneath. It backs up folders
on a schedule to local disks, SFTP servers and S3-compatible storage such as
Backblaze B2; browses and restores any backup; keeps
a searchable index of every file in every backup; removes old backups, frees
their space and verifies each backup location; and reports through macOS
notifications, webhooks, Slack, Discord and Healthchecks.io.

## Requirements

- macOS 15 or later.
- Nothing else. restic 0.19.1 is inside the app, and the app runs only that
  copy, whatever else is on the Mac. It updates with app updates; its
  license (BSD 2-Clause) is in the About window.
- Full Disk Access (System Settings ▸ Privacy & Security), or macOS
  withholds `~/Documents`, `~/Desktop` and the like and backups end
  incomplete. The app asks for it when you set up your first backup.

## Build, run and test

```sh
brew install xcodegen
./build.sh                     # regenerate the Xcode project, then build
./build.sh test                # unit tests and end-to-end tests against the bundled restic
open SwiftRestic.xcodeproj     # or work in Xcode
```

The build downloads the pinned restic into `.build/` once and checks its
SHA-256. To move to a new one, change the version and both checksums in
`Tools/fetch-restic.sh`, then run the tests.

Debug builds are signed with the author's Apple Development certificate. On
another Mac, build ad hoc:

```sh
SWIFTRESTIC_ADHOC_SIGN=1 ./build.sh test
```

Release builds are ad hoc signed with the hardened runtime off. Distribution
would need a Developer ID, the hardened runtime and notarization, for the app
and for the restic inside it.

## Where it keeps things

- Settings: `~/Library/Application Support/com.newlix.SwiftRestic/config.json`,
  with the two previous generations beside it.
- Backup location passwords and storage secrets: the login Keychain.
- The search index: one SQLite file per backup location, `index/` beside
  `config.json`. It holds the path of every file in every backup, unencrypted,
  and is rebuilt from the location on request.
- Each run's log: `Logs/` beside `config.json`, deleted with its run record.
  It holds the restic command lines and restic's messages, never a password.

## Good to know

- Scheduled backups need the app running. There is no daemon: while any plan
  has a schedule, the app starts at login, once it is in `/Applications`,
  since a login item registered from a build folder goes stale. It stops
  when no plan has one. To turn it off, use System Settings ▸ General ▸
  Login Items.
- One switch, *Notify when a backup succeeds*, sends successes to macOS
  notifications and every webhook; failures always go. A webhook's service
  (Slack, Discord, Healthchecks.io, or plain JSON) is read from its address.
  Healthchecks hears every run.
- The app is not sandboxed. restic has to read any folder and reach the
  network, and a sandboxed app confines its children.
- *Back Up a Folder…* starts the plan's first backup as soon as it is
  created; the plan then backs up every day until its schedule is changed.
- SFTP from a GUI app has no `SSH_AUTH_SOCK` and no terminal: use a key
  without a passphrase, or an `~/.ssh/config` entry with an `IdentityFile`.
  A new server's host key is accepted on first connection
  (`StrictHostKeyChecking=accept-new`); a key that changes later is refused.
- The UI is English only.

## For agents

The conventions for working here are in `CLAUDE.md`. The source tree under
`Sources/SwiftRestic/` is the only description of how the app works; read it
with the tools, not through prose.
