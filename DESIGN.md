---
name: Ari Meeting
description: A focused local meeting workspace for capture, notes, and recall, themed to the Arivo brand.
colors:
  canvas: "#F4F1EB"
  surface: "#FBFAF8"
  surface-subtle: "#ECE7DF"
  surface-strong: "#E1DACE"
  ink: "#1A2B4A"
  ink-muted: "#566276"
  ink-faint: "#8A8578"
  rail: "#EAE5DC"
  rail-hover: "#E2DCCF"
  rail-selected: "#FAECD6"
  rail-ink: "#1A2B4A"
  rail-muted: "#566276"
  accent: "#E8A020"
  accent-soft: "#FAECD6"
  success: "#2A6048"
  warning: "#B57817"
  danger: "#B04040"
  info: "#37699E"
  border: "#D9D3C9"
  border-strong: "#C9C2B4"
  dark-canvas: "#0D192B"
  dark-surface: "#17233B"
  dark-rail: "#0B1522"
  dark-ink: "#F1EDE4"
  dark-accent: "#EEA82F"
typography:
  display:
    fontFamily: "Space Grotesk, -apple-system, BlinkMacSystemFont, SF Pro Text, Segoe UI, sans-serif"
    fontSize: "32px"
    fontWeight: 650
    lineHeight: 1.08
    letterSpacing: "-0.03em"
  headline:
    fontFamily: "Space Grotesk, -apple-system, BlinkMacSystemFont, SF Pro Text, Segoe UI, sans-serif"
    fontSize: "24px"
    fontWeight: 650
    lineHeight: 1.15
    letterSpacing: "-0.02em"
  title:
    fontFamily: "Space Grotesk, -apple-system, BlinkMacSystemFont, SF Pro Text, Segoe UI, sans-serif"
    fontSize: "17px"
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: "-0.01em"
  body:
    fontFamily: "Space Grotesk, -apple-system, BlinkMacSystemFont, SF Pro Text, Segoe UI, sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.55
    letterSpacing: "normal"
  label:
    fontFamily: "Space Grotesk, -apple-system, BlinkMacSystemFont, SF Pro Text, Segoe UI, sans-serif"
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
    backgroundColor: "{colors.ink}"
    textColor: "{colors.surface}"
    typography: "{typography.body}"
    rounded: "{rounded.sm}"
    padding: "9px 14px"
    height: "36px"
  button-accent:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.ink}"
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
    textColor: "{colors.rail-ink}"
    typography: "{typography.body}"
    rounded: "{rounded.sm}"
    padding: "8px 10px"
    height: "36px"
---

# Design System: Ari Meeting

## Overview

**Creative North Star: "The Signal Desk"**

Ari Meeting should feel like a precise desktop workbench with the warmth of the Arivo brand. A warm cream canvas holds the meeting; a navy-inked rail holds tools and state. Navigation is compact, predictable, and low-chrome. Transcript, summary, notes, and local model feedback are allowed to breathe without being wrapped in a grid of decorative cards.

The visual signature comes from the Arivo palette — warm cream canvas, deep navy ink and structure, and a scarce golden Arivo Amber accent — set in Space Grotesk with tight geometry and unusually clear state language. It reads like a sharp product organization with taste, not a generic SaaS dashboard.

**Key Characteristics:**

- Warm cream canvas with a navy-inked utility rail (deep navy rail and canvas in dark mode).
- Restrained Arivo Amber reserved for recording, current AI work, and decisive selection.
- Flat-by-default surfaces separated by warm tone and one-pixel borders.
- Compact controls with generous reading width where content matters.
- State-driven motion only; no decorative page choreography.

## Colors

The palette is warm-neutral and high-contrast. Color is functional, scarce, and therefore meaningful. Every neutral is warm — cream, taupe, tan — never cool gray.

### Primary

- **Navy Ink (`#1A2B4A`):** primary actions, headings, critical text, and the structural rail.
- **Arivo Amber (`#E8A020`):** recording, active AI work, and rare signature emphasis. It must not become decoration.

