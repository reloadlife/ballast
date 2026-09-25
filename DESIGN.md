---
name: Ballast
description: A calm, native macOS storage utility. Plain words, one accent color, nothing animated that isn't feedback.
colors:
  accent: "#007AFF"
  category-applications: "#5856D6"
  category-your-files: "#007AFF"
  category-caches: "#FF9500"
  category-build-files: "#FFCC00"
  category-system: "#8E8E93"
  safety-safe: "#34C759"
  safety-quit-first: "#FF9500"
  safety-caution: "#FFCC00"
  safety-protected: "#FF3B30"
  age-warm: "#E6731A"
  unmeasured-tile: "#9E9E9E"
  window-background: "#FFFFFF"
  grouped-surface: "#F9F9F9"
  track: "#EBEBEB"
typography:
  display:
    fontFamily: "SF Pro Rounded, system-ui"
    fontSize: "34px"
    fontWeight: 600
    fontFeature: "tnum"
  headline:
    fontFamily: "SF Pro, system-ui"
    fontSize: "17px"
    fontWeight: 600
  title:
    fontFamily: "SF Pro, system-ui"
    fontSize: "13px"
    fontWeight: 700
  body:
    fontFamily: "SF Pro, system-ui"
    fontSize: "13px"
    fontWeight: 400
  label:
    fontFamily: "SF Pro, system-ui"
    fontSize: "12px"
    fontWeight: 400
  caption:
    fontFamily: "SF Pro, system-ui"
    fontSize: "10px"
    fontWeight: 400
rounded:
  bar: "6px"
  tile: "7px"
  group: "12px"
  callout: "14px"
  capsule: "9999px"
spacing:
  row-y: "9px"
  gap: "12px"
  inset: "14px"
  callout: "18px"
  section: "32px"
  page-x: "36px"
  content-max: "780px"
components:
  button-prominent:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.window-background}"
    rounded: "{rounded.capsule}"
  card-grouped:
    backgroundColor: "{colors.grouped-surface}"
    rounded: "{rounded.group}"
    padding: "{spacing.inset}"
  card-callout:
    rounded: "{rounded.callout}"
    padding: "{spacing.callout}"
  size-bar:
    backgroundColor: "{colors.track}"
    rounded: "{rounded.capsule}"
    height: "5px"
  storage-bar:
    backgroundColor: "{colors.track}"
    rounded: "{rounded.bar}"
    height: "20px"
  treemap-tile:
    backgroundColor: "{colors.accent}"
    rounded: "{rounded.tile}"
---

# Design System: Ballast

## Overview

**Creative North Star: "The Storage Pane That Shipped With macOS"**

Ballast should look like Apple wrote it next to System Settings › Storage. The chrome is stock macOS 26: a `NavigationSplitView` sidebar, a toolbar, and a right-hand inspector for the Cleanup List. The system gives those their Liquid Glass. Content sits on plain window and grouped backgrounds, set in SF text styles, with one accent color carrying the data. Nothing is decorative. Every color, symbol and motion either encodes a measurement or answers something the user did.

Density is moderate. Overview is a single 780pt reading column, Explorer is a full-bleed treemap over a native `Table`, Suggestions is an inset `List` in sections. Words are plain and specific ("32.6 GB can be cleaned safely", "Quit the app first"). Numbers are measured values, never estimates, and gaps such as locked folders are named instead of hidden.

This direction replaced an earlier "radar" direction that the owner rejected as hard to read and laggy. Don't bring back custom-drawn instruments or ambient animation.

**Key Characteristics:**
- Stock chrome with system Liquid Glass. Content stays flat on plain backgrounds.
- One data color: the user's system accent.
- Category colors appear only in the storage bar and its legend.
- Safety is a fixed four-part vocabulary of symbol, color and title.
- Every byte figure uses tabular digits.
- All motion is feedback, and all of it goes through `Motion`, which turns it off under Reduce Motion.

