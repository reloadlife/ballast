# How Ballast works

```
first launch  ─▶  fts walk of /System/Volumes/Data  ─▶  SQLite index of every folder
                  (one pass, like du -x)                  (sizes include everything below)

every launch  ─▶  replay FSEvents since last time   ─▶  recheck only changed folders
                  (the log macOS keeps anyway)            and adjust their parents' totals
```

- It walks `/System/Volumes/Data`, not `/`, so firmlinked folders like `/Users` and `/Applications` count once.
- It stores folders, with files folded into their parent's size, plus one row for each file of 50 MB or more (name, allocated and logical size, modification time, inode), kept current by the same updates. A 500 GB disk makes an index of about 450k folder rows and 500 file rows; listing the files adds nothing measurable to a full scan (77–79 s, against 77 s without) and about 70 KB to a 36 MB index.
- An index from before large files were listed keeps working: the next update adds the (empty) table, and the Overview says "Largest files appear after the next full scan" until a full scan has filled it, rather than showing only the folders that changed since.
- Hard links are counted once, and sizes are what's actually allocated on disk (what `du` reports), not logical file sizes.
- If the change log can't be trusted (events dropped, IDs wrapped, too many changes), Ballast falls back to a full scan instead of guessing.
- Other drives get their own index, `volumes/<volume UUID>/index.sqlite`, next to the startup disk's (which stays at `index.sqlite`, where the command line and widget read it). They're walked from their mount point and never scanned on their own. An APFS or Mac OS Extended drive keeps its FSEvents history on the drive itself, so Update replays it with a device-relative stream, as long as the history's ID still matches the one saved with the index; ExFAT and FAT drives get a new history on every mount, so they're rescanned. A drive that comes back under another name ("Drive 1") keeps its index. Ejecting a drive mid-scan stops the scan so the eject goes through, and a scan whose drive vanished is thrown away before it's saved: the last complete index stays.

## Permissions

- **Full Disk Access** (recommended): macOS hides Photos, Mail, iOS backups and some app data from every app, root included. Grant it in System Settings › Privacy & Security › Full Disk Access, then reopen Ballast.
- **Administrator** (optional): a handful of system folders such as `/private/var` need an admin to measure. Ballast asks for your password once and reads only those folders.

To keep the Full Disk Access grant across rebuilds, sign with your own identity: put `SIGN_ID=<your identity>` in `scripts/signing.local`. That file is gitignored.

## Updates

Ballast updates itself with [Sparkle](https://sparkle-project.org). The second time you open it, it asks whether to check for updates automatically (once a day, from this repository's latest release); until you say yes, it only checks when you choose **Check for Updates…** in the Ballast menu, the menu bar item or Settings › About. Settings › General › Updates changes this later, and can also have updates download and install on their own. Every update is checked against the signing key built into the app before it's installed. Builds without a key (`swift run`, or a checkout with no `Resources/sparkle-public-key.txt`) never check, and Settings says so.

## Command line

The app binary doubles as a CLI, handy for cron jobs or CI boxes:

```sh
Ballast.app/Contents/MacOS/Ballast --index full           # rebuild the index
Ballast.app/Contents/MacOS/Ballast --index update         # replay changes since last run
Ballast.app/Contents/MacOS/Ballast --auto-clean --dry-run # what your rules would clean now
Ballast.app/Contents/MacOS/Ballast --check-space          # low-space alert check (no scan)
```

`--index` needs Full Disk Access for whatever runs it: started from a terminal, macOS checks the terminal's access, not Ballast's, and protected folders would be indexed as empty. Without it, the command refuses to run. While the app is open it replays the change log on its own: every 30 minutes, or sooner when free space moves by a gigabyte.

Auto-clean rules live in `~/Library/Application Support/Ballast/autoclean.json`; daily folder sizes for "what grew" in `growth.sqlite` (`--index` runs add today's too); the last 20 cleanups, with where their items went in the Trash, in `trash-log.json`; excluded and protected folders, and the other Settings the command line also needs, in `settings.json` next to it; and, only if you share usage data, your answer and identifier in `telemetry.json` and unsent events in `telemetry-queue.json`. The background runs are LaunchAgents that Ballast installs and removes to match Settings: `dev.mamad.Ballast.autoclean` daily while background auto-clean is on, and `dev.mamad.Ballast.spacecheck` hourly while the low-space alert is on. They log to `~/Library/Logs/Ballast/`. Every run, and the app, keeps a summary of the Overview's figures in `status.json` and asks the widget to redraw from it.

## Project layout

```
Sources/Ballast/
├── Engine/        Walker (fts), IndexDB (SQLite), ScanEngine (full + incremental),
│                  ChangeLog (FSEvents), Safety, Cleaner, AdminScan, History,
│                  ArtifactKind (build folders), AutoClean, SystemData,
│                  LowSpace, StatusSnapshot+Index (writes status.json),
│                  Apps (unused apps and their data), Installers,
│                  TrashLog (cleanup log and Put Back),
│                  Growth (daily folder sizes and "what grew"),
│                  LargeFiles (files of 50 MB or more, by kind),
│                  Duplicates (content hashing, APFS clone detection),
│                  Volumes (other drives: listing, per-drive indexes,
│                  drive facts for the safety rules)
├── Intents/       Shortcuts, Siri and Spotlight actions (App Intents) and
│                  what they say
├── Views/         Overview, Explorer, Suggestions, Cleanup List, Cleanup
│                  History, treemap, menu bar item, Settings
├── Catalog.swift  Known caches and tools, and what counts as build output
├── Updates.swift  In-app updates (Sparkle), and whether this build can have them
├── Telemetry.swift Opt-in usage data: every event and property, the queue,
│                  and sending to PostHog
└── AppModel.swift State, caching, and the scan/clean flows
Sources/BallastCore  What the app and the widget share: StatusSnapshot
                     (status.json), free space, category colors
Sources/BallastWidget The WidgetKit extension, bundled as
                     Ballast.app/Contents/PlugIns/BallastWidget.appex
Sources/WidgetRender Development only: draws the widget to PNGs
                     (`swift run WidgetRender <folder>`), never bundled
Tests/BallastTests   Safety rules, treemap layout, walker, cleaner,
                     large files and duplicates (clones, hard links),
                     growth ranking, search escaping, CSV export,
                     Shortcuts action wording, drive listing and
                     per-drive indexes
```