### Secondary

- **Warm Cream Canvas (`#F4F1EB`):** the application background behind working surfaces (brand cream `#EDE8DF` family).
- **Card Surface (`#FBFAF8`):** transcript, summary, editor, dialog, and field surfaces — warm near-white.
- **Layer Neutrals:** warm hover, selected, recessed, and disabled differentiation (`surface-subtle`, `surface-strong`).

### Neutral

- **Muted Ink (`#566276`):** secondary descriptions and metadata (blue-gray).
- **Faint Ink (`#8A8578`):** placeholders and tertiary information only when contrast remains valid.
- **Structural Border (`#D9D3C9`):** one-pixel warm separation between adjacent functional regions.

### Dark Mode

Dark mode is navy-grounded, not a naive inversion: canvas `#0D192B`, card surface `#17233B`, rail `#0B1522`, ink becomes warm cream `#F1EDE4`, and the accent brightens slightly to `#EEA82F`. Contrast and the amber-for-state discipline are preserved on both grounds.

### Named Rules

**The Signal Rule.** Arivo Amber appears on no more than 8% of a screen. Use it only for recording, active local AI work, a current selection that needs immediate recognition, or the app icon.

**The Warm Neutral Rule.** Every neutral is warm (cream, taupe, tan). Never introduce cool gray or blue-gray fills; the amber-on-navy pairing is the signature, and warm creams keep it grounded.

**The Two-World Rule.** The rail and the canvas are both warm and separated by tone plus a one-pixel border: in light mode the rail is a deeper cream over a lighter cream canvas; in dark mode both go deep navy. Ink, primary actions, and structure are navy.

**The No Fake State Rule.** Semantic colors and progress treatments require authoritative application state and a text or icon label.

## Typography

**Display and Body Font:** **Space Grotesk**, bundled locally (`frontend/public/fonts/SpaceGrotesk-Variable.woff2`) so it renders offline. It is the Arivo brand face and is used for headings, titles, controls, labels, and long transcripts alike — geometric and clean with just enough personality.
**Label/Mono Font:** the native monospace stack (SF Mono → `ui-monospace`), reserved for timestamps, model identifiers, and technical values.

**Character:** Precise, calm, and slightly editorial. Hierarchy comes from confident weight, compact letter-spacing, and deliberate reading measures rather than oversized marketing copy.

### Hierarchy

- **Display** (650, 32px, 1.08): route-defining titles only; never a greeting that repeats the navigation context.
- **Headline** (650, 24px, 1.15): primary workspace sections and meeting titles.
- **Title** (600, 17px, 1.3): panels, dialogs, and high-value rows.
- **Body** (400, 14px, 1.55): controls and explanatory copy; long-form prose is capped at 72ch.
- **Label** (600, 12px, 0.02em): compact metadata and short section labels, normally sentence case; uppercase eyebrows use muted ink, not amber.
- **Mono** (500, 12px, 1.4): timestamps, model identifiers, file formats, and technical values.

### Named Rules

**The Product Voice Rule.** No marketing-scale greetings inside the desktop app. The largest type names the work currently open.

**The Reading Rule.** Transcript, summary, and notes use comfortable line-height and a readable measure even when surrounding controls remain dense.

## Elevation

The system is flat by default. Depth comes from tonal layering, one-pixel borders, and fixed panel boundaries. Shadows appear only on content that temporarily floats above the workspace: menus, tooltips, dialogs, and drag overlays.

### Shadow Vocabulary

- **Floating Control** (`0 8px 24px rgba(26, 43, 74, 0.10)`): popovers, menus, and compact floating controls.
- **Dialog** (`0 24px 64px rgba(26, 43, 74, 0.18)`): blocking dialogs and recovery/import overlays.
- **Focus Halo** (`0 0 0 3px rgba(232, 160, 32, 0.18)`): keyboard focus paired with a solid amber outline.
- **Amber Glow** (`radial-gradient(ellipse at 70% 30%, rgba(232, 160, 32, 0.14), transparent 60%)`): optional low-opacity warmth behind hero/recording surfaces, echoing the logo arc.

