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

Revised 2026-11-05 at the owner's request ("bad UI and UX, be creative, Liquid Glass with a touch of magic, animations"); replaces the 2026-09-25 native-minimal contract. Owner pinned: native structure stays, Liquid Glass moves into content, a few authored moments, fast, no idle loops (the radar was rejected as laggy).

THESIS: Your disk read like a sea chart: depth bands show where the weight sits, open water is free space, and the tools float above it on Liquid Glass.

OWN-WORLD: Chart Under Glass. Day chart (light): open-water ground, depth-banded blues for data (heavier = deeper), buff land for what can't move (System), chart magenta only for hazards the user can act on. Night chart (dark): navy ground, depth bands brighten with weight. Tokens live in `Sources/Ballast/Views/Design/Theme.swift (enum `Theme`; Swift Charts owns the name `Chart`)`. Stock macOS 26 chrome (sidebar, toolbar, inspector) keeps system glass; content tools (callouts, dock, filters, headers) are Liquid Glass capsules and panels over the chart.

STORY: See how deep the disk is loaded, see what can be dropped safely, gather it in the dock, drop the ballast, watch open water return.

FIRST VIEWPORT: Overview: volume name and used/total at left; free space as the one hero sounding at right (italic, tabular); the storage bar drawn as depth bands with System as land and free space as open water; a glass "can be cleaned safely" panel with Review; floating at the bottom of the detail column, the Ballast dock (glass capsules that merge and grow with the Cleanup List).

SIGNATURE MOVE: Drop ballast. Adding items fills the dock capsule (numeric count, morphing glass); Clean Up drains the reclaimed band out of the storage bar into open water, the hero figure counts up to the new free space, and one light sweep crosses the glass once. Everything else is quiet feedback.

MOTION GRAMMAR: feedback 120-180 ms (.snappy), state 220-300 ms (.smooth), layout and pane changes 300-400 ms (spring, low bounce, blur-crossfade on pane switch), the one authored drop moment up to 800 ms. Exits faster than entrances. All motion through `Motion`, off under Reduce Motion (crossfade only). No idle loops; loading shimmer runs only while data is actually loading.

FORM: native Storage-settings grammar kept for layout and controls; seed:96732ca9b9803f81 (direction round, assigned candidate). Status in the toolbar subtitle.

RAISES (from declined challengers):
- Emission-Line Rail: safety verdicts differ by symbol shape and line form, never hue alone, so they survive Increase Contrast and Reduce Transparency.
- Timetable Slide Rack: one opaque plate per screen; only the primary action leaves the glass (ink plate).
- Metro Tiles: one figure owns each screen.
- Guide-Map Lobes: space and edges divide content; no borders, no card-in-card.
- Centre-Rail Edition: hairlines at one device pixel, drawn once.
- Mixtape J-Card: every byte figure right-aligned to one tabular column edge per list.

AMENDMENTS (finish review, 2026-11-05):
- Storage bar bands are categorical: each category keeps one band (Applications deepest, then your files, caches, build files, other), so a category stays the same blue between scans and through the drop, when sizes change mid-animation. "Heavier = deeper" holds for share bars and the treemap, which step through the bands by weight.
- One ink plate per window, not only per screen: while the Cleanup List inspector holds a ready Clean Up, the detail column's plate steps down to a shoal capsule (`\.inkYields`).
- Selection controls (segmented pickers, toggle buttons) take `Theme.control`, never the system accent; set per control, since a scene-wide tint fills every glass and bordered button. Links keep the system link color (macOS ignores the tint for `.link`). Sheets keep their own plate (`.ownsInkPlate()`).

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, and DESIGN.md rewritten from the shipped code.
