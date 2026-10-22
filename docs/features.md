# Ballast features

Everything Ballast does, in detail. For the short version, see the [README](../README.md).

## Finding space

- **Whole-disk index.** Every folder on the data volume gets measured, not sampled. On a 500 GB Mac with about 4 million files, the first scan takes around two minutes.
- **Instant updates.** Ballast replays the FSEvents log macOS already keeps and rechecks only the folders that changed, so reopening it takes seconds.
- **Explorer.** A treemap plus a sortable table. Drill into any folder and see its size, share and last change at a glance; the file button adds the folder's files of 50 MB or more to the table and the map. **Search** (⌘F) finds folders by name anywhere on the disk, biggest first, in about 40 ms. Space opens Quick Look, ⌥⌘R shows the selected folder in Finder, and the context menu copies a path or rows as CSV.
- **Largest files.** The Overview lists the ten largest files on the disk, with **Show All** for every file of 50 MB or more (about 500 files on a 500 GB Mac), filtered by kind: videos, disk images and archives, VMs and containers, and everything else. Each row has the file's icon, where it is, when it last changed, Quick Look, Show in Finder and ⊕. Files keep the safety rules of where they are: inside the Photos library, Mail, an app's container or `.git` they stay protected, and a VM's disk waits while UTM, Parallels, VMware Fusion, VirtualBox, Docker or OrbStack is open. Files in folders Ballast couldn't read can't be listed, and the list says how many folders that is.
- **Duplicate files.** **Find Duplicates** in Suggestions compares the large files on the startup disk, only when asked, and can be stopped: files of the same size are compared by their first and last 64 KB, and only those still matching are read in full (SHA-256). Hard links aren't copies, and APFS clones already share their storage, so a set of clones is named ("already share storage") but never suggested, and a clone's copy counts only the blocks it doesn't share. Each set keeps one copy (the oldest outside Downloads, the Desktop and the Trash, or the one you pick), and **Add Others** puts the rest on the Cleanup List with what removing each actually frees. Nothing is removed on its own, and copies in protected places aren't compared.
- **What grew.** "My disk was fine yesterday": the Overview lists the folders that grew since you last opened Ballast, or over the last 24 hours, 7 days or 30 days, with what shrinking folders freed. Each row is the deepest folder that explains the growth, and no byte is counted twice: a parent is listed only for what its listed subfolders don't explain ("~/Library · not counting go-build"). Ballast notes the size of every folder over 20 MB once a day (about 5,000 folders, a few MB for 90 days) in `growth.sqlite`, which a full rescan doesn't touch. It only offers periods it has history for, and the card says the exact date it compares with.
- **What is "System Data"?** One click breaks it down: macOS itself, boot and update files, swap, Recovery, snapshots, downloaded macOS assets, system caches and logs, Homebrew, and anything Ballast couldn't measure. Each part comes with a plain explanation and what, if anything, you can do about it. Time Machine's local snapshots are listed with their dates, and **Delete Local Snapshots…** asks macOS to thin them (backups on your backup disk aren't touched) and shows how much space came back.
- **Honest numbers.** What Ballast can't see (locked folders, file-system overhead) is named, not hidden, and every screen shows the same figures.
- **Other drives.** External drives, other APFS volumes and disk images you mount show up under **Disks** in the sidebar, with their format, capacity and free space. Ballast scans one only when you ask, keeps a separate index for each (so an unplugged drive stays listed: "Not connected · scanned 3 days ago", with **Forget**), and shows it in Overview and Explorer: build folders, other folders, and space no folder holds, measured the way `du` counts it. APFS and Mac OS Extended drives are updated from their own change log, even after being unplugged; ExFAT and FAT drives start a new log every time they're plugged in, so Ballast rescans them and says so. Build folders on connected drives appear in Suggestions, and cleaning there goes to that drive's own Trash, with Put Back. Read-only drives (NTFS, for one) can be explored but never cleaned; network drives aren't supported yet, and Time Machine backup disks aren't listed at all. The menu bar item, widget and Shortcuts stay about the startup disk.
- **Export.** File › Export… (⇧⌘E) saves the open folder's list in Explorer, or the largest folders on the Overview, as CSV or JSON: path, name, bytes, size, share, last change, and whether the folder was locked.

## Suggestions

- **Suggestions.** Tool caches (npm, Bun, pnpm, Yarn, pip, CocoaPods, Composer, Deno, Go, Cargo, Gradle, uv…), logs, Xcode DerivedData, device support files and previews, project build output, Trash, and stale folders, sorted by size. Things you'd miss get **Check first**: Xcode archives, the Maven repository, Hugging Face and Ollama models, Android emulators and system images, and `docker system prune` (it keeps volumes, but not what's inside stopped containers).
- **Build folders by type.** `node_modules`, `.next`, Rust and Maven `target`, Gradle `build`, SwiftPM `.build`, .NET `bin`/`obj`, Elixir `_build`/`deps`, Haskell `.stack-work`, Python venvs, `.tox`, `__pycache__` and pytest/mypy/Ruff caches, `Pods`, `Carthage/Build`, `.turbo`, `.nx`, `.svelte-kit`, `.astro`, `.expo`, `.vercel/output`, `.wrangler/tmp`, Nuxt/Nitro `.output`, coverage reports, `.terraform`, and JavaScript `dist`/`build`/`out`, `storybook-static` and Composer `vendor` when the repository's `.gitignore` ignores them, and more, grouped with totals. Each one is confirmed by the file that proves it (`target/` only counts next to a `Cargo.toml`, `coverage/` only next to a `package.json` and with a report inside), never by name alone.
- **Temporary developer files.** Suggestions include individual Go build directories, Bun temporary packages, Node/Clang caches, and deployment working copies in the current user's `/private/var/folders` area, plus any other item there of 500 MB or more and your own folders of that size in `/tmp`. These require review and stopping related work first; other accounts' and system services' files in `/tmp` stay protected. App runtime clones are explained but remain protected, as do system databases and swap.
- **Git worktrees.** Find repositories in the disk index or choose a repository anywhere, including outside home. Use **Clean Build Files…** to review recognized ignored build folders in the Cleanup List, including in the main worktree. Use **Remove Worktree…** to remove clean linked worktrees through Git while retaining branches and commits. Changed, untracked, ignored, locked and unreferenced detached work are protected and checked again at removal. Suggestions also list the worktree folders coding agents fill (`~/.codex/worktrees`, `~/.t3/worktrees`, a repository's `.claude/worktrees` and similar) for review.
- **Unused apps.** Apps you haven't opened in six months (the same setting as stale folders), by last-opened date from Spotlight, with what uninstalling frees: "App 420 MB + data 1.2 GB". The data is found by exact identity only: the app's bundle id or name in `~/Library` (Containers, Application Support, Caches, Preferences, Saved Application State, HTTPStorages, WebKit), plus group containers whose own metadata names a group only that app declares. Uninstalling moves the app and that data to the Trash, always, even with Delete Now chosen. Apple's own apps, aliases into the system volume and Ballast itself are never listed; apps with no Spotlight record say so instead of guessing a date.
- **Installers and disk images.** `.dmg`, `.pkg`, `.mpkg` and `.xip` files of 10 MB or more in Downloads, Desktop and Documents (and their direct subfolders), plus `.zip` files with an app at the top. Each shows when it was added and, when the file is named after an app you have, that the app is installed. A mounted disk image gets an **Eject** button and is cleaned only once it's ejected.
- **Review controls.** Filter suggestions by category, see safety reasons beside them, and open Explorer directly. Explorer has a map toggle and a selected-item review area with visible cleanup actions.

## Cleaning

- **Cleanup List.** Collect items from anywhere: the ⊕ buttons, drag and drop from Finder, or a file picker. Review them, then clean in one go.
- **Move to Trash by default.** Deleting permanently is a separate, clearly marked choice. Tools with their own cleanup command (`npm cache clean`, `go clean -modcache`, `brew cleanup`, `pod cache clean`) run that command instead of deleting files. A cache listed on its own, like pip's inside `~/Library/Caches`, is left alone when its parent folder is emptied, so nothing is counted twice.
- **Put Back.** Every cleanup, auto-clean runs included, is logged with where each item went in the Trash. **Put Back** (on the result, in **Cleanup History**, or Edit › Put Back Last Cleanup) moves them back, and never over something new: "A new node_modules exists there now, so it was left in the Trash." Deleting permanently and tool commands can't be undone, and the Cleanup List says so where you choose.
- **Auto-clean rules.** For example: "delete `.next` folders once their project hasn't changed for 3 days". Rules run daily in the background, even with the app closed, and notify you when they clean something. Each rule chooses Trash or Delete; every rule starts off.

## Safety verdicts

Before anything is deleted, Ballast gives it one of four verdicts:

| | Verdict | Examples | What happens |
|---|---|---|---|
| ✅ | **Safe** | App caches, `node_modules`, DerivedData, downloaded installers, your own files | Cleaned |
| ⏸ | **Quit the app first** | Chrome's cache while Chrome is open; uninstalling an app that's open | Waits, with a **Quit** button; turns safe once the app closes |
| ⚠️ | **Check first** | Git repositories, tool folders like `~/.bun/bin`, apps; uninstalling an app with its data, or one that installs system components ("use its own uninstaller if it has one") | Only cleaned if you tick **I’ve reviewed this item** |
| ⛔ | **Protected** | An installed app's data (browser profiles, logins), Keychains, Preferences, Mail, the Photos library, `.ssh`, `.git`, your top-level folders; apps only an administrator, or macOS App Management, lets Ballast remove | Can't be added; the reason is shown |

An app's data stays protected on its own; it can only go together with its app, as one uninstall that's checked again when it runs (same app, still closed, same data). Ballast never asks for admin rights to delete: a root-owned app is skipped with the reason, not escalated. When Ballast empties `~/Library/Caches`, it **skips the caches of apps that are running** instead of pulling files out from under them. Folders whose owner it can't identify stay protected: a guess isn't good enough when the cost is someone's data. The rules live in [`Safety.swift`](../Sources/Ballast/Engine/Safety.swift) and are covered by tests.

## Developer tools

- **Homebrew packages.** Browse installed formulae and casks, filter available updates, check for updates, update individual packages and uninstall through `brew`. Pinned formulae stay pinned; package changes require confirmation and do not use the Trash.
- **Homebrew sorting.** Compact package rows can be sorted by name, indexed size, or last recorded app use. Command-line usage is not tracked; unknown dates sort last. Sizes cover Cellar/Caskroom files and linked apps, excluding shared dependencies, caches, and other installer payloads.

## Around the Mac

- **Menu bar item.** Free space, the storage bar and what's safe to clean, one click away, with Refresh and Review Cleanup. With it on, closing the window keeps Ballast running there instead of in the Dock.
- **Desktop widget.** Free space, what fills the disk and what's safe to clean, in small, medium and large sizes. The free-space figure is read fresh every time the widget updates; the breakdown comes from Ballast's last scan and says how old it is. Click it to open the Overview, or "safe to clean" to open Suggestions.
- **Shortcuts, Siri and Spotlight.** Six actions: Get Free Space, Get Disk Status, Update Disk Index, Run Auto-Clean (a preview unless you turn Preview Only off), Put Back Last Cleanup and Open Ballast. See [Shortcuts](#shortcuts).
- **Low-space alert.** A notification when free space drops below a threshold you pick (20 GB by default), checked hourly even with the app closed: "Only 12 GB left on Macintosh HD. 8.4 GB is safe to clean."
- **Native.** SwiftUI on macOS 26, with system materials, SF Symbols, keyboard shortcuts, Dark Mode and Reduce Motion. App update checks and anonymous usage data are off until you allow them. Homebrew checks and package updates contact Homebrew when you request them (see [Privacy](privacy.md)).

### Adding the widget

Open Ballast once so it can measure the disk, then right-click the desktop, choose **Edit Widgets…**, search for **Ballast**, and drag the size you want onto the desktop (or into Notification Center). The widget reads the figures Ballast saves in `~/Library/Application Support/Ballast/status.json` and nothing else; it's sandboxed, with read-only access to that one folder.

### Shortcuts

Ballast's actions show up in the Shortcuts app (search for **Ballast** in the action list), in Spotlight, and to Siri, with no setup. Nothing is added to your shortcuts library; build your own with them, or just say the phrase.

| Action | What it does | Say or type |
|---|---|---|
| **Get Free Space** | Returns free space as a size, and says "86 GB free of 494 GB". The same figure as the Overview and Finder. | "How much space is free in Ballast" |
| **Get Disk Status** | Returns free space, capacity, what's safe to clean and when Ballast last scanned, for use one by one. Free space is read fresh; the rest is from the last scan. | "Ballast disk status" |
| **Update Disk Index** | Brings the index up to date from the macOS change log, or rescans the whole disk when it has to, and reports progress. | "Update Ballast index" |
| **Run Auto-Clean** | Runs your auto-clean rules now. **Preview Only** is on by default: it lists what the rules would clean and removes nothing. Turned off, it asks first, and says so when your rules delete permanently. With no rule on, it says so. | "Preview Ballast auto-clean" |
| **Put Back Last Cleanup** | Asks first, then moves the newest cleanup that still has items in the Trash back where they were, never over something new, and names anything it left in the Trash. | "Undo the last Ballast cleanup" |
| **Open Ballast** | Opens the window on Overview, Explorer or Suggestions. | "Open Suggestions in Ballast" |

The actions run inside Ballast, which macOS starts if it isn't running. They clean nothing your auto-clean rules or the Cleanup List wouldn't, with the same checks. If you keep more than one copy of Ballast (say, a build in the project folder and one in Applications), macOS reads the actions from only one of them, so keep the copy you use up to date.

## Health (v0.6.0)

- **Storage health.** Read-only SMART status for physical drives, SSD endurance used, available spare capacity and cumulative media errors where macOS exposes them. Missing metrics remain unavailable. Startup disk capacity is flagged below 10% free. SMART is not a guarantee against failure; Ballast opens Disk Utility for manual filesystem checks instead of running repairs or self-tests.
- **Mac security.** Local checks for FileVault, System Integrity Protection, Gatekeeper and the application firewall. Unrecognized, transitional, denied or failed checks are unavailable rather than passed. Links open Privacy & Security and Software Update; Ballast does not change settings or claim to check update availability itself.
- **Known package vulnerabilities.** Review installed Homebrew core formula versions from local receipts in `/opt/homebrew` and `/usr/local`, then explicitly send those names and versions to OSV. All installed revisions are included. Matches link to advisories for affected-version and remediation details. Casks, app bundles, custom prefixes, third-party taps, HEAD builds and other package managers are outside this version's coverage. No known match is not a security guarantee. No automatic updates or uninstalls.
- **On demand.** Health is available before a disk scan, in the sidebar, Shortcuts and `ballast://health`. Results remain in memory with their check time; no background polling or diagnostic telemetry.
