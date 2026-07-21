# Liquid Glass adoption (Marginalia, macOS 26)

**Decision (owner, 2026-07-20):** adopt macOS 26 **Liquid Glass** (`glassEffect`) in the product. This revises BRAND.md §4/§9, which previously permitted only stock materials and banned "glassmorphism of our own". Rationale: `glassEffect` is *Apple's own stock system material/API* — not hand-rolled glassmorphism — so it fits the "stock system materials only" spirit while giving the app a current macOS 26 look.

## Rules (add to BRAND.md §4 + §9; keep the calm/flat ethos)
- **Chrome/action layer only.** Glass lives on the elevated/navigation layer: the sidebar, the toolbar/title-bar chrome, floating controls, the primary/recording action buttons, and the notch HUD. **Never on content** — transcript, summary, and notes stay on opaque paper (content-owns-canvas, §3). Glass over reading content is banned.
- **Flat by default still holds.** Glass is the exception for the elevated layer, not a texture applied everywhere. Cards/rows/fields stay flat Marginalia surfaces.
- **Accent-tinted glass is a Signal.** `.glassEffect(.regular.tint(accent))` is reserved for THE primary action (and recording-red glass for live capture) — one per view, counts against the ≤8% budget. Neutral `.regular` (untinted) glass for passive chrome (sidebar, toolbar).
- **Respect Reduce Transparency.** The system degrades `glassEffect` to an opaque material automatically; do not fight it. (No manual guard needed, but don't layer our own translucency on top.)
- **Two inks unchanged.** Glass changes the *surface*, not the color system — labels on tinted glass follow the on-fill rule (`.canvas` paper).

## Surfaces (v1)
1. **Primary + recording buttons → Liquid Glass.** In `MarginaliaButtonStyle.makeBody`, render the `.primary` and `.recording` roles with `.glassEffect(.regular.tint(<fill role>).interactive(), in: Capsule())` instead of the solid `RoundedRectangle` fill (label stays `.canvas`; keep the 6pt-radius shape via a `RoundedRectangle` for the glass shape to match the control radius, or a Capsule — pick what reads best). `.secondary`/`.quiet` stay FLAT (tonal/text — they're not the signal). The `MarginaliaButtonSpec.fill` role becomes the glass *tint* for filled roles; parity tests unchanged (still assert `.accent`/`.recordingRed`).
2. **Sidebar rail → system glass.** Replace the `.elevated` rail backgrounds (from the review fix) with a stock translucent material so the rail reads as the macOS 26 sidebar: prefer `.background(.regularMaterial)` for the broad rail region (Apple uses the sidebar material for large nav areas; `glassEffect` is for discrete elements). This still satisfies the two-world separation (§10) — better than the flat `.elevated`.
3. **Toolbar / unified title bar** → the frameless unified toolbar already floats; ensure it shows the system glass (it does by default with `.windowStyle(.hiddenTitleBar)` + unified toolbar — confirm nothing opaque is painted over it at the top edge).
4. **Design Gallery** → flip the "macOS 26 Liquid Glass" section caption from "NOT currently adopted" to "adopted in the primary action + sidebar chrome"; keep the eval demos.

## Brand doc + tests
- BRAND.md §4 + §9: add the rules above; change the "don't build glassmorphism" line to "don't hand-roll glassmorphism — use Apple's Liquid Glass (`glassEffect`) on the chrome/action layer only".
- No token changes (glass is a surface treatment, not a color). Parity tests unaffected.
- If a spec field is added to record "filled roles render as glass", add a matching parity assertion; otherwise leave the button parity tests as-is.

## Out of scope (v1)
Content-area glass (banned), per-row glass, glass on cards/fields. The notch sidecar already uses `.ultraThinMaterial` — leave it; a later pass can move it to `glassEffect`.
