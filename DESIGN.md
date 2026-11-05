---
name: Ballast
description: Your disk read like a sea chart, with the tools floating above it on Liquid Glass.
colors:
  water: "#F7FAFB"
  shoal: "#EDF4F7"
  land: "#E9DDBB"
  contour: "rgba(46, 111, 147, 0.18)"
  depth-0: "#D3E7F0"
  depth-1: "#A2CBDD"
  depth-2: "#5F9EC0"
  depth-3: "#2A6890"
  depth-4: "#123049"
  control: "#2A6890"
  on-ink: "#F7FAFB"
  hazard: "#A8126A"
  verdict-safe: "#1F7A57"
  verdict-caution: "#9A5B00"
  verdict-blocked: "#5B6B78"
typography:
  hero:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "44px"
    fontWeight: 600
    fontFeature: "tnum"
  title:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "15px"
    fontWeight: 600
  headline:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "13px"
    fontWeight: 600
  body:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "13px"
    fontWeight: 400
  sounding:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "13px"
    fontWeight: 400
    fontFeature: "tnum"
  sounding-small:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "12px"
    fontWeight: 400
    fontFeature: "tnum"
  callout:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "12px"
    fontWeight: 400
rounded:
  bar: "7px"
  tile: "8px"
  row: "12px"
  card: "18px"
  panel: "24px"
spacing:
  row-y: "9px"
  gap: "12px"
  inset: "16px"
  section: "32px"
  page-x: "36px"
components:
  button-ink:
    backgroundColor: "{colors.depth-4}"
    textColor: "{colors.on-ink}"
    typography: "{typography.headline}"
    padding: "7px 16px"
  button-ink-large:
    backgroundColor: "{colors.depth-4}"
    textColor: "{colors.on-ink}"
    typography: "{typography.title}"
    padding: "11px 22px"
  button-ink-yielding:
    backgroundColor: "{colors.depth-0}"
    padding: "7px 16px"
  chart-surface:
    backgroundColor: "{colors.shoal}"
    rounded: "{rounded.card}"
    padding: "{spacing.inset}"
  chart-glass:
    rounded: "{rounded.panel}"
    padding: "{spacing.inset}"
  dock-capsule:
    padding: "8px 14px"
  chip:
    padding: "5px 11px"
  share-bar:
    backgroundColor: "{colors.depth-0}"
    height: "5px"
  storage-bar:
    backgroundColor: "{colors.water}"
    rounded: "{rounded.bar}"
    height: "18px"
---

# Design System: Ballast

## Overview

**Creative North Star: "Chart Under Glass"**

Ballast reads the disk like a nautical chart. Free space is open water, the plain ground of every screen. The weight on the disk is drawn in five depth bands of blue: the more something weighs, the deeper its blue. What can't be moved (System Data) is buff land. Chart magenta marks only hazards the user can act on. Content tools (callouts, the dock, filter chips, the "can be cleaned safely" panel) float above the chart on Liquid Glass, while stock macOS 26 chrome (sidebar, toolbar, inspector) keeps its system glass.

The app is a native macOS SwiftUI utility built on the Storage-settings grammar: native split view, plain words, dense lists of rows. One authored moment, "drop ballast", carries the story: a cleaned item drains out of its band in the storage bar, free space counts up, and one light sweep crosses the glass. Everything else is quiet feedback. Nothing loops at idle.

Every color is defined once in `Theme` (Sources/Ballast/Views/Design/Theme.swift) for the day chart (light), the night chart (dark), and both under Increase Contrast. The frontmatter records the day chart; night and high-contrast values are in the sidecar.

**Key Characteristics:**
- Open-water ground, depth-banded blue data, buff land, magenta for actionable hazards only.
- Liquid Glass only for floating content tools; shoal surfaces for grouped rows.
- One opaque ink plate per window.
- Byte figures set as italic tabular soundings on one column edge.
- No shadows, no borders around groups, no card-in-card.
- Springs throughout, exits faster than entrances, everything off under Reduce Motion.

## Colors

A cool chart of blues on near-white water, with buff land and one magenta used rarely.

