---
version: 1
slug: "sources-ballast-views-rootview-swift"
primary_target: "Sources/Ballast/Views/RootView.swift"
related_targets: ["Sources/Ballast/Views"]
---

# Ballast app window

Scope: the whole macOS window (Overview, Explorer, Suggestions, Cleanup List inspector, onboarding/welcome, scan states). Visitor mode: **Operate**.

Audience and job: people whose Mac is nearly full, developers first; see where space went, trust what is safe, clean it, see space come back.

Constraints: SwiftUI only, macOS 26+ Liquid Glass design language; all current features stay; Reduce Motion respected; name "Ballast" fixed; needs an app icon.

## Direction contract

Revised 2026-09-25 at the owner's request: the Disk Radar direction was rejected ("don't like the radar", "hard to understand", "laggy"); replaced with native minimal.

THESIS: A calm, native storage utility: plain words, one accent color, nothing animated that isn't feedback.

OWN-WORLD: Stock macOS 26 chrome (sidebar, toolbar, inspector get Liquid Glass from the system). Content on plain backgrounds; SF text styles; the accent color for data; category colors only in the storage bar.

STORY: See how full the disk is and what fills it, see what can go safely, add it to the list, clean, see space return.

FIRST VIEWPORT: Overview: volume name and used/total at left, available space as the largest number at right, segmented storage bar with legend, then one "can be cleaned safely" row with Review.

FORM: native Storage-settings grammar (formerly candidate 1, "Native Utility"); original seed 07b3a0c0. Status always in the toolbar subtitle, with a percentage during full scans.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Raises from declined challengers (radar era, superseded)

- Sneaker Box Wall: one strict label grid rules every item.
- Cloud Quarry: lift is the verb; tiles and rows drag onto the Cleanup List.
- ASCII Render: a single ramp is the whole data palette.
- Seedbed Lobes: controls detach from edges as floating glass capsules.
- Acetate Manual: the breadcrumb becomes an extent rail proportional to size.
