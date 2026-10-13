---
name: Burrow
description: A native macOS window that shows what Mole would remove, lets you untick what to keep, and cleans only what stays ticked.
colors:
  ink-secondary: "#5C5C63"
  ink-secondary-dark: "#9E9EA6"
  strata-clay: "#B06145"
  strata-clay-dark: "#CC8566"
  strata-ochre: "#947014"
  strata-ochre-dark: "#D9B054"
  strata-moss: "#668047"
  strata-moss-dark: "#94B273"
  strata-slate: "#546E8A"
  strata-slate-dark: "#8CA8C7"
typography:
  row-primary:
    fontFamily: "SF Pro (system)"
    fontSize: "13px"
    fontWeight: 400
  row-secondary:
    fontFamily: "SF Pro (system)"
    fontSize: "11px"
    fontWeight: 400
rounded:
  swatch: "2.5px"
  bar: "4px"
  well: "6px"
  panel: "8px"
spacing:
  compact: "6px"
  inline: "10px"
  gutter: "12px"
  band: "16px"
  sheet: "24px"
  pane: "32px"
components:
  strata-bar:
    width: "12px"
    rounded: "{rounded.bar}"
  strata-swatch:
    width: "10px"
    height: "10px"
    rounded: "{rounded.swatch}"
---

# Design System: Burrow

## Overview

**Creative North Star: "The Soil Strata"**

Reclaimable space is a stack of layers you dig out one at a time. Burrow shows exactly what Mole would remove, grouped by category and sized, and lets you untick anything you want to keep before a single confirmation. The ground is neutral and native: system window materials, SF Pro, the system accent for actions, and four muted earth hues that name categories and nothing else.

The look refuses the category default. There is no giant "9.5 GB junk" ring or donut, no red alarm badge, and no fear copy. Sizes are plain numbers in monospaced digits. Density is low and calm, sized for an occasional cycle that takes under a minute.

**Key Characteristics:**
- Native macOS controls and system materials; no custom chrome.
- Four earth hues identify categories; they never signal alarm or action.
- Kept rows show their state by form as well as by colour.
- Two row text sizes, with sizes right-aligned in monospaced digits.
- Flat surfaces; depth comes from system materials and native sheets.
- A thin strata bar on the right edge tallies selected bytes live.

## Colors

Neutral native grounds carry four muted earth hues, and the system accent is the only colour that asks for action.

### Primary
- **System accent** (user-set, not a Burrow token): the one action colour. It fills the prominent toolbar action (Clean, Purge, Remove, Uninstall with its size or count), Scan and Retry, and the confirm sheet's action button.

### Secondary
- **Strata hues** (`strata-clay`, `strata-ochre`, `strata-moss`, `strata-slate`, each with a `-dark` variant in frontmatter): one hue per category, assigned by the category's position in the scan's group order. The same hue marks the group swatch, the layer in the strata bar and the swatch in the confirm sheet, so a category keeps its colour across the window. After four categories the cycle repeats at 60% opacity.
- Increased Contrast pushes each hue 25% away from its background: light values toward black, dark values toward white. Those values are recorded in the sidecar, not repeated here.
- Each light value measures at least 3.8:1 against white and against a #ECECEC window grey, which is enough for a non-text indicator.

### Neutral
- **Ink secondary** (`ink-secondary`, `ink-secondary-dark`): secondary and dimmed text, including detail lines, trailing counts, kept-row sizes, footer counts, paths, group size text and the disclosure chevron. It measures about 5.6:1 on #ECECEC and about 6.3:1 on a #1E1E1E dark window. It does not change under Increase Contrast.
- **System primary label and materials**: item titles use the primary label. The footer and notice bars sit on the system bar material. The strata track and the log well use a quaternary fill.
- **System red**: used once, for the failed "Always keep" line. Red never marks a category or a size.

**The Layers Not Alarm Rule.** The four strata hues identify categories and never carry alarm, status or action. Red appears only where a write has failed. No size is coloured by how large it is.