### Primary
- **Depth Bands** (`depth-0` to `depth-4`): all data and emphasis step through these five bands and nothing else. In the night chart the bands invert (`#1F3D52` to `#BFE3F4`), so the deepest band is the brightest and heavier still reads as stronger. `Theme.depth(fraction)` picks a band for a 0 to 1 value.
- **Sea** (`depth-3`): data marks, selection outlines, share-bar fills, the dock's tray symbol and Review label, the quit-first verdict, empty-state symbols.
- **Ink** (`depth-4`): the one opaque plate (the primary action), with **On Ink** (`on-ink`) for its label.
- **Control Blue** (`control`): the fill of selected system controls (segmented selections, toggle buttons), whose labels are white. Same as band 3 by day (6:1); by night a deeper `#3A7FA8` (4.4:1); under Increase Contrast at night `#2F7AA6` (4.7:1), darker rather than brighter because macOS draws control borders then and the white label is what must read. Never text or symbols on the ground: links keep the system link color, which macOS draws whatever the tint.

### Secondary
- **Chart Magenta** (`hazard`): low free space (the hero figure, sidebar sounding and bar, menu bar, notification settings), items that need a decision (the dock's "needs you" capsule, waiting counts in the plan), and Health/Homebrew findings in the attention state.

### Tertiary
- **Verdict Green / Amber / Slate** (`verdict-safe`, `verdict-caution`, `verdict-blocked`): the second cue of a safety verdict, after its shape. Slate also strokes the Trash hatching.

### Neutral
- **Open Water** (`water`): the content background of every detail screen and the free-space band of the storage bar.
- **Shoal** (`shoal`): grouped surfaces sitting on the water (`chartSurface`).
- **Land** (`land`): the System Data band and its legend only. The Trash band is land at 75% opacity with slate hatching.
- **Contour** (`contour`): every hairline, drawn at one device pixel (1 / displayScale): the storage bar's outline, free-space swatches, contour rings, the background `ContourField`.

### Named Rules
**The Magenta Is Hazard Rule.** Chart magenta marks only something the user can act on: low space, an item that needs a decision, a finding that needs attention. Never decoration, never a safety verdict, never an error message (errors are secondary text).

**The Heavier Is Deeper Rule.** Share bars and treemap tiles step through the depth bands by weight (`0.25 + 0.75 × fraction`). The storage bar is categorical instead: each category keeps one band between scans and through the drop (Applications `depth-4`, Your files `depth-3`, Caches `depth-2`, Build files `depth-1`, Other `depth-0`, System Data land, In Trash hatched land, Available water).

## Typography

**Display Font:** SF Pro (system), italic with tabular digits for figures
**Body Font:** SF Pro (system), macOS text styles

**Character:** One family. Figures are the voice: byte counts are set like the soundings on a chart, italic and tabular, so columns line up and counting values don't jitter.

### Hierarchy
- **Hero** (600, italic, tabular; 44px default, 22 to 44 per screen): the one figure that owns a screen: free space on Overview, a folder's size in Explorer, reclaimable bytes in the Cleanup List and on the cleanable panel (22).
- **Title** (title3, 600): ink-large labels, empty-state titles. Welcome uses largeTitle 600.
- **Headline** (headline, 600): section titles in `ChartHeader`, panel messages, ink labels (body 600).
- **Body** (body, 400): row names and prose.
- **Sounding** (body, italic, tabular): every byte figure in a list; section totals use Sounding at 600.
- **Sounding Small** (callout, italic, tabular): scan progress bytes and percentages.
- **Callout** (callout, secondary): section notes (two lines max), popover text, detail lines. Paths use caption/caption2 in tertiary, middle-truncated.

### Named Rules
**The One Column Edge Rule.** Every byte figure is a `Sounding`, right-aligned to one tabular column edge per list (`ChartRow` fixes it at 84pt, trailing), and counts to new values with `Motion.figure`. Figures that update several times a second (live scan bytes) skip the count.

**The One Figure Rule.** Each screen has one hero figure; everything else is a sounding.

## Layout

Native `NavigationSplitView`: sidebar (200pt minimum, 220pt ideal), detail column on open water, the Cleanup List as the inspector. Detail content is capped at 820pt (`contentMax`) with 36pt page margins and 32pt between sections. Rows have 9pt vertical padding; 12pt is the standard gap and 16pt the inset inside surfaces and panels. The Ballast dock floats at the bottom of the detail column; RootView places it and a bottom inset keeps scrolling content clear of it.

Narrow windows reflow rather than squeeze: `ChartHeader`, the cleanable panel and the dock use `ViewThatFits`, so trailing controls drop below the title and the dock collapses to its count and Review. Screens set no minimum width on the detail column.

**The Space Divides Rule.** Space and headers divide content. Grouped rows sit on one shoal surface with no border, and a surface is never nested inside another.

## Elevation & Depth

There are no shadows anywhere in the build. Depth comes from three layers: open water at the bottom, shoal surfaces for grouped rows, and Liquid Glass for content tools floating above. Glass panels (`chartGlass`) are `.regular` glass tinted 6% toward sea; capsules (`chartCapsule`) are untinted regular glass, interactive when they are controls. Dock capsules merge inside a `GlassEffectContainer` (spacing 14) and morph by `glassEffectID`.

### Named Rules
**The No Glass On Glass Rule.** Glass is for floating content tools only, never on stock chrome (sidebar, toolbar, inspector) and never inside another glass shape. Secondary buttons inside a glass panel are `.bordered`.

**The Hairline Rule.** Contours and outlines are one device pixel (1 / displayScale), drawn once; groups get no borders.

## Shapes

Continuous (squircle) corners everywhere: the storage bar at 7px (or half its height), treemap tiles and swatches at 8px, rows and small surfaces at 12px, grouped surfaces and in-content callouts at 18px, floating glass panels at 24px. Buttons, chips, dock items, share bars and progress lines are capsules. The Trash band is marked by diagonal hatching (4pt spacing) rather than hue, so it reads in grayscale and Increase Contrast.

## Components

### Buttons
**The One Plate Per Window Rule.** Only the window's primary action leaves the glass as an opaque ink plate. While the Cleanup List inspector holds a ready Clean Up, every detail-column plate steps down to a shoal-blue capsule (`\.inkYields`). Sheets are their own context: their content calls `.ownsInkPlate()`, so a sheet's Done keeps its plate.

**The Control Tint Rule.** Selection controls (segmented pickers, toggle buttons) take `Theme.control`, set on each control, never the system accent and never a scene-wide tint. Links stay in the system link color.

- **Ink plate** (`.buttonStyle(.ink)` / `.inkLarge`): the window's primary action only. Capsule, `depth-4` fill, `on-ink` semibold label, 16×7 (large 22×11), 35% fill when disabled, presses to 0.97 scale.
- **Yielding plate:** while the Cleanup List inspector holds a ready Clean Up, RootView sets `\.inkYields` and every detail-column ink plate steps down to a `depth-0` capsule with primary text (animated with `Motion.state`).
- **Secondary:** `.bordered` (inside glass) or plain system buttons; links are `.link` in the system link color. Segmented pickers and toggle buttons take `.tint(Theme.control)` per control.
- **List toggle:** borderless `plus.circle` / `checkmark.circle.fill` in sea, symbol-replace transition; no control for protected items.

### Chips
- **Style:** glass capsules, 11×5, callout. Selected chips take glass tinted 28% sea, semibold label and the selected trait.

### Cards / Containers
- **ChartSection:** a `ChartHeader` (headline title, optional two-line callout note, trailing controls, the total as a semibold sounding) on the water, then the rows on one shoal surface (18px radius, 16px inset).
- **Glass panel** (`chartGlass`): floating callouts at 24px radius, 16 to 20px inset; in-list callouts at 18px.
- **Shadow Strategy:** none (see Elevation & Depth). **Border:** none.

### Navigation
Stock sidebar with system glass; screen status lives in the toolbar subtitle. Pane switches use the surface transition: blur 6 to 0, lift 8pt, fade in; removal fades out with `Motion.exit`.

### Ballast Dock (signature)
The Cleanup List gathered as merging glass capsules at the bottom of the detail column: count (tray symbol in sea, numeric transition), total bytes as a sounding, "needs you" in magenta when items need a decision, and Review (glass tinted 12% sea). Capsules grow out of the group as the list gains them and the dock collapses away when it empties. One button opens the inspector; pressing dips it to 0.98.

### DepthBar and the drop
The storage bar: 18pt tall, categorical bands with 1.5pt gaps (2pt minimum per present band), free space as water outlined by a contour hairline, Trash band last against the water. Each band has hover help; VoiceOver reads one summary. On a drop, a ghost piece the size of the moved bytes leaves its band and either settles into the Trash band (moved, not freed: no count-up, no sweep) or shrinks and blurs into open water (space freed: free space counts up and `lightSweep` crosses the cleanable panel once).

### SafetyMark
**The Shape First Rule.** A verdict is a shape before it is a color: safe is a checkmark circle, quit first a pause rectangle, caution a triangle, protected a lock. Color (green, sea, amber, slate) is the second cue and never magenta.

`WhatIsThisButton` opens a 320pt popover explaining a location: what it is, what happens when it's removed, how to clean it, its verdict (the row's own verdict wins), and any Full Disk Access need.

