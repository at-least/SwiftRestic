# SwiftRestic

Agents write this project entirely. It is fully optimized for agent vibe
coding, debugging and RSI (recursive self-improvement): this README is the
only file written for humans. Everything else, code, comments and tests, is
written by agents for agents, and the code itself is the documentation.

SwiftRestic is a native macOS backup app in the spirit of Arq, with
[restic](https://restic.net) doing the work underneath. It backs up folders
on a schedule to local disks, SFTP, S3-compatible storage, Backblaze B2,
rclone remotes and restic REST servers; browses and restores any backup; keeps a searchable index of every
file in every backup; removes old backups, frees their space and verifies each backup location;
and reports through macOS notifications, webhooks, Slack, Discord and
Healthchecks.io.

## Requirements

- macOS 15 or later.
- restic 0.19.1 or later on this Mac (`brew install restic`). The app does
  not download or update restic.
- rclone, only for rclone remotes (`brew install rclone`), with the remote
  already configured with `rclone config`.
- Full Disk Access (System Settings ▸ Privacy & Security), or macOS
  withholds `~/Documents`, `~/Desktop` and the like and backups end
  incomplete. The app says so in Settings.

## Build, run and test

```sh
brew install restic xcodegen
./build.sh                     # regenerate the Xcode project, then build
./build.sh test                # unit tests and end-to-end tests against the installed restic
Tools/restic-version.sh 0.19.1 # the real-restic suites on one restic release
open SwiftRestic.xcodeproj     # or work in Xcode
```

Debug builds are signed with the author's Apple Development certificate. On
another Mac, build ad hoc:

```sh
SWIFTRESTIC_ADHOC_SIGN=1 ./build.sh test
```

Release builds are ad hoc signed with the hardened runtime off. Distribution
would need a Developer ID, the hardened runtime and notarization.

## Where it keeps things

- Settings: `~/Library/Application Support/com.newlix.SwiftRestic/config.json`,
  with the two previous generations beside it.
- Backup location passwords and storage secrets: the login Keychain.
- The search index: one SQLite file per backup location, `index/` beside
  `config.json`. It holds the path of every file in every backup, unencrypted,
  and is rebuilt from the location on request.
- Each run's log: `Logs/` beside `config.json`, deleted with its run record.
  It holds the restic command lines and restic's messages, never a password
  or a hook's output.

## Good to know

- Scheduled backups need the app running. There is no daemon: saving the
  first scheduled plan turns on *Start at login*, once the app is in
  `/Applications`, since a login item registered from a build folder goes
  stale. Settings can turn it off again.
- The app is not sandboxed. restic has to read any folder and reach the
  network, and a sandboxed app confines its children.
- A new scheduled plan backs up within a minute of being saved. Pick
  *Manually* if that is not wanted.
- SFTP from a GUI app has no `SSH_AUTH_SOCK` and no terminal: use a key
  without a passphrase, or an `~/.ssh/config` entry with an `IdentityFile`,
  and connect once with `ssh` first so the host key is known.
- Hooks run through `/bin/sh -c` with the app's privileges and are told
  about the run through `SWIFTRESTIC_*` environment variables. Only the
  first line of a failing hook's output is kept, and it never leaves this
  Mac.
- The UI is English only.

## For agents

The conventions for working here are in `CLAUDE.md`. The source tree under
`Sources/SwiftRestic/` is the only description of how the app works; read it
with the tools, not through prose.
