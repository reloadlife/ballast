---
name: Ballast Website
description: A calm, sculptural introduction to making room on a Mac.
colors:
  paper: "#f8f8f5"
  ink: "#242521"
  muted: "#666760"
  line: "#ddded6"
  orange: "#bc4314"
  orange-bright: "#f16c38"
  sage: "#e7e9df"
  mist: "#edeee8"
  white: "#ffffff"
  ink-hover: "#3c3e36"
  outline-hover: "#eeeee8"
typography:
  display:
    fontFamily: "var(--font-manrope), sans-serif"
    fontSize: "clamp(4rem, 6.7vw, 6rem)"
    fontWeight: 500
    lineHeight: 1.055
    letterSpacing: "-0.04em"
  headline:
    fontFamily: "var(--font-manrope), sans-serif"
    fontSize: "clamp(2.5rem, 4.3vw, 3.8rem)"
    fontWeight: 500
    lineHeight: 1.13
    letterSpacing: "-0.04em"
  title:
    fontFamily: "var(--font-manrope), sans-serif"
    fontSize: "1.2rem"
    fontWeight: 650
    letterSpacing: "-0.025em"
  body:
    fontFamily: "var(--font-manrope), sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.75
  label:
    fontFamily: "var(--font-manrope), sans-serif"
    fontSize: "13px"
    fontWeight: 600
rounded:
  button: "10px"
  sheet: "12px"
  preview: "14px"
  feature: "16px"
  control: "30px"
spacing:
  compact: "16px"
  gutter-mobile: "24px"
  gutter-desktop: "40px"
  section-gap: "50px"
  split-gap: "100px"
components:
  button-primary:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.white}"
    rounded: "{rounded.button}"
    height: "48px"
    padding: "0 24px"
  button-primary-hover:
    backgroundColor: "{colors.ink-hover}"
  button-outline:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    rounded: "{rounded.button}"
    height: "48px"
    padding: "0 24px"
  button-outline-hover:
    backgroundColor: "{colors.outline-hover}"
  button-ghost:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    rounded: "{rounded.button}"
    height: "48px"
    padding: "0 24px"
  sculpture-control:
    backgroundColor: "#ffffff90"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    padding: "11px 17px"
  download-callout:
    backgroundColor: "{colors.sage}"
    rounded: "{rounded.sheet}"
    padding: "25px 30px"
---

# Design System: Ballast Website

## Overview

**Creative North Star: "Room to Breathe"**

Ballast's website makes disk space feel tangible through a softly shaded segmented sculpture, warm paper surfaces, and generous room around plain language. Manrope supplies a precise but approachable voice for the broad Mac audience; developer details remain readable supporting evidence.

This is the website system, scoped to `website/`. The native SwiftUI application's root `DESIGN.md` remains its own authority. Product facts and image provenance constrain the presentation: actual app captures are labeled, illustrative surroundings are disclosed, and the sculpture never pretends to show a visitor's disk.

**Key Characteristics:**

- Warm paper, charcoal type, and purposeful orange accents.
- Large restrained headlines and spacious split compositions.
- Physical depth in illustrations; quiet controls and content surfaces.
- Motion on request, with immediate reduced-motion state changes.

## Colors

The palette pairs warm neutrals with burnt orange and subdued sage.

### Primary

- **Burnt Orange** (`orange`): headline emphasis, text-link hover, and visible keyboard focus.
- **Sculpture Orange** (`orange-bright`): the illustration's category key. The Three scene uses its own lit orange material; do not substitute this decorative color for readable accent text.

### Secondary

- **Soft Sage** (`sage`): developer feature panel and download callouts.

### Neutral

- **Warm Paper** (`paper`): the page canvas.
- **Charcoal Ink** (`ink`): headings, navigation, and primary button fill.
- **Quiet Gray** (`muted`): paragraphs, supporting labels, and captions.
- **Paper Edge** (`line`): dividers and outlined controls.
- **Mist** (`mist`): the full-width index explanation surface.
- **White** (`white`): preview surface and primary button text.

**The Readable Orange Rule.** Use burnt orange for text and focus; reserve bright orange for illustration and category marks.

## Typography

**Display and Body Font:** Manrope Variable, self-hosted and preloaded through `next/font/local`, with a metric-adjusted Arial fallback in `--font-manrope` and a final sans-serif fallback. Developer filenames use the browser's monospace code face.

The hierarchy is large and light at the top, compact and firmer for labels. Headings use balanced wrapping; body text stays relaxed rather than becoming dense technical documentation.

- **Display:** hero headline, using the frontmatter role; emphasized words inherit its weight.
- **Headline:** section titles, with specific developer/FAQ headings at 42px on desktop.
- **Title:** short feature names and supporting headings.
- **Body:** feature paragraphs; the hero introduction is 16px, and guide ledes are 19px with 1.7 line height.
- **Label:** navigation; text links use 13px/700. Supporting notes and captions range from 9–12px and must not carry the sole explanation of a required action.