## Typography

**Display Font:** SF Pro (system). No custom or display faces.
**Body Font:** SF Pro (system).
**Label/Mono Font:** SF Mono (system monospaced) for file paths and log lines. Digits in size columns use monospaced digits on SF Pro.

**Character:** Plain system type that reads like the rest of macOS. Rank comes from weight and colour, not from size.

### Hierarchy
- **Row primary** (13pt, regular 400, body): item titles, size columns, the footer total, and group titles at semibold 600.
- **Row secondary** (11pt, regular 400, subheadline): detail lines, item counts, the "Kept" label, trailing notes, path lines (monospaced), notices, and sidebar subtitles.
- **Page heading** (system title3, 15pt; title2, 17pt semibold): sits outside rows. Used for "Scanning" and running status, the confirm headline (title3 semibold), the done title, and the "Burrow needs Mole" title (title2 semibold).
- **Log lines**: row secondary, monospaced, selectable.

**The Two-Size Row Rule.** Rows use exactly two sizes, 13pt and 11pt. Weight and colour mark rank inside a row; a third size does not.

## Layout

- **Window**: a split view with a sidebar of 240 to 320pt (ideal 260pt) listing the four jobs, and a detail pane that fills the rest. Minimum window size 940 x 600pt.
- **Review list**: an inset list fills the detail pane's height. The strata bar sits on its right edge with 20pt clear of the native scroller on its left and 12pt on its right, and 12pt of vertical padding. Uninstall adds a 300pt leftovers pane beside the list.
- **Rows**: 3pt vertical padding. From left to right: checkbox (16pt), title stack, flexible gap (minimum 12pt), trailing note (84pt, right-aligned), size (76pt, right-aligned, monospaced digits), disclosure (16pt). Expanded paths indent 42pt on the leading side and 28pt on the trailing side.
- **Footer**: bar material under the list, 16pt horizontal and 8pt vertical padding.
- **Phase views**: centred columns. Running caps at 560pt and done at 520pt, both with 32pt padding. The confirm sheet is 440pt wide with 24pt padding and 16pt section spacing.
- **Spacing steps in use**: 6, 10, 12, 16, 24 and 32pt. These are observed values, not a strict grid.
- **Responsive behaviour**: the layout is fixed. The minimum window size keeps the split view intact; no compact layout exists.

## Elevation & Depth

Flat. No shipping surface carries a shadow. The only shadow in the codebase is in the snapshot harness's presentation frame, which is not UI. Depth comes from system materials (the bar material on the footer and notices), quaternary fills (the strata track and the log well), and native sheets for modal confirmation.

**The Flat Window Rule.** Surfaces are flat. A modal step is a native sheet, not a shadow.

## Shapes

Rounded rectangles with continuous corners (`style: .continuous`) throughout. Observed radii: strata swatch 2.5pt, strata bar 4pt (track and clip), log well 6pt, command panel 8pt. Rows have no fill, border or divider of their own; the list supplies selection. Checkboxes and disclosure chevrons are native controls. The confirm sheet separates its lines with system dividers.

## Components

Quiet rows that carry all of the state.

### Item Rows
- **Shape:** no container; the whole row is the hit area; 3pt vertical padding.
- **Selectable:** a native checkbox. Title and size in the primary label.
- **Kept (Clean, Purge, Installers):** an unticked row dims. Title and detail move to ink-secondary, the size is struck through, and a "Kept" label sits under the size. VoiceOver speaks "size, kept".
- **Opt-in (Uninstall, AI leftovers):** an unticked row dims and nothing more. No strike, no label. VoiceOver speaks "size, not selected".
- **Not removable:** the checkbox is replaced by 16pt of empty space, and the trailing note in ink-secondary says why Burrow will not remove it.
- **Disclosure:** the chevron rotates 90 degrees when paths are shown. Up to eight paths appear in monospaced row-secondary text, followed by "and N more".

