---
name: Ari Meeting
description: A focused local meeting workspace for capture, notes, and recall, themed to the Marginalia brand — two inks on warm paper.
colors:
  canvas: "#FAF8F5"
  surface: "#FFFFFF"
  surface-subtle: "#F1EDE6"
  surface-strong: "#E6E1D8"
  ink: "#2B2620"
  heading: "#152C66"
  ink-muted: "#6F6759"
  ink-faint: "#A89F92"
  rail: "#F1EDE6"
  rail-hover: "#E6E1D8"
  rail-selected: "#1B3A8C"
  rail-ink: "#2B2620"
  rail-muted: "#6F6759"
  accent: "#1B3A8C"
  accent-soft: "#DEE3F0"
  success: "#42794F"
  warning: "#B57817"
  danger: "#C6362C"
  info: "#20408C"
  border: "#E6E1D8"
  border-strong: "#D8CFC2"
  dark-canvas: "#211E1B"
  dark-surface: "#2D2925"
  dark-rail: "#2B2723"
  dark-ink: "#EDE8E1"
  dark-heading: "#E8EAF2"
  dark-accent: "#7E9BE8"
typography:
  display:
    fontFamily: "Bricolage Grotesque, -apple-system, BlinkMacSystemFont, SF Pro Text, sans-serif"
    fontSize: "32px"
    fontWeight: 700
    lineHeight: 1.08
    letterSpacing: "-0.02em"
  headline:
    fontFamily: "Bricolage Grotesque, -apple-system, BlinkMacSystemFont, SF Pro Text, sans-serif"
    fontSize: "24px"
    fontWeight: 700
    lineHeight: 1.15
    letterSpacing: "-0.01em"
  title:
    fontFamily: "Bricolage Grotesque, -apple-system, BlinkMacSystemFont, SF Pro Text, sans-serif"
    fontSize: "17px"
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: "-0.01em"
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, SF Pro Text, Segoe UI, sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.55
    letterSpacing: "normal"
  label:
    fontFamily: "-apple-system, BlinkMacSystemFont, SF Pro Text, Segoe UI, sans-serif"
    fontSize: "12px"
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: "0.02em"
  mono:
    fontFamily: "SFMono-Regular, ui-monospace, Menlo, monospace"
    fontSize: "12px"
    fontWeight: 500
    lineHeight: 1.4
    letterSpacing: "normal"
rounded:
  xs: "4px"
  sm: "6px"
  md: "10px"
  lg: "14px"
  full: "9999px"
spacing:
  "1": "4px"
  "2": "8px"
  "3": "12px"
  "4": "16px"
  "5": "24px"
  "6": "32px"
  "7": "40px"
  "8": "48px"
components:
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.canvas}"
    typography: "{typography.body}"
    rounded: "{rounded.sm}"
    padding: "9px 14px"
    height: "36px"
  button-record:
    backgroundColor: "{colors.danger}"
    textColor: "{colors.canvas}"
    typography: "{typography.body}"
    rounded: "{rounded.sm}"
    padding: "9px 14px"
    height: "36px"
  button-secondary:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.sm}"
    padding: "9px 14px"
    height: "36px"
  field:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.sm}"
    padding: "9px 12px"
    height: "36px"
  navigation-item:
    backgroundColor: "{colors.rail}"
    textColor: "{colors.rail-muted}"
    typography: "{typography.body}"
    rounded: "{rounded.sm}"
    padding: "8px 10px"
    height: "36px"
  navigation-item-selected:
    backgroundColor: "{colors.rail-selected}"
    textColor: "{colors.canvas}"
    typography: "{typography.body}"
    rounded: "{rounded.sm}"
    padding: "8px 10px"
    height: "36px"
---

# Design System: Ari Meeting

> This document and `DESIGN.json` are the load-bearing test fixtures for the **outgoing (frozen) Tauri app** (`frontend/tests/lib/visual-system.test.mjs`), kept in lockstep with `frontend/src/app/globals.css`. The canonical brand is **Marginalia** — `brand/BRAND.md` + `brand/tokens.json`, the go-forward SwiftUI source of truth. This file applies Marginalia to the Tauri app; on any conflict, `brand/BRAND.md` wins.

## Overview

**Creative North Star: "Marginalia — the notebook that listens"**

Ari Meeting should feel like a working instrument in a private study, not a SaaS dashboard: **two inks on warm paper.** A porcelain paper canvas holds the meeting; a warm elevated-paper rail holds tools and state. Navigation is compact, predictable, and low-chrome. Transcript, summary, notes, and local model feedback breathe without being wrapped in a grid of decorative cards.

The visual signature comes from the Marginalia palette — porcelain and espresso paper grounds, a warm-charcoal body ink paired with an Iron Gall **heading ink** (the second ink), and a scarce **Shin-kai** interactive accent — set in **Bricolage Grotesque** headings over an **SF Pro** body, with tight geometry and unusually honest state language.

