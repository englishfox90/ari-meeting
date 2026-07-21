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

---

# v2 (2026-07-21) — audit against Apple's "Adopting Liquid Glass" + the standards for new pages

Audited the app against https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass. v1 was already correct on: standard components (stock `NavigationSplitView`, no custom sidebar background), the floating unified title bar, tinted-glass primary/recording buttons with `.canvas` on-fill labels, glass confined to the chrome/action layer ("avoid overusing"), and letting Reduce Transparency degrade the material. v2 closed the gaps below and locked in the standards.

## v2 changes (shipped)

1. **Glass controls take the system capsule.** `MarginaliaButtonStyle` glass roles (`.primary`/`.recording`) render in `Capsule()` — macOS 26 controls adopt rounder forms concentric with window corners. Flat roles (`.secondary`/`.quiet`) keep the brand 6 pt control radius; the split is deliberate: system-material controls follow the system's curvature, flat Marginalia surfaces follow brand tokens.
2. **Audio transport → floating glass.** `AudioPlayerBar` is a neutral `.regular` glass capsule placed via `.safeAreaInset(edge: .bottom)` in `MeetingDetailView`, so content scrolls beneath it and the glass keeps it legible (the article's "optimize for legibility when content scrolls beneath controls"). It replaced an opaque `.elevated` band inside the layout VStack.
3. **Ambient canvas wash.** `MarginaliaCanvasWash` (AriKit DesignSystem) — a gentle diagonal `.canvas` → `.elevated` gradient — is the window-content ground on every page (Home, list scaffolds, detail, placeholders), replacing flat `.canvas`. Flat one-color grounds make glass read as an opaque panel; the wash gives the sidebar/toolbar glass tonal variation to refract. This is the ONE sanctioned gradient in Marginalia (owner decision 2026-07-21, revising BRAND.md §4 "no gradients"); it uses only the two existing ground tokens, so no new contrast surface exists. `List`-based screens pair it with `.scrollContentBackground(.hidden)`.
4. **Scroll edge effect on Home.** `.scrollEdgeEffectStyle(.soft, for: .top)` keeps the header legible scrolling under the floating title-bar chrome.
5. **Gallery: stock presentations demo.** Menus/popovers demoed live in the Design Gallery materials section as automatic glass.

## Standards for new pages (carry forward — checklist)

Every new screen/component follows these; they are the durable output of the v2 audit.

- **Stock first.** Use standard SwiftUI components (`NavigationSplitView`, `List`, `Menu`, `.sheet`, `.popover`, `.searchable`-style patterns, stock toolbars). They pick up Liquid Glass, scroll edge effects, and accessibility degradation automatically. Custom chrome must earn its existence.
- **Modals & dropdowns: stock presentation, zero custom backgrounds.** Sheets, popovers, menus, and pickers get glass from the system. Never paint a background, material, or visual-effect view onto a presented surface — that's exactly the "audit the backgrounds of sheets and popovers" failure in Apple's article. Content *inside* a sheet may use Marginalia text/fields as usual.
- **Nav bar / title bar: never paint over it.** The unified title bar and toolbar show system glass; nothing opaque may be drawn at the top edge, and toolbar items use stock `ToolbarItem`(+`ToolbarSpacer` for grouping). Hide a toolbar item by hiding the *item*, not its view. Icons (SF Symbols) over text in toolbars; every icon gets an accessibility label; don't mix text and icons within one shared-background group.
- **Page ground = `MarginaliaCanvasWash`,** not flat `.canvas` (and not any other gradient — this is the single exception). Lists over it use `.scrollContentBackground(.hidden)`.
- **Content layer stays paper.** Transcript, summary, notes, cards, rows, fields: opaque Marginalia surfaces, hairline strokes, brand radii (6/10/14). Glass never sits under or over reading content.
- **Chrome/action layer may be glass, sparingly.** Floating controls and bars: neutral `.glassEffect(.regular, in: Capsule())`, placed with `.safeAreaInset` so content scrolls beneath. Tinted glass (`.tint(accent)` / recording red + `.interactive()`) is THE primary action only — one per view, inside the ≤ 8 % Signal budget, label in `.canvas`.
- **Glass shapes are capsules/concentric.** Custom glass takes `Capsule()` (or a shape concentric with its container for corner-nested elements); flat controls keep brand radii.
- **Multiple custom glass elements near each other share one `GlassEffectContainer`** (rendering cost + fluid morphing). With the one-Signal rule this should be rare.
- **Scrolling under bars:** content that scrolls beneath any bar/chrome relies on the system scroll edge effect (`.scrollEdgeEffectStyle(.soft, for: .top)` for custom ScrollViews under the floating title bar); never fake it with an opaque strip.
- **Stock `Section` headers use sentence case** (macOS 26 renders section headers as-given, title-style — no more automatic all-caps). The uppercase eyebrow (`SectionHeader` + caption tracking) remains a deliberate brand device for the hand-built rail and gallery only; never feed pre-uppercased strings to stock `List`/`Form` sections.
- **Respect the settings.** Reduce Transparency/Reduce Motion degrade glass and morphing — never counteract; test both, plus light/dark, before calling a page done.
- **Windows resize arbitrarily.** No fixed-size assumptions; split views + safe areas handle reflow.

## Still open (v3 candidates)
- `ari-notch` HUD still on `.ultraThinMaterial` — migrate to `glassEffect` when the notch work is next touched.
- App icon: re-cut with Icon Composer layers (background paper field + ink gesture as separate layers) so it picks up system lighting/refraction and the dark/clear/tinted variants — currently a flat SVG composite (BRAND.md §6).
- Concentric-corner APIs for any future corner-nested chrome (none exists today).