**The Plain Language Rule.** Let headlines explain the benefit and nearby prose explain the mechanism. Keep filenames in the developer context.

## Layout

The main container is 1216px including 40px inline gutters. The header expands to 1296px; reading pages narrow to 850px. Desktop sections commonly pair equal columns with a 100px gap, while headings pair a large title with short explanatory copy. Feature paragraphs are usually constrained to 350–400px.

At 1000px and below, split gaps become 50px and the hero headline becomes 4.6rem. At 700px and below, gutters become 24px, major splits stack, the hero uses `clamp(3.5rem, 12vw, 5.5rem)` with 1.07 line height, and standard section headings become 37px. Feature notes retain their compact two-column arrangement. Secondary header links and the illustrative preview sidebar hide; core navigation and download remain available. The developer panel has its own inset mobile margins and 35px by 26px padding.

Desktop section breathing room is typically 85–125px; mobile sections commonly use 60–70px. At 1500px and above the hero and sculpture stage increase in height. Keep the responsive reading order meaningful independently of the artwork.

## Elevation & Depth

Depth belongs to the physical sculpture, the real app preview's illustrative frame, and the tilted index sheet. Ordinary text and guide lists remain flat, separated by space or fine rules. Primary buttons have a small ambient shadow, not a heavy floating treatment.

- **Button:** `0 4px 10px #2425210c`.
- **App preview:** `0 24px 60px -25px #34352b35`.
- **Index sheet:** `-16px 24px 38px -15px #34352b30`, paired with perspective and gentle three-axis rotation.

**The Evidence Has Depth Rule.** Use physical framing to explain storage or show the application; keep reading surfaces calm.

## Shapes

Controls use compact rounded rectangles; pill geometry is reserved here for the sculpture's interaction control. The app frame, index sheet, and sage feature panel use slightly more generous corners from the frontmatter scale. Fine neutral borders define controls and rows. The sculpture is a beveled, three-layer segmented ring, with a lit material rather than a flat diagram fill.

## Components

### Buttons

Primary actions are charcoal with white text; outline and ghost variants support secondary actions. All share a 10px radius and 600 weight. Sizes are 40px/16px horizontal padding/12px text, 48px/24px/14px, and 56px/28px/14px. The mobile hero specifically uses 50px height, 20px horizontal padding, and 12px text.

Primary hover lifts by 2px and changes fill; active scales to 0.97. Outline hover adds a pale neutral fill. Ghost has no added hover fill. Disabled library buttons disable pointer interaction and use half opacity. Keyboard focus is an orange 2px outline; button utilities use a 4px offset, other controls the global 5px offset. Reduced motion removes transitions and hover translation.

### Navigation and text links

Header navigation is a compact horizontal group, with orange hover and visible focus. Text links pair bold text with an inline SVG arrow, adding orange and an underline on hover. Footer links use underline feedback. Keep SVG icons explicit; do not introduce icon fonts.

### App preview and feature surfaces

The preview combines the committed app image with a disclosed illustrative window. It clips to rounded corners and adapts by removing its decorative sidebar on small screens. Sage download callouts use a modest inset and no shadow. The developer feature is a larger two-column sage surface that stacks on mobile.

### Index sheet

The tilted paper sheet uses folder silhouettes, row labels, and explicit Updated/Unchanged text. Orange highlights a changed row; the textual state preserves meaning without color. Its shadow and perspective belong to this explanatory illustration rather than ordinary list components.

### Sculpture

Show the opaque, warm-paper WebP prerender from the exact Three scene immediately. Load Three and Motion on mouse entry, control focus, or click. The pressed-state button separates and reunites the layers using an interruptible 0.65-second, zero-bounce spring. Render only on state updates, pointer movement, and resize; there is no perpetual render loop. Reduced motion changes state immediately and suppresses pointer tilt. Failed WebGL initialization retains static closed/open images and an explicit status. Essential content remains outside the hidden decorative canvas.

### Health checks

Health reuses the equal-column explanatory section, stacking at the existing mobile breakpoint. Its semantic definition list stays flat: fine top rules, 22px vertical row padding, 1.2rem/650 titles with 10px below, and muted 14px descriptions at 1.8 line height. Preserve the relationship between each check and its explanation without adding card framing or decorative status badges.

### FAQ and guides

FAQs use native details/summary, fine row dividers, and an expanded-state marker. Guides use the narrower reading container, underlined orange prose links, and ruled link lists. No input or chip component is established in this website.

## Do's and Don'ts

### Do:

- **Do** preserve a complete readable page before interactive artwork loads.
- **Do** use burnt orange for readable emphasis and charcoal for the main action.
- **Do** distinguish actual application evidence from illustrative framing.
- **Do** maintain visible keyboard focus and immediate reduced-motion state changes.

### Don't:

- **Don't** make the canvas the only source of product information.
- **Don't** extend the illustration's depth treatment to every reading surface.
- **Don't** infer native application styling from this website system.
- **Don't** treat unused fallback CSS or superseded declarations as design tokens.