**Key Characteristics:**

- Warm porcelain canvas with a warm elevated-paper rail (both go espresso in dark mode) — no navy rail.
- Two inks: warm-charcoal body text and non-interactive Iron Gall headings.
- Restrained Shin-kai accent reserved for selection, citations, links, and speaker names.
- Flat-by-default surfaces separated by warm tone and one-pixel borders.
- State-driven motion only; no decorative page choreography.

## Colors

The palette is warm-neutral and high-contrast. Color is functional, scarce, and therefore meaningful. Every neutral is warm — porcelain, espresso, charcoal, taupe — never cool gray.

### Primary

- **Shin-kai (`#1B3A8C`):** the sole interactive ink — selection, citations, links, speaker names, and the one primary action per view (its only solid fill). If it's Shin-kai, you can act on it.
- **Iron Gall heading ink (`#152C66`):** headings and display text only — the "second ink". Non-interactive; never a fill, never a state signal.
- **Warm Charcoal Ink (`#2B2620`):** body copy and controls — never pure black.

### Secondary

- **Porcelain Paper Canvas (`#FAF8F5`):** the application background behind working surfaces.
- **Card Surface (`#FFFFFF`):** transcript, summary, editor, dialog, and field surfaces.
- **Elevated Paper (`#F1EDE6`):** the sidebar/rail ground and grouped regions; warm hover/recessed layers (`surface-subtle`, `surface-strong`).

### Neutral

- **Secondary Ink (`#6F6759`):** secondary descriptions and metadata (AA at any size). Never the only copy of critical information.
- **Faint Ink (`#A89F92`):** placeholders and tertiary information only when contrast remains valid.
- **Hairline (`#E6E1D8`):** one-pixel warm separation between adjacent functional regions.

### Dark Mode

Dark mode is espresso-grounded, not a naive inversion: canvas `#211E1B`, card surface `#2D2925`, rail `#2B2723`, body ink becomes paper-white `#EDE8E1`, heading ink becomes ink-washed paper-white `#E8EAF2` (blue-black cannot survive honestly on dark), and the Shin-kai accent lifts to `#7E9BE8`. Contrast and the accent-for-interaction discipline are preserved on both grounds.

### Named Rules

**The Signal Rule.** The Shin-kai accent appears on no more than 8% of a screen and only for selection, citations, links, and speaker names. Solid Shin-kai fill is reserved for the one primary action per view.

**The Two-Ink Rule.** Body text is warm charcoal; headings and display text use the Iron Gall second ink (Bricolage Grotesque). The heading ink is non-interactive and never signals state — it sits outside the accent budget.

**The Warm Neutral Rule.** Every neutral is warm (porcelain, espresso, charcoal, taupe). Never introduce cool gray or blue-gray fills.

**The No Fake State Rule.** Semantic colors and progress treatments require authoritative application state and a text or icon label.

## Typography

**Heading/Display Font:** **Bricolage Grotesque** (SIL OFL), bundled locally (`frontend/public/fonts/BricolageGrotesque-Variable.woff2`) so it renders offline. Headings and display text only, at ≥ 17px; it keeps a grotesque lineage with the outgoing Space Grotesk while its ink traps carry the fountain-pen story.
**Body/UI Font:** the native **SF Pro** system stack — all body, controls, labels, and metadata; SF Pro Semibold stands in for headings below the 17px floor.
**Mono Font:** the native monospace stack (SF Mono → `ui-monospace`), reserved for timestamps, model identifiers, and technical values (tabular numerals).

**Character:** Precise, calm, and literate. Hierarchy comes from confident weight, the two-ink distinction, and deliberate reading measures rather than oversized marketing copy.

### Hierarchy

- **Display** (Bricolage 700, 32px, 1.08): route-defining titles only, in heading ink; never a greeting that repeats the navigation context.
- **Headline** (Bricolage 700, 24px, 1.15): primary workspace sections and meeting titles, heading ink.
- **Title** (Bricolage 600, 17px, 1.3): panels, dialogs, and high-value rows, heading ink.
- **Body** (SF Pro 400, 14px, 1.55): controls and explanatory copy; long-form prose is capped at 72ch.
- **Label** (SF Pro 600, 12px, 0.02em): compact metadata and short section labels; uppercase eyebrows use secondary ink, never accent or heading ink.
- **Mono** (SF Mono 500, 12px, 1.4): timestamps, model identifiers, file formats, and technical values.

### Named Rules

**The Product Voice Rule.** No marketing-scale greetings inside the desktop app. The largest type names the work currently open.

**The Reading Rule.** Transcript, summary, and notes use comfortable line-height and a readable measure even when surrounding controls remain dense.

## Elevation

