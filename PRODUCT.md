# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

Native macOS app (SwiftUI, Swift 6, SwiftPM). The skill's platform list has no `macos` value; Apple-native guidance comes from its iOS reference plus the macOS Human Interface Guidelines.

## Users

Everyone who runs out of space on a Mac, with developers as the core audience. The typical moment: the disk is nearly full, something failed to install or build, and the person wants to know where the space went and get it back without breaking anything. Developers bring extra weight: `node_modules`, build output, toolchains, simulators, Docker and VM images, package-manager caches.

## Product Purpose

Ballast maps the whole disk once, keeps that map current, and turns what it finds into a short, safe list to clean. Success: the user sees where space went within seconds of opening the app, cleans a meaningful amount with confidence, and nothing they rely on breaks afterwards.

## Positioning

Two halves carry equal weight:

- **See everything, instantly.** A full-disk index (every folder, not a sample) that updates incrementally from the macOS FSEvents change log, so reopening the app costs seconds, not a rescan.
- **Never breaks anything.** Every item on the Cleanup List carries a safety verdict with a plain reason: safe, quit the app first, check first, or protected. The check runs again at the moment of deletion. Caches of running apps are left alone, installed apps' data is protected, and the default is Move to Trash.

## Operating Context

- Opened when space runs low, or regularly to see how the disk is trending; the index makes reopening cheap.
- Flow: Overview (where the space is) → Explorer (drill into folders via treemap and list) or Suggestions (known caches, build output, stale folders) → add to the Cleanup List → Clean Up → see space freed.
- Items enter the list from ⊕ buttons, drag and drop from Finder, or a file picker.
- Some folders need Full Disk Access (privacy-protected) or an administrator scan (Unix-permission-protected); the app explains which and why.

## Capabilities and Constraints

- Full scan of `/System/Volumes/Data` (about 105–140 s for ~620k folders and ~4M files); incremental updates through FSEvents (seconds); SQLite index at `~/Library/Application Support/Ballast/`.
- Screens: Overview (stat tiles, usage donut, home-folder bars, hotspots, free-space history, cleanup summary), Explorer (squarified treemap, Size/Age color modes, breadcrumb, list), Suggestions (catalog, build artifacts, untouched 6+ months), Cleanup List (right-hand inspector).
- Safety engine (`SafetyCheck`) with four levels; the Cleaner re-checks each item at deletion time.
- Admin scan runs the same binary as root through `osascript`, only for folders that failed with Unix permission errors (EACCES).
- All current features must survive any redesign.
- UI is SwiftUI only, using the current macOS design language (Liquid Glass). No web technology.
- Signed with the owner's Apple Development identity so the Full Disk Access grant survives rebuilds.
- Open decision: `Catalog.isProjectArtifact` only matches `node_modules` today (owner's TODO).

## Brand Commitments

- Name: **Ballast**, fixed. The metaphor is the dead weight a ship carries and drops to rise.
- Needs an app icon (none exists yet).
- To be open-sourced and published on GitHub.

## Evidence on Hand

- The working app itself and its real measurements on the owner's Mac.
- No users, testimonials, benchmarks against competitors, or press yet. Do not fabricate any.

## Product Principles

1. **Safety is visible, not implied.** Every destructive action shows why it's safe before it happens.
2. **Truth over comfort.** Numbers are measured, never estimated; gaps (locked folders, snapshots) are named, not hidden.
3. **Understand, then act.** Seeing the disk and cleaning it are one continuous flow, not separate modes.
4. **Native first.** It should feel like it shipped with macOS: standard controls, keyboard shortcuts, system materials.
5. **Developer-literate, human-readable.** Paths and commands are available for those who want them, with plain-language reasons for everyone else.

## Accessibility & Inclusion

- Must respect Reduce Motion: every animation has a calm fallback.
- Follow macOS standards for VoiceOver labels, keyboard navigation, Dynamic Type where available, and Increase Contrast / Reduce Transparency with Liquid Glass.