### Status and empty states
- **DepthProgress / SizeBar:** capsule lines on a `depth-0` track filled in sea (share bars by weight; magenta for low space). Indeterminate progress is the system linear bar tinted sea.
- **SkeletonRows:** `depth-0` placeholder rows with the loading shimmer, only while data loads.
- **EmptyChart:** symbol in sea inside three static contour rings, a title3 title, one teaching sentence (max 380pt), an optional action.
- **ContourField:** six static, seeded background contour hairlines on Overview and Welcome.

### Motion
All animation goes through `Motion`; `Motion.animation(_:)` and `Motion.with(_:_:)` return nothing under Reduce Motion. Springs throughout, so everything is interruptible.
- **feedback** (snappy, 160ms): presses, toggles, counts.
- **state** (smooth, 260ms): a value or status changing in place, the yielding plate.
- **layout** (spring 360ms, bounce 0.1): layout changes, dock glass merging, pane switches.
- **exit** (easeOut 140ms): anything leaving; always faster than it arrived.
- **figure** (smooth, 600ms): soundings counting, storage-bar bands outside a drop.
- **drop** (spring 750ms, bounce 0.16; keyframes 750ms): the one authored moment.
- **sweep** (keyframes 800ms): the light sweep, once per drop that freed space.
- **shimmer** (linear 1.3s, repeating): only while data is actually loading.