### Named Rules

**The Flat Workspace Rule.** Static content surfaces do not float. If every region casts a shadow, the hierarchy has failed.

**The State Lift Rule.** Elevation may respond to hover, drag, menu, or modal state; it may not be permanent decoration.

## Components

Components are compact and familiar. Their personality comes from precision and state clarity rather than unusual affordances.

### Buttons

- **Shape:** compact rectangular controls with gently softened corners (6px).
- **Primary:** Navy Ink fill, warm-surface text, 36px height. One primary action per screen.
- **Accent:** Arivo Amber only for recording or active AI operations. Pair filled amber with Navy Ink text for contrast.
- **Hover / Focus:** tonal shift in 180ms; keyboard focus uses a solid amber outline and soft halo.
- **Secondary / Ghost:** Card Surface with one-pixel border, or transparent when placed in a toolbar.

### Chips

- **Style:** small tonal labels with 6px corners, never decorative pills by default.
- **State:** semantic icon plus text. A selected filter may use Accent Soft with a dark-amber label; the active recording chip is the one place a solid amber fill is welcome.

### Cards / Containers

- **Corner Style:** 10px only for independent bounded objects; continuous workspace regions remain square or 4px.
- **Background:** Card Surface or a named warm layer neutral.
- **Shadow Strategy:** flat at rest.
- **Border:** one-pixel Structural Border when adjacent tone is insufficient.
- **Internal Padding:** 16px compact, 24px reading, 32px major workspace.

### Inputs / Fields

- **Style:** Card Surface, one-pixel border, 6px corners, 36px standard height.
- **Focus:** Border becomes Arivo Amber and receives the Focus Halo.
- **Error / Disabled:** error includes text and icon; disabled lowers contrast without hiding the control's label.

### Navigation

The rail uses muted navy labels on warm cream at rest (cream labels on deep navy in dark mode), a quiet tonal hover layer, and a clearly differentiated selected row. The Arivo wordmark sits at the top of the rail (gray on light, white on dark) above the "Ari Meeting" product label. The persistent shell uses the app's structural glyphs (`MeetilyGlyph`) at 16–18px with a consistent 1.45px rounded stroke; descriptive content actions may use the established semantic icon library. The recording control is separated from route navigation and uses Arivo Amber only when it needs to dominate.

### Meeting Workspace

The meeting title and authoritative date establish context. Summary is the first reading surface when present. Transcript remains immediately discoverable and virtualized. Tools live in compact bars or inspectors, not inside repeated nested cards.

## Do's and Don'ts

### Do:

- **Do** use the warm cream canvas and navy rail as the primary compositional structure.
- **Do** keep Arivo Amber scarce and tied to real recording, AI, or selection state.
- **Do** keep every neutral warm — cream, taupe, tan.
- **Do** use 4/8/12/16/24/32/40/48 spacing tokens and 6/10/14px radii only.
- **Do** preserve every local command, lifecycle lock, keyboard path, and missing/error state during visual migration.
- **Do** let transcript, summary, and notes own the space instead of wrapping every section in a card.
- **Do** verify every route at the native 1100×700 window and at the supported minimum size, in both light and dark.

### Don't:

- **Don't** use cool gray or blue-gray neutrals; the palette is warm throughout.
- **Don't** use upstream Meetily's mixed utility-screen styling, hard-coded gray/blue controls, or form-first hierarchy.
- **Don't** spread Arivo Amber onto labels, eyebrows, or decoration — uppercase labels use muted ink.
- **Don't** build generic AI dashboards with oversized greetings, equal-weight card grids, decorative gradients, fake metrics, fake progress, or invented assistant states.
- **Don't** use gradient text, glassmorphism, colored side-stripe borders, nested cards, or permanent decorative shadows.
- **Don't** add a visual field, badge, progress value, citation, or status that lacks an authoritative local contract.
