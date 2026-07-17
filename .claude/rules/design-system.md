# Rule: Design System ("Signal Desk")

The design language is **Signal Desk**, themed to the **Arivo brand**: focused, calm, exact. Warm cream canvas + navy-inked rail, sparing golden-amber accent. The brand personality is "focused / calm / exact" — never loud, never playful-for-its-own-sake. Every neutral is warm (cream, taupe, tan), never cool gray.

## Source of truth is load-bearing

`DESIGN.json` and `DESIGN.md` (repo root) define the tokens and rules. **`frontend/tests/lib/visual-system.test.mjs` reads them and asserts the implemented UI matches.** Consequences:

- If you change a color/type/spacing token in `frontend/src/app/globals.css` or `tailwind.config.js`, update `DESIGN.json`/`DESIGN.md` in lockstep (or vice versa) — otherwise the visual-system test fails.
- `DESIGN.json` is the machine-readable token source; treat it as canonical.

## Core rules (from DESIGN.md)

- **Signal Rule** — the accent (Arivo Amber, `#E8A020`) covers **≤ 8%** of any screen. It signals the one thing that matters (recording, active AI, selection), not decoration. Amber never goes on labels/eyebrows.
- **Two-World Rule** — a clear visual separation between the navy-inked rail and the warm cream content canvas (both go deep navy in dark mode); separated by warm tone + a one-pixel border.
- **No-Fake-State (absolute)** — never invent metrics, progress bars, counts, timestamps, or citations that aren't backed by real data. Empty/loading/error states must be honest. This aligns with the backend's "never invent citations" recall invariant.
- **Flat by default** — minimal shadows/borders; rely on spacing and type hierarchy.
- **Typography** — **Space Grotesk** (Arivo brand face), bundled locally at `frontend/public/fonts/SpaceGrotesk-Variable.woff2` for offline use, with the native `-apple-system` stack as fallback. Uppercase eyebrows/labels use muted ink, not amber.

## Tokens (see DESIGN.json for exact values)

- Spacing scale: 4 / 8 / 12 / 16 / 24 / 32 / 40 / 48
- Radii: 6 / 10 / 14 px
- Accessibility: **WCAG 2.2 AA**
- Default window target: ~1100×700

## Implementation

- Tailwind 3.4, dark mode via `class` strategy. Authoritative config is `tailwind.config.js` (NOT `.ts`).
- Use shadcn/ui primitives in `src/components/ui/`; compose with `cn()`.
- Colors are HSL CSS variables in `globals.css` — reference tokens, never hardcode.
