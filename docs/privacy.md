# Privacy

Ballast works entirely on your Mac. The index, the growth history and the cleanup log stay in `~/Library/Application Support/Ballast`; nothing about your files leaves it.

**Usage data is opt-in and off by default.** After a scan, the Overview asks once whether to share anonymous usage data; **No Thanks** is final, and Settings › Privacy changes it any time. Until you say yes, nothing is recorded, queued or sent, and no identifier exists. What it sends, all defined in [`Telemetry.swift`](../Sources/Ballast/Telemetry.swift):

| Event | When | Properties |
|---|---|---|
| `app_opened` | Ballast opens | whether the menu bar item is on |
| `scan_completed` | A startup-disk scan finishes | full or incremental, duration range, folder-count range, whether an update fell back to a full scan |
| `cleanup_completed` | A cleanup finishes | item-count range, size range, Trash or delete, Cleanup List / auto-clean / Shortcuts |
| `put_back_used` | Put Back restores a cleanup | none |
| `suggestion_section_viewed` | A Suggestions section scrolls into view (once per section per run) | section name from a fixed list |
| `widget_installed` | A widget size appears on the desktop (once per size) | small, medium or large |
| `settings_changed` | A setting changes | which setting, and the new value only for switches and fixed choices (never folder lists or rules) |
| `feature_used` | Once per run: search, export, Find Duplicates, scanning another disk, What grew, Quick Look | which feature |

Every event also carries a random identifier made when you opted in, Ballast's version and build, the macOS version (major.minor), Apple silicon or Intel, your language code ("en"), whether Full Disk Access is on, and the startup disk's size rounded to a common size ("512 GB"). Sizes, durations and counts are ranges ("1-10 GB", "10K-100K"). Paths, file, folder and app names, bundle identifiers, user and computer names, serial numbers and exact byte counts are never sent: every value is from a fixed list, a boolean or a version number, and anything else is dropped before it's queued.

Events wait in `telemetry-queue.json` (at most 500, dropped after three days) and go to [PostHog](https://posthog.com) over HTTPS about every half hour and at quit. Each asks PostHog not to create a person profile (`$process_person_profile: false`) and not to look up a location (`$geoip_disable: true`), and Ballast doesn't send an IP address, but PostHog sees the address a request comes from, as any server does. Settings › Privacy lists every event and property (generated from the same definitions), shows the queued events exactly as they'll be sent, and resets the identifier. Turning sharing off deletes the identifier and the queue. The daily auto-clean run only adds to the queue; it never goes online itself. Builds without a PostHog key, including `swift run` and forks, can't send at all and never ask.