The system is flat by default. Depth comes from tonal layering, one-pixel borders, and fixed panel boundaries. Shadows appear only on content that temporarily floats above the workspace: menus, tooltips, dialogs, and drag overlays.

### Shadow Vocabulary

- **Floating Control** (`0 8px 24px rgba(43, 38, 32, 0.10)`): popovers, menus, and compact floating controls.
- **Dialog** (`0 24px 64px rgba(43, 38, 32, 0.18)`): blocking dialogs and recovery/import overlays.
- **Focus Halo** (`0 0 0 3px rgba(27, 58, 140, 0.18)`): keyboard focus paired with a solid Shin-kai outline.

No gradients, no glassmorphism of our own — the warm palette carries the paper feeling on its own.

### Named Rules

**The Flat Workspace Rule.** Static content surfaces do not float. If every region casts a shadow, the hierarchy has failed.

**The State Lift Rule.** Elevation may respond to hover, drag, menu, or modal state; it may not be permanent decoration.

## Components

Components are compact and familiar. Their personality comes from precision and state clarity rather than unusual affordances.

### Buttons

- **Shape:** compact rectangular controls with gently softened corners (6px).
- **Primary:** solid Shin-kai fill, porcelain text, 36px height. One primary action per screen — the only solid accent fill.
- **Recording:** recording red (`#C6362C`) only for starting or representing active capture; never co-branded with the accent.
- **Hover / Focus:** tonal shift in 180ms; keyboard focus uses a solid Shin-kai outline and soft halo.
- **Secondary / Ghost:** Card Surface with one-pixel border, or transparent when placed in a toolbar.

### Chips

- **Style:** small tonal labels with 6px corners, never decorative pills by default.
- **State:** semantic icon plus text. A selected filter uses the Shin-kai selection wash with accent text; the active recording chip is recording red.

### Cards / Containers

- **Corner Style:** 10px only for independent bounded objects; continuous workspace regions remain square or 4px.
- **Background:** Card Surface or a named warm layer neutral.
- **Shadow Strategy:** flat at rest.
- **Border:** one-pixel Hairline when adjacent tone is insufficient.
- **Internal Padding:** 16px compact, 24px reading, 32px major workspace.

### Inputs / Fields

- **Style:** Card Surface, one-pixel border, 6px corners, 36px standard height.
- **Focus:** Border becomes Shin-kai and receives the Focus Halo.
- **Error / Disabled:** error includes text and icon; disabled lowers contrast without hiding the control's label.

### Navigation

The rail uses secondary-ink labels on warm paper at rest (paper-white on espresso in dark mode), a quiet tonal hover layer, and a clearly differentiated selected row (Shin-kai). The **Dictation mark** — the cursive "a" whose tail runs out as a hand-drawn waveform (`AriMark`, rendered in Shin-kai) — sits at the top of the rail above the "Ari Meeting" product label, collapsing to the signature flick on the narrow rail. The persistent shell uses the app's structural glyphs (`MeetilyGlyph`) at 16–18px with a consistent 1.45px rounded stroke; descriptive content actions may use the established semantic icon library. The recording control is separated from route navigation and uses recording red only when it needs to dominate.

### Meeting Workspace

The meeting title and authoritative date establish context. Summary is the first reading surface when present. Transcript remains immediately discoverable and virtualized. Tools live in compact bars or inspectors, not inside repeated nested cards.

## Do's and Don'ts

### Do:

- **Do** use the warm porcelain canvas and warm-paper rail as the primary compositional structure.
- **Do** keep the Shin-kai accent scarce and tied to real selection, citation, link, or speaker-name state.
- **Do** render headings in Bricolage Grotesque and the Iron Gall heading ink.
- **Do** keep every neutral warm — porcelain, espresso, charcoal, taupe.
- **Do** use 4/8/12/16/24/32/40/48 spacing tokens and 6/10/14px radii only.
- **Do** preserve every local command, lifecycle lock, keyboard path, and missing/error state during visual migration.
- **Do** let transcript, summary, and notes own the space instead of wrapping every section in a card.
- **Do** verify every route at the native 1100×700 window and at the supported minimum size, in both light and dark.

### Don't:

- **Don't** use cool gray or blue-gray neutrals; the palette is warm throughout.
- **Don't** reintroduce the retired golden-amber accent or the navy-rail two-world system.
- **Don't** spread the Shin-kai accent onto labels, eyebrows, or decoration; do not use the heading ink interactively.
- **Don't** build generic AI dashboards with oversized greetings, equal-weight card grids, decorative gradients, fake metrics, fake progress, or invented assistant states.
- **Don't** use gradient text, glassmorphism, colored side-stripe borders, nested cards, or permanent decorative shadows.
- **Don't** add a visual field, badge, progress value, citation, or status that lacks an authoritative local contract.