## Colors

Ballast defines no custom colors. The palette is system semantic colors, and the only chromatic element that varies is the accent the user picked in System Settings. The hex values in the frontmatter are light-mode approximations of the SwiftUI colors named below, which are the real source of truth. The accent is recorded as the macOS default blue (#007AFF light, #0A84FF dark); the review captures in `.impeccable/review/minimal` show the owner's own accent choice, which is exactly the behavior this system expects.

### Primary
- **System Accent** (`Color.accentColor` / `.tint`): the only data color. It fills size bars, treemap tiles in Size mode, the free-space chart line and area, folder icons in the Explorer table, the ⊕/✓ list toggle when on, prominent buttons, the tint on the "can be cleaned safely" callout (8% opacity), and the drop-target highlight on the Cleanup List. No asset catalog or code overrides it.

### Secondary
- **Storage Categories** (`.indigo` Applications, `.blue` Your files, `.orange` Caches, `.yellow` Build files, `.gray` System & other): these explain what fills the disk, in the Overview storage bar and its legend dots (8pt circles). They never appear anywhere else.

### Tertiary
- **Safety Levels** (`.green` Safe to clean, `.orange` Quit the app first, `.yellow` Check before cleaning, `.red` Protected): tint only the safety symbol on Cleanup List rows and the safety legend.
- **Age Warm** (#E6731A in the treemap; system `.orange`/`.red` in the Last Changed column): stands for "long untouched". In Age mode, treemap tiles blend from neutral gray toward this orange on a log scale up to one year. `AgeBadge` turns `.orange` at 3–6 months and `.red` past 6 months. Anything more recent stays `.secondary`.
- **Destructive Red** (`.red`): the Clean Up button tints red when "Delete Now" is selected. Red also marks the dashed 2pt outline of treemap tiles already on the list, sidebar errors, and the free-space bar when less than 10% of the disk is free.

### Neutral
- **Window Background** (`.background`): plain content background for Overview and Suggestions.
- **Grouped Surface** (`.background.secondary`): the fill for grouped cards (access notes, Largest folders, the Trash note after cleaning).
- **Track** (`.quaternary`): the empty track behind size bars and the free-space remainder of the storage bar.
- **Unmeasured Tile** (white 0.62 in light mode, 0.32 in dark): treemap tiles for "Other folders", loose "Files" and locked folders. They are gray because they have no measured subtree to rank.
- **Text hierarchy** (`.primary`, `.secondary`, `.tertiary`): name / detail / path. Paths and breadcrumb chevrons use `.tertiary`.

### Named Rules
**The Borrowed Accent Rule.** Data is drawn in `Color.accentColor` and nothing else. Never hard-code a brand blue in UI. The app should turn purple when the user's Mac does.

**The Storage Bar Owns Category Color Rule.** The five category colors exist only in the storage bar and its legend. Lists, tiles and charts don't color-code by category.

**The Actionable Alarm Rule.** Warning color appears only where the user can do something about it. Rows that are protected, locked or empty get a muted `AgeBadge` and no list toggle, because alarm with nothing to do is noise.

## Typography

**Display Font:** SF Pro Rounded (system, `.rounded` design), for the free-space figure only
**Body Font:** SF Pro (system text styles)

**Character:** The type is exactly what macOS uses. Hierarchy comes from Apple's text styles, weight and `.secondary` color. There are no custom sizes except the single rounded hero number.

### Hierarchy
- **Display** (semibold, 34pt, SF Rounded, tabular digits): available space, top right of Overview. It is the largest number on the first viewport and it animates with `.numericText`.
- **Headline** (`.title2`, semibold, 17pt): volume name, the Suggestions summary ("… can be cleaned safely"). `.largeTitle` semibold is used for the first-run welcome only, and `.title3` semibold for the inspector's "Cleanup List" heading.
- **Title** (`.headline`, 13pt bold): section titles ("Largest folders", "Free space over time"), Suggestions category headers, callout title.
- **Body** (`.body`, 13pt): row names, access-note titles.
- **Label** (`.callout`, 12pt): row detail lines, legends, secondary actions. `.caption` (10pt) is for the sidebar footer, age badges and safety reasons. `.caption2` is for paths in the inspector and treemap size lines.

### Named Rules
**The Tabular Bytes Rule.** Every byte count, file count and percentage uses `.monospacedDigit()`, so columns line up and figures don't jitter while updating.

**The Text Style Rule.** Use SwiftUI text styles (`.headline`, `.callout`, `.caption`) with weight modifiers. Don't use point sizes. The one exception is the 34pt rounded display figure.

## Layout

- **Chrome:** `NavigationSplitView` with a sidebar (200–220pt) listing Overview, Explorer and Suggestions as `Label`s with SF Symbols. A footer pinned to the bottom shows scan progress, available space and a 5pt free-space bar. The Cleanup List is an `.inspector` (300–480pt, ideal 350). Status goes in the toolbar subtitle (`navigationSubtitle`), never in page content.
- **Overview:** one scrolling column, 780pt max width, 36pt horizontal and 32pt vertical padding, 32pt between sections. The first viewport follows the Storage-settings layout: volume name and "used of total" on the left, available space as the largest number on the right, a 20pt segmented storage bar, a legend, then the single "can be cleaned safely" callout with Review.
- **Explorer:** a header bar (breadcrumb, Size/Age segmented picker, total, Show in Finder), then a `VSplitView` with the treemap (12pt inset, 200pt minimum) above a sortable `Table`.
- **Suggestions:** an inset `List` with a summary section, then one section per category. Each section header has the category name, one line of advice, an optional link action, and the total.
- **Row rhythm:** 14pt horizontal padding, 9–11pt vertical padding, 12pt gaps between row elements. Trailing columns have fixed widths (size bar 80–90pt, byte figure 72–76pt, right-aligned).

## Elevation & Depth

Content is flat. The Views code adds no shadows. Depth comes from the system: Liquid Glass on the sidebar, toolbar and inspector, and tonal grouping in content (`.background.secondary` cards on the window background). Glass button styles (`.glass`, `.glassProminent`) are used inside the Cleanup List inspector, which is a system glass surface, and nowhere in main content.

### Named Rules
**The System Glass Rule.** Glass comes from the system chrome and its button styles. Don't add custom materials, blurs or shadows to content.

## Shapes

Corners are continuous (`style: .continuous`), sized to the element: 6pt for the storage bar, up to 7pt for treemap tiles (capped at a third of the tile's shorter side), 12pt for grouped cards, 14pt for the accent callout and the empty drop zone. Size bars are capsules. Dividers inside grouped cards are inset to line up with the text (14pt, or 44pt after a leading symbol). The only dashed strokes mean "list": red 5/3 dashes on treemap tiles already on the Cleanup List, and accent or quaternary 6/4–6/5 dashes on the drop zone.

## Components

### Buttons
- **Primary:** `.borderedProminent` in the accent color, `.large` or `.extraLarge` (Scan Disk, Review, Add All Safe Items). One per view.
- **Inspector:** `.glass` (Add…, Choose Files…) and `.glassProminent` (Clean Up, Done). Clean Up fills the width at `.extraLarge`, is labelled with the actual bytes ("Clean Up 32.6 GB"), and tints red when deleting permanently.
- **Secondary:** default bordered (Rescan, Scan as Admin…). In-flow text actions use `.link` ("Add Ones Older Than 3 Months", "Open Settings"). Icon-only controls use `.borderless`.
- **Destructive:** `role: .destructive` behind a `confirmationDialog` that names the count and bytes. Move to Trash is the default.

### List Toggle (signature)
The ⊕ / ✓ control that adds an item to the Cleanup List. It shows `plus.circle` in `.secondary` or `checkmark.circle.fill` in the accent, at `.title3`, switching with `.symbolEffect(.replace)`. Protected items get an empty 20pt placeholder instead of a control, and the reason goes in the context menu.

### Size Bar
A 5pt capsule on a `.quaternary` track, filled with the accent gradient, with a minimum visible width of 3pt when the value is non-zero. Its length is relative to the largest sibling or the parent folder, not the disk.

### Storage Bar
A 20pt rounded bar with one segment per category, 2pt gaps, and free space as the empty track. It carries an accessibility summary of every segment plus free space.

### Cards / Containers
- **Grouped card:** `.background.secondary`, 12pt continuous radius, no border, inset dividers, rows with a hover fill of `primary` at 4%.
- **Callout:** accent at 8%, 14pt radius, 18pt padding, a leading `.title` symbol in `.tint`, headline plus secondary line, and a trailing prominent button.

### Treemap (signature)
A squarified treemap drawn in one `Canvas` so hovering stays smooth, with 1.5pt insets between tiles. In Size mode tiles use the true accent hue, with lightness stepping by size: in light mode they mix toward white by up to 60%, in dark mode toward black by up to 50%. Labels (`.caption` semibold name, `.caption2` size) are drawn only when the tile is at least 64×34pt. Label color is chosen per tile: white on deep tiles, black at 80% on pale ones, white throughout in dark mode. Hovering adds a 2pt `primary` 70% outline. Age mode blends gray toward Age Warm.

### Safety Label
A fixed set of four: `checkmark.shield.fill` green "Safe to clean", `pause.circle.fill` orange "Quit the app first", `exclamationmark.triangle.fill` yellow "Check before cleaning", `nosign` red "Protected". Rows show the symbol in its level color, followed by the plain-language reason in `.secondary` caption. Quit-first rows add a small "Quit {App}" button. Caution rows add a "Clean this anyway" checkbox. Items that need a decision are grouped under an orange "Needs you" header at the top of the list.

### Navigation
The sidebar uses a `List` with `Label`s (`internaldrive`, `square.grid.3x3.topleft.filled`, `lightbulb`). Explorer's breadcrumb uses `.plain` buttons with the current folder in semibold `.primary` and ancestors in `.secondary`, separated by `.tertiary` chevrons. Back is ⌘←.

### Motion
Every animation goes through `Motion.animation(_:)`, which returns `nil` when Reduce Motion is on. The vocabulary is small: `.smooth` for status changes, `.smooth(duration: 0.6)` for byte figures and storage segments, `.snappy` when items are added to or removed from the list, `.numericText` for changing numbers, `.symbolEffect(.replace)` when a symbol changes state, and one `.bounce` on the clean result, gated on `Motion.reduced`.

## Do's and Don'ts

### Do:
- **Do** draw data in `Color.accentColor` and let the system decide what it is.
- **Do** use SF text styles and SF Symbols, and put `.monospacedDigit()` on every number.
- **Do** put content on `.background` / `.background.secondary` with continuous corners (12pt cards, 14pt callouts).
- **Do** send every animation through `Motion.animation(_:)`, and gate symbol effects on `Motion.reduced`.
- **Do** show a safety symbol and a plain reason next to anything that can be deleted, and put the byte count on the destructive button.
- **Do** keep status in the toolbar subtitle and the sidebar footer.
- **Do** write copy the way macOS writes it: sentence case for text, title case for buttons and menu items, specific numbers, no exclamation marks.

### Don't:
- **Don't** hard-code an accent or brand color in UI. The blue gradient in `scripts/make-icon.swift` is for the app icon only.
- **Don't** use category colors outside the Overview storage bar and its legend.
- **Don't** add custom shadows, blurs or materials to content.
- **Don't** animate anything that isn't a response to data or input: no idle motion, no radar sweeps.
- **Don't** show warning color, or an add control, on rows the user can't act on.
- **Don't** show an unmeasured folder as zero. Label it "Locked".