### Accessibility behaviour
- **Reduce Motion:** every `Motion` value is off. Pane switches keep a 180ms plain crossfade, the storage bar crossfades to its new state instead of draining (no ghost piece), the light sweep and the shimmer don't run (placeholders stay static), and symbol bounces are skipped.
- **Increase Contrast:** every token switches to its high-contrast value, contour alpha rises from 0.18 to 0.40, and `ContourField` is hidden.
- **Reduce Transparency:** handled by the system's own `glassEffect` fallback; the app adds no handling of its own. Shoal surfaces are opaque, and verdicts and the Trash band read by shape and hatching, not translucency.
- **VoiceOver:** the storage bar reads as one summary; SafetyMark reads its verdict title; the dock reads count, bytes, decisions and measuring.

## Do's and Don'ts

### Do:
- **Do** keep one ink plate per window: the primary action only, stepping down via `\.inkYields` while the Cleanup List holds a ready Clean Up.
- **Do** set `.tint(Theme.control)` on each segmented picker and toggle button, never the system accent; put `.ownsInkPlate()` on every sheet's content.
- **Do** set every byte figure as a `Sounding` on one trailing column edge per list.
- **Do** give every verdict its `SafetyMark` shape; color is only the second cue.
- **Do** keep each storage category in its own band; step share bars and treemap tiles through the bands by weight.
- **Do** route every animation through `Motion` so Reduce Motion turns it off.
- **Do** use `ChartSection` for grouped rows and `EmptyChart` for empty or all-clear states.

### Don't:
- **Don't** use chart magenta for decoration, safety verdicts or plain errors.
- **Don't** put glass on glass, or glass on the sidebar, toolbar or inspector.
- **Don't** set the control tint scene-wide; it fills every glass and bordered button.
- **Don't** add shadows, borders around groups, or a surface inside a surface.
- **Don't** run idle loops; motion without input is allowed only while data is loading.
- **Don't** add a second hero figure to a screen.