**The Kept Shows Its Form Rule.** In a clean-style list, an unticked row is kept, and it shows that in form as well as colour: dimmed, struck through and labelled "Kept".

**The Opt-In Exception.** Uninstall and AI leftovers default to unticked, so an unticked row there means "not chosen", not "kept". Those rows dim and carry no strike and no label.

### Group Headers
- A native tri-state checkbox (on, off, mixed) for the whole group, a strata swatch, a semibold group title, and a trailing size in monospaced digits. When the group is partly selected the size reads "X of Y".

### Strata Bar
- 12pt wide, spanning the list height less 12pt top and bottom. The track is a quaternary fill with 4pt corners, clipped to the same shape. One layer per category that has selected bytes, stacked in group order and anchored to the bottom, with 1pt gaps and a 2pt minimum height. Each layer has a tooltip: category, size selected.
- Layers animate over 0.22s with ease-out. The animation is off under Reduce Motion.
- VoiceOver reads the bar as one value: "Selected space by category", with each category and its size.

**The Shrinking Bar Rule.** The bar tallies selected bytes; it is not a gauge of the disk. Unticking a row thins its layer, and nothing else on the bar carries meaning.

### Strata Swatch
- A 10pt rounded square (2.5pt corners) in the category's hue, hidden from VoiceOver. Used in group headers and in the confirm sheet.

### Footer
- Bar material. "X of Y selected" in the primary label and "N of M items" in ink-secondary. "Select all" (hidden for Uninstall) and "Select none" are small link buttons, disabled when they would do nothing. When a search is active they act only on the visible rows.

### Toolbar Action
- A Rescan control with the arrow.clockwise symbol, and a prominent action button labelled with its action and size, such as "Clean 7.8 GB", in monospaced digits. It is disabled at zero selected.

### Confirm Sheet
- 440pt wide. A title3 semibold headline, then the consequence sentence in ink-secondary, then up to six category lines (swatch, title, count, size) with "and N more" after them. Cancel (Escape) and the prominent action (Return) sit at the bottom right; the action carries the destructive role.

### Sidebar
- A sidebar-style list. Each job has an SF Symbol in a 20pt column in ink-secondary, a title in row primary, a one-line subtitle in row secondary (truncated so rows keep their height), and a monospaced size on the right once a scan has sized it.

### Running and Done
- Running: the status in title3, a linear progress bar (determinate when Mole reports progress, indeterminate otherwise), "N of M items" only when progress is known, and a collapsible Details log in a 260pt quaternary well with 6pt corners. Stop is bound to Escape.
- Done: a centred column. The title is "X freed" or "N items removed". Uninstall reads "N apps moved to the Trash" and "Empty the Trash to free the space." A single prominent "Scan again" closes the column.

### System Symbols
- SF Symbols are the native device for sidebar icons, status notices, empty states and disclosure chevrons. They are not decoration added on top of the system.

## Do's and Don'ts

### Do:
- **Do** dim kept rows, strike their size and label them "Kept" in clean-style lists, so the state reads without colour.
- **Do** keep the opt-in exception: Uninstall and AI leftovers dim unticked rows and nothing more.
- **Do** set secondary text in `ink-secondary`, which holds at least 4.5:1 in both appearances.
- **Do** right-align sizes in a fixed-width column with monospaced digits.
- **Do** keep row text to the two sizes, 13pt and 11pt.
- **Do** use the system accent for actions, and the system bar and quaternary materials for chrome.
- **Do** write confirm copy in plain words: the headline names the count and size, the sentence says what happens to each kind, and "Anything you unticked stays where it is." follows.

### Don't:
- **Don't** use the strata hues for alarm, status or buttons.
- **Don't** strike or label unticked rows in Uninstall or AI leftovers.
- **Don't** add a third row size or a custom display face.
- **Don't** add shadows to resting surfaces.
- **Don't** use a ring or donut total, a red alarm badge, or fear words in the confirm sheet.
- **Don't** read the strata bar as a gauge against the disk total; it tallies selected bytes.
