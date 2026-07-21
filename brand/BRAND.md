# Ari Meetings — Brand & Design System ("Marginalia")

**Status:** Adopted 2026-07-16 for the SwiftUI era. Canonical.
**Scope:** This document + `tokens.json` + `assets/` define the brand for the native SwiftUI frontend.
**Relationship to `DESIGN.md` / `DESIGN.json`:** those repo-root files are the load-bearing test fixtures for the **outgoing (frozen) Tauri app** (`frontend/tests/lib/visual-system.test.mjs`). As of **2026-07-16** the Tauri app was rebranded to Marginalia ahead of the Swift rewrite (color scheme, Bricolage Grotesque, and the Dictation mark/icons), so `DESIGN.*` now describe *Marginalia as applied to the Tauri app* and are kept in lockstep with `frontend/src/app/globals.css`. This file (`BRAND.md` + `tokens.json` + `assets/`) remains **canonical**; on any conflict, BRAND.md wins. Don't fork the palette — derive `DESIGN.*` from these tokens, never the reverse. (The former "do not reconcile the two" rule is retired by this decision.)

---

## 1. Brand story & positioning

**Ari Meetings** is a private, single-user, Apple-native meeting-intelligence tool — macOS today, with a mobile ("lite") companion planned after the Swift migration completes (same feature set minus speaker identification; see `plans/swift-migration-plan.md`, Phase 6). It records and transcribes meetings and writes summaries that know who is in the room, who owns the meeting, and what kind of meeting it is. This design system (Marginalia) is the go-forward brand for **every** Ari surface — Mac and mobile alike.

**The promise:** Ari exists so you never drop a commitment. Meetings are where promises are made — and where they get lost. Ari keeps a connected record of the recurring people and recurring formats in your working life, captures what was promised and by whom, and surfaces it when it matters again. **The record that remembers your people.** The instrument is the means; the kept commitment is the point.

The brand story is a lineage: **pen → keyboard → voice.** But the pen's job was never recording — it was *thinking*. A margin note is a choice about what matters; writing was how a careful person reflected on what they'd heard. Recording is the easy part, and machines took it over long ago. The pen's real work — reflection, selecting what counts, connecting it to the people involved — is what Ari's summaries and context do now. **The summary is the marginalia.** The visual system is built from that story: paper grounds, two inks, hand-drawn gesture, a written letterform that becomes a soundwave.

*Structural debt, honestly held:* the name Marginalia should eventually be earned by the product itself — the user's own margin on the record. Annotation on transcripts is a natural product direction (the app already ships a rich-text notes editor, so the seam exists). This is a direction, not a shipped promise; don't market it until it's real.

**Personality:** calm, precise, literate — *the notebook that listens.* Never loud, never chirpy, never salesy. Ari is a working instrument in a private study, not a SaaS dashboard.

**Positioning:** off-the-shelf transcription tools treat every meeting as an anonymous, isolated event. Ari treats meetings as a connected record of recurring people and recurring formats. The brand must always feel like a *record* — considered, permanent, trustworthy — not a feed.

### What stays local

Plain words, because this is brand: **everything stays on the Mac.** Audio, transcripts, summaries, speaker profiles, and calendar context live in a local SQLite database and local files under `~/Library/Application Support/` (plus rolling logs under `~/Library/Logs/`). Transcription and speaker identification run on-device. Nothing leaves the machine unless the user explicitly configures a cloud summary provider with their own API key — and then only transcript text is sent to that provider, nothing else. There is no telemetry (analytics were removed 2026-07-14 and must not return), no accounts, no sync, and no other outbound requests. Any copy that describes privacy uses this same operational register — what goes where — never trust-us adjectives.

## 2. Voice & tone

Ari writes the way a careful notebook reads: **literate but plain.** Short declarative sentences. Concrete nouns. No exclamation marks, no mascot energy, no fake urgency, no apology theater.

**Honesty is the voice.** The No-Fake-State rule (§3) is not just a UI rule — it is how Ari speaks. Ari never claims to know something it doesn't, never shows progress it isn't making, and never invents a citation. When Ari is uncertain, it says so in plain words.

Register rules:

- Sentence case everywhere, including buttons and headings.
- Active voice; a control says exactly what happens ("Save summary", not "Submit").
- An action keeps its name through the flow ("Record" → "Recording" → "Recorded").
- Numbers are exact or absent — never "a few", never rounded theatrics.
- No first-person plural marketing ("we're excited"). Ari has no "we".

### Copy examples

| Moment | Do | Don't |
|---|---|---|
| Empty meeting list | "No meetings yet. Record one, or import an audio file." | "Nothing here yet! 🎉 Let's get you started on your meeting journey!" |
| Transcription error | "Transcription stopped at 12:41 — the model ran out of memory. The audio up to that point is saved. Retrying with the smaller model is recommended." (primary action button: "Retry with smaller model") | "Oops! Something went wrong. Please try again." — or a diffident "Retry…?" with no recommendation. Errors are decisive: when Ari knows the best recovery, it says so. |
| Recording consent prompt | "Record this meeting? Everyone on the call should know they're being recorded." | "Start capturing insights now!" |
| Summary while processing | "Summary in progress. The transcript is ready to read." | A progress bar with an invented percentage — or literary flourish ("Writing the summary…"). Plain instruction beats atmosphere. |
| Ask Meetings, no answer found | "Nothing in your meetings answers that. Nearest matches are listed below." | A confident answer with fabricated sources. |

## 3. Principles carried over

These survive the rebrand verbatim; they are the constitution.

1. **No-Fake-State (absolute).** Never invent metrics, progress values, counts, timestamps, or citations that aren't backed by real application state. Empty, loading, and error states are honest. Aligns with the engine's `local_recall_tests` "never invent citations" invariant.
2. **The Signal Rule.** The interactive accent (Shin-kai) covers **≤ 8 %** of any screen and appears **only** on: selection, citations, links, and speaker names. Note: the Iron Gall *heading ink* (§4) is text, not accent — it is non-interactive, never signals state, and sits **outside** this budget.
3. **Content owns the canvas.** Transcript, summary, and notes breathe; no nested-card grids, no decorative chrome. Depth comes from system materials and hierarchy, not shadows.
4. **Consented recording.** Recording is always prompted, never silent. Recording red belongs to live capture and to nothing else.
5. **State-driven motion only.** Animation communicates recording, live transcription, processing, and transitions. It never decorates (§9).
6. **The transcript is the primary record, not a fallback.** For some users the transcript is how they attend the meeting at all. Transcription is access, not just convenience: the transcript is never buried behind the summary, never truncated for layout, and always fully keyboard- and screen-reader-navigable.

### Where the rules apply

- **Brand-wide, every surface:** the two inks · the voice · No-Fake-State · warm neutrals only (no cool grays) · sentence case. In marketing, No-Fake-State means screenshots and recordings show real product states — never staged, mocked, or composited as if real.
- **Product-only — "animate only real state":** governs the product UI. Marketing surfaces may use composed motion (launch film, draw-on logo) provided it stays calm and ink-like; a hand-drawn mark being written *is* on-brand motion.
- **Product-only — the ≤ 8 % Signal Rule:** an app-surface budget. On marketing pages the equivalent discipline is: **accent = interaction + citation only, one primary CTA visible per viewport.**

## 4. Color system — "two inks on paper"

Marginalia has warm paper grounds and **two inks**:

- **Iron Gall** (`#152C66`, blue-black) is the *writing* ink — heading and display text in light mode. It reads as "written in ink" against the charcoal body text: two inks on one page, the way a careful notebook actually looks. It is text only: never interactive, never a fill, never a state signal. In dark mode blue-black cannot survive honestly, so headings shift to an **ink-washed paper white** (`#E8EAF2`, a barely-blue cream) that keeps the two-ink distinction without faking a dark blue.
- **Shin-kai** (`#1B3A8C` light / `#7E9BE8` dark, named for the Iroshizuku "deep sea" bottle) is the *interactive* ink — the sole accent. If it's Shin-kai, you can act on it.

Recording red is a third, separate channel: it means live capture only and is never co-branded with the accent.

### Role table

Contrast ratios are WCAG 2.x, computed against the role's own ground (canvas unless noted).

| Role | Light | Dark | Contrast (L / D) | Use |
|---|---|---|---|---|
| Canvas | `#FAF8F5` | `#211E1B` | — | Window background. Porcelain paper / warm espresso. |
| Elevated / sidebar | `#F1EDE6` | `#2B2723` | — | Sidebar ground (under system sidebar material), grouped regions. |
| Surface / card | `#FFFFFF` | `#2D2925` | — | Summary card, fields, popovers. |
| Ink (body text) | `#2B2620` | `#EDE8E1` | 14.1:1 / 12.9:1 | Body copy, controls. Warm charcoal — never pure black/white. |
| Heading ink (Iron Gall) | `#152C66` | `#E8EAF2` | 12.5:1 / 13.8:1 | Headings/display text only. The "second ink". Non-interactive. |
| Secondary ink | `#6F6759` | `#A89F92` | 5.3:1 / 6.4:1 | Metadata, descriptions. AA-compliant at any text size in both modes. Component guidance: use for supporting text, never for the only copy of critical information (times, owners, errors) — that's an information-hierarchy rule, not a contrast workaround. |
| Hairline | `#E6E1D8` | `#3E3933` | — | One-pixel separations. |
| Accent (Shin-kai) | `#1B3A8C` | `#7E9BE8` | 9.8:1 / 6.1:1 | Selection, citations, links, speaker names. ≤ 8 % of any screen. Solid Shin-kai **fill** is reserved for *the* primary action — one per view/viewport; all other accent use is stroke, text, or wash. |
| Accent hover | `#16317A` | `#92ABEC` | — | Pointer hover on accent-colored interactive text/controls. |
| Accent pressed | `#122763` | `#6B89DE` | — | Active/pressed. |
| Selection wash | `rgba(27,58,140,0.11)` † | `rgba(126,155,232,0.16)` | — | Selected row/​chip background; pairs with accent text. † Tune-in-build: 11 % may be invisible on bright displays — test 16–18 % alpha in the real app on a sunlit screen before locking. |
| Recording red | `#C6362C` | `#FF6B5E` | 5.0:1 / 6.2:1 | Live capture only. |
| Recording red pressed | `#A62B22` | `#E85548` | — | Record-button pressed/active state only. |
| Success | `#42794F` | `#8CC2A0` | 4.6:1 / 8.9:1 | Saved, complete, verified. Always with a text/icon label. |
| Error | `#9A3327` | `#EB9A8E` | — | Warm error ink, distinct from recording red so an error state is never mistaken for live capture. Error text and banners only; always paired with a symbol (never color alone). |

Rules:

- Every neutral is warm (paper, espresso, charcoal); never introduce a cool gray.
- Semantic colors (red, green) always ship with a text or icon label — color is never the only signal.
- No gradients, no glassmorphism of our own — translucency comes only from stock macOS materials. **One sanctioned exception (owner decision, 2026-07-21): the ambient canvas wash** — `MarginaliaCanvasWash`, a gentle diagonal Canvas → Elevated gradient used as the window-content ground so the Liquid Glass sidebar/toolbar has tonal variation to refract (a flat one-color ground makes glass read as an opaque panel). It is built only from the two existing ground tokens, lives only on the page ground (never on cards, fields, or controls), and licenses no other gradient.
- **Liquid Glass (macOS 26, decided 2026-07-20):** `glassEffect` is Apple's own stock system material/API, so it satisfies the stock-materials-only rule above and is adopted on the **chrome/action layer only** — the sidebar, toolbar/title-bar chrome, floating controls, the primary/recording action buttons, and the notch HUD. **Never on content** — transcript, summary, and notes stay on opaque paper (content-owns-canvas). Accent-tinted glass (`.glassEffect(.regular.tint(accent))`) is reserved for THE primary action (and recording-red glass for live capture) — one per view, counts against the ≤ 8 % Signal budget; neutral untinted `.regular` glass is for passive chrome (sidebar, toolbar). Flat-by-default still holds elsewhere — cards/rows/fields stay flat Marginalia surfaces. The system degrades `glassEffect` to an opaque material automatically under Reduce Transparency; don't fight it or layer our own translucency on top. Glass changes the *surface*, not the color system — labels on tinted glass still follow the on-fill convention below. **v2 additions (2026-07-21, from Apple's "Adopting Liquid Glass" audit):** custom glass takes the system's **capsule** curvature (flat controls keep brand radii); floating glass bars sit in a `safeAreaInset` so content scrolls beneath them; **modals and dropdowns (sheets, popovers, menus) are always stock presentations with zero custom backgrounds** — the system supplies their glass; multiple custom glass elements near each other share one `GlassEffectContainer`. Full checklist: `docs/plans/liquid-glass-adoption.md` ("Standards for new pages").
- **On-fill label convention:** any filled control or badge (primary/recording buttons, success/recording badges) labels itself with **Canvas** (paper) — never Surface. Canvas is near-white in light mode and near-black in dark mode, so it stays high-contrast against a solid fill in *both* schemes. Surface resolves to warm espresso (`#2D2925`) in dark mode, which reads as muddy brown text on a light dark-mode fill (e.g. the dark-mode recording-red `#FF6B5E`) — never use it as an on-fill label.

## 5. Typography

Sans-only. Two families, three roles:

- **Bricolage Grotesque** — headings and display **only**, and only at **≥ 17 pt**. Below 17 pt its display cuts blur; titles under the floor use SF Pro Semibold instead. Weights used: 600 (SemiBold) and 700 (Bold). It keeps a grotesque lineage with the outgoing Space Grotesk while its ink traps carry the fountain-pen story. **Licensing/bundling:** SIL OFL — free to bundle in a commercial app. Self-host the `.ttf` in the app bundle (exactly as Space Grotesk was in the Tauri app), register under `Fonts provided by application` in Info.plist, load via `Font.custom("Bricolage Grotesque", size:)` (verify the exact PostScript names, e.g. `BricolageGrotesque-SemiBold`, from the shipped file).
- **SF Pro** (system) — all body, controls, labels, metadata; SF Pro Semibold stands in for headings below the 17 pt floor. Use stock text styles wherever possible so Dynamic Type and optical sizing (Text ≤ 19 pt / Display ≥ 20 pt) come free.
  - **Fixed-pt sizing is sanctioned on macOS** (brand-owner decision, 2026-07-20): the type ramp's SF Pro/SF Mono entries resolve via `Font.system(size:weight:design:)` at their exact declared point size, not `Font.system(.body)`/`relativeTo:` Dynamic Type. This is deliberate — the ramp's pt values are the spec, not a stand-in for a Dynamic-Type text style — and is lower-risk than rewrapping every font call. The **iOS "Lite" app must revisit this** for Dynamic Type support when it ships (Phase 6); macOS has no such obligation. Bricolage Grotesque keeps `relativeTo:` as-is (see `MarginaliaTypography.swift`) since headings do scale today.
- **SF Mono** — timecodes, model identifiers, and technical values only. Always `tabular-nums`.

### Type ramp

| Style | Face · weight | Size (pt) | Ink | Use |
|---|---|---|---|---|
| Display | Bricolage 700 | 32 | Heading ink | Route-defining titles only. Never a greeting — except Home's sanctioned owner greeting (see the product voice rule below). |
| Title 1 | Bricolage 700 | 24 | Heading ink | Meeting titles, primary workspace sections. |
| Title 2 | Bricolage 600 | 19 | Heading ink | Panel and dialog titles. |
| Headline | Bricolage 600 | 17 | Heading ink | High-value rows; the floor of the Bricolage range. |
| Subheadline | SF Pro Semibold | 15 | Body ink | Sub-17 pt headings; compact panel titles. |
| Body | SF Pro Text 400 | 14 | Body ink | Transcript, summary prose (max 72 ch measure), controls. |
| Callout | SF Pro Text 400 | 12 | Secondary ink | Explanations, metadata sentences. |
| Caption / label | SF Pro Text 600 | 11 | Secondary ink | Uppercase eyebrows (+0.07 em tracking). Never in accent or heading ink. |
| Timecode | SF Mono 500 | 12 | Body or accent | Timestamps, durations, model ids. Tabular numerals. |

Product voice rule: the largest type on screen names the work currently open — no marketing-scale greetings inside the app. **One sanctioned exception (owner decision, 2026-07-20): the Home screen's display title is a time-of-day greeting to the owner** ("Good morning, Paul") — a fixed deterministic list (morning/afternoon/evening/hello), never generated, addressed to a real name only (owner profile, else the macOS account name; no name → the phrase alone). Its two-ink rendering puts the greeting phrase in Shin-kai and the name in heading ink — a deliberate, Home-only exception to accent-is-interactive; it does not license accent on any other non-interactive text.

## 6. Mark & logo — the "Dictation" family (R2)

The mark is **one continuous hand-drawn gesture in one ink line**: a cursive lowercase "a" written without lifting the pen, whose exit stroke rises into a hand-drawn waveform — three irregular organic peaks, stroke weight tapering (8 → 2.8 in artwork units) as the pen lifts. The letter is the record; the run-out is the voice still speaking. It must never read as geometric bars.

### Roles (assigned — no deferrals)

| Role | Artwork | File |
|---|---|---|
| Menu bar & recording glyph (16 px) | **The signature flick** — the terminal wave alone. This role is owned: the flick *is* the small mark and *is* the recording-state glyph (animated from real audio level while capturing). | `assets/mark-16.svg` |
| Wordmark | **Full R2 gesture** + "Ari Meetings". Sidebar and title contexts. | `assets/wordmark.svg` |
| Full mark (≥ 32 px) | The complete Dictation gesture: about window, onboarding, README. Never scaled below 32 px — switch to the flick instead. | `assets/mark-full.svg` |
| Dock / app icon | **The mark itself** — the full R2 gesture in an icon-weight cut, on a porcelain paper field in the standard macOS squircle (22.37 % corner radius). Light: Iron Gall ink on porcelain. Dark: paper-white ink on espresso. The gesture spans ≈ 60 % of the field; at 32 px and below it switches to the simplified heavier cut (single-weight "a", run-out shortened to its first upturn). | `assets/app-icon.svg` |

*Explored, superseded:* **R3 "Ledger Hand"** (`assets/mark-fallback-ledger.svg`) was round 2's robustness candidate — a blunt-nib drawing whose small cut is the same artwork shortened. It is **retired from the live system** (the flick answered the small-size problem better); the asset is kept as design history only. Do not ship it or mix it with the Dictation family.

### Usage rules

- **Ink-only, single color.** The mark renders in exactly one color per instance: Shin-kai (preferred), heading/body ink, or paper-white on dark/photographic grounds. SVGs use `currentColor` — tint, don't edit. **Placeholder, disabled, and empty-state renderings** of the mark may additionally use **Secondary ink** — a fourth sanctioned option for a mark that is present but deliberately de-emphasized (e.g. an empty-library placeholder), not for any active/branded appearance.
- **Clear space:** keep a margin of at least the height of the "a" bowl (≈ 50 % of mark height) on all sides.
- **Minimum sizes:** full mark ≥ 32 px height; below that, switch to the 16 px cut (never scale the full mark down).
- **On dark:** use the dark-mode accent `#7E9BE8` or paper white `#EDE8E1`; never the light-mode `#1B3A8C` on dark grounds.
- **Misuse (never):** outline the strokes; apply gradients or shadows; recolor outside the two inks + paper white; stretch or skew; rotate; pair or intercut with geometric waveform bars (this was rejected in round 1); redraw the peaks evenly — irregularity is the point; enclose in a container shape that crops the run-out.

### App icon — the mark, one drawing everywhere

The app icon is the R2 "Dictation" mark itself — the written "a" and its waveform run-out. One drawing carries the brand from dock to menu bar to wordmark. Rendering spec:

- **Field:** standard macOS squircle (22.37 % corner radius), porcelain paper `#FAF8F5` in light; warm espresso `#211E1B` in the dark variant.
- **Ink:** Iron Gall `#152C66` on the light field; paper-white `#EDE8E1` on the dark field. No other colors, no gradients.
- **Icon cut:** stroke weights run a touch heavier than the wordmark cut (≈ 1.3×, tapering 10.5 → 4.2 in artwork units) so the gesture holds presence at dock scale; the gesture spans ≈ 60 % of the field, centered.
- **Small sizes:** at 32 px and below the icon switches to the simplified heavier cut — a single-weight "a" with the run-out shortened to its first upturn.
- **Artwork:** `assets/app-icon.svg` (icon-weight glyph, `currentColor` — composite onto the squircle field at export; export sizes 512/256/128/32/16).

## 7. Iconography & imagery

- **SF Symbols is the icon language.** No third-party icon set. Match symbol weight to the adjacent text weight (Regular with body, Semibold with headings) and use `.imageScale`/text-style-relative sizing so symbols track Dynamic Type.
- **Custom glyphs are allowed only for the mark family** — the full mark, the signature flick, and the flick-as-recording-glyph. Everything else is a stock symbol.
- **Texture & paper:** **skip texture entirely** — the warm palette carries the paper feeling on its own. No grain, fiber, or paper-image assets. Never skeuomorphic (no torn edges, no coffee stains, no ruled lines).
- **Imagery:** the product is UI-first; avoid stock photography. If illustration is ever needed it follows the mark's language: single-ink, hand-drawn line, pressure-modulated.

## 8. Motion

State-driven only. Motion answers "what is the system doing?", never "isn't this delightful?".

| Token | Duration | Easing | Use |
|---|---|---|---|
| instant | 120 ms | `cubic-bezier(0.23, 1, 0.32, 1)` | Press feedback, micro-state. |
| fast | 180 ms | same | Hover, selection, compact disclosure. |
| standard | 260 ms | same | Sidebar, dialog, and panel state changes. |

Sanctioned animated states: the recording pulse (flick glyph / red dot breathing at ~1.6 s), the live waveform while capturing, sync/processing indicators tied to real work. Respect **Reduce Motion**: pulses become static, transitions become fades. No page choreography, no parallax, no decorative springs.

## 9. Do's & Don'ts

| Do | Don't |
|---|---|
| Use warm paper grounds and the two-ink text system as the primary structure. | Introduce cool grays, pure black/white text, or a third ink. |
| Keep Shin-kai on selection, citations, links, speaker names — and count it against 8 %; reserve solid accent fill for the one primary action per view. | Put accent on labels, eyebrows, or decoration; fill anything but the primary action; use heading ink interactively. |
| Use stock SwiftUI materials, controls, and SF Symbols first. | Don't hand-roll glassmorphism — use Apple's Liquid Glass (`glassEffect`) on the chrome/action layer only. |
| Let transcript/summary/notes own the space at a 72 ch reading measure. | Wrap content in nested-card grids or decorative containers. |
| Ship honest empty/loading/error states with plain-language copy. | Invent progress, counts, citations, or chirpy filler ("Oops!"). |
| Animate only real state (recording, live transcription, sync). | Add decorative motion, permanent shadows, or attention-seeking pulses. |
| Use the 16 px cut below 32 px; tint marks via `currentColor`. | Scale the full mark tiny, outline it, gradient it, or pair it with geometric bars. |
| Keep recording red exclusive to live capture, always labeled. | Reuse red for errors-in-general or mix it with the accent on one element. |

## 10. SwiftUI mapping

Token names below match `tokens.json`; mirror them as **asset-catalog Color Sets** (with Any/Dark appearances) so light/dark switching is free.

- **Colors:** asset catalog names `Canvas`, `Elevated`, `Surface`, `InkBody`, `InkHeading`, `InkSecondary`, `Hairline`, `AccentShinKai` (+ `AccentHover`, `AccentPressed`), `SelectionWash`, `RecordingRed` (+ `RecordingRedPressed`), `Success`, `Error`. Set `AccentShinKai` as the app accent and apply `.tint(Color("AccentShinKai"))` at the app root; global tint IS the Signal Rule's delivery mechanism — do not hand-color controls.
- **On-fill labels:** any filled control/badge (primary/recording buttons, success/recording badges) labels itself with `Color("Canvas")`, never `Color("Surface")` — see §4's on-fill label convention rule.
- **Structure:** `NavigationSplitView` with the stock sidebar — the system applies the sidebar/Liquid Glass material; place `Elevated` only *behind* it, never replace the material. Content column on the ambient canvas wash (`MarginaliaCanvasWash`, the §4 exception — `List` screens add `.scrollContentBackground(.hidden)`); cards on `Surface` with `Hairline` strokes. Custom ScrollViews under the floating title bar take `.scrollEdgeEffectStyle(.soft, for: .top)`. Floating chrome (e.g. the audio transport) is a neutral `.glassEffect(.regular, in: Capsule())` in a bottom `safeAreaInset`. Sheets/popovers/menus: stock presentation, no custom backgrounds. New-page checklist: `docs/plans/liquid-glass-adoption.md`.
- **Typography:** `Font.custom("Bricolage Grotesque", size: 24, relativeTo: .title)` (use `relativeTo:` so Dynamic Type scales it; confirm PostScript names from the bundled TTF). Body/UI via stock styles (`.body`, `.callout`, `.caption`); sub-17 pt headings via `.system(.subheadline, weight: .semibold)`. Timecodes: `.system(.caption, design: .monospaced).monospacedDigit()`.
- **Heading ink:** apply `Color("InkHeading")` as `foregroundStyle` on heading text styles — a view-modifier seam (e.g. an `AriHeading()` ViewModifier) so the two-ink rule lives in one place.
- **Symbols:** SF Symbols with `.symbolRenderingMode(.monochrome)`; weight matched to adjacent text. Recording states may use `.symbolEffect(.pulse)` gated on real capture state and `accessibilityReduceMotion`.
- **Marks:** ship the SVGs' paths as template images (or SwiftUI `Shape`s for the animated flick); tint with `foregroundStyle`. The flick's recording animation drives per-peak scale from the live audio level — real signal, per No-Fake-State.
- **Motion:** `Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.12/0.18/0.26)`; wrap in a helper that returns `nil`/fades under Reduce Motion.
- **Spacing/radii:** spacing scale 4/8/12/16/24/32/40/48 pt; radii 6 (controls), 10 (cards), 14 (dialogs/windows-adjacent) — carried over from the Signal Desk discipline unchanged.

---

## 11. Marketing surfaces

The website, launch articles, social, email, and film speak the same language as the product. The rule-scope statement (§3) applies: real product states always; composed motion allowed; one primary CTA per viewport.

### Imagery

- Marketing pages are filled by: real product screenshots (true states only) · typographic compositions in the two inks · the mark family · line diagrams drawn in ink on paper in the SF-Symbols weight/stroke idiom.
- Screenshots sit on paper fields with hairline borders — never floating on white, never in device bezels or perspective mockups.
- Never: stock photography, illustration systems, 3D renders, texture assets.

### Asset kit

| Asset | Size | Spec |
|---|---|---|
| OG / share image | 1200×630 | Espresso or porcelain field; headline in Bricolage (that field's heading ink); flick or wordmark anchored to a corner; 72 px (6 %) margins; nothing else. |
| Social avatar | 400×400+ | The app-icon squircle composition; for circular crops center the mark at ≈ 55 % of the paper field. |
| Favicon | 16 / 32 / 180 | The simplified 32 px icon cut on the paper field; 180 px (apple-touch) may use the full icon cut. |
| Social banner | 1500×500 | Poster-template derived: field + one headline + flick; type stays inside the safe center 1200 px. |
| Square / story | 1080×1080 · 1080×1920 | Poster template recomposed vertically; headline ≤ 3 lines; wordmark bottom-left. |
| Email header | 600×200 | Wordmark on paper field exported **as an image** — email clients strip web fonts, so live email text renders in the system-stack fallback; wherever Bricolage matters in email it ships as an image with alt text. |

### Motion for marketing

- **The signature move — the draw-on mark:** the gesture writes itself (bowl, stem, run-out) in 600–900 ms with ink-like easing (the product's `cubic-bezier(0.23, 1, 0.32, 1)` family). It opens the launch film and the website hero.
- Calm rules: no parallax theater, no springs, nothing loops forever; one orchestrated moment per page; Reduce Motion honored on the web as in the app.

### URL & handle lockup

Wordmark + address, one pattern: the domain or handle set in SF Mono, secondary ink, baseline-aligned to the wordmark. Domain/handles are placeholders until final; the pattern is the spec.

### Web layout

Marketing pages compose on a 12-column grid inside a ~1100 px content measure; prose caps at 72 ch. Spacing and radii tokens (§10) apply unchanged.

## 12. Editorial system

Long-form articles and pages read like the product: two inks, generous measure, no decoration. **The brand does not use italics** — emphasis comes from weight and ink; blockquotes stay roman.

**Marketing display scale** (heroes, posters): 36 / 46 / 58 px, Bricolage 700.

| Element | Spec |
|---|---|
| Article H1 | Bricolage 700 · 34 px · heading ink |
| Article H2 | Bricolage 700 · 24 px · heading ink |
| Article H3 | Bricolage 600 · 19 px · heading ink |
| Body | SF stack 400 · 17 px / 1.65 · body ink · 72 ch |
| Blockquote | Body size, secondary ink, 2 px Shin-kai left rule, roman |
| Pull-quote | Bricolage 600 · 28 px · heading ink · ≤ 22 ch |
| Lists | Body spec; markers in secondary ink; no custom bullets |
| Caption | SF stack 400 · 13 px · secondary ink |
| Figure | Paper field + hairline border; screenshots per the imagery policy |

### Headlines — the house formula

Short declaratives, often two beats with a period pivot. Concrete nouns. No questions, no puns, no colon-with-hype.

- **Approved:** "The record that remembers your people." · "The meeting ends. The record remembers." · "The pen's job was never recording. It was thinking." · "Everything stays on the Mac."
- **Never:** "Supercharge your meetings: AI that never forgets!" · "What if your meetings could remember themselves?"

### Self-reference

The brand writes about Ari in the third person ("Ari records", "Ari keeps"). No "we", no byline persona. Articles are authored by the maker under their own name; product statements belong to Ari. The registers never mix inside a sentence.

## 13. Stress-tested

2026-07-16: the brand was pressure-tested by a six-persona panel. Verdict: **6/6 resonates** (several conditional — every condition is now folded into this document).

- **Dana (engineering manager):** "Resonates but unfinished — make me the protagonist: the record that remembers my people." → the story now claims the outcome (§1).
- **Viktor (privacy-skeptic staff engineer):** "Honest craft, not perfume — but tell me plainly what stays local." → the What-stays-local section (§1).
- **Mika (design-literate founder):** "Legitimate native Mac software. Commit to mark roles now." → mark roles assigned, R3 retired, texture dropped (§6, §7).
- **Sam (customer-success lead):** "Consent copy is perfect; show me the recording signal and claim the promise-keeping." → outcome promise added; the flick-as-recording-glyph role locked.
- **Ruth (low-vision ops director):** "Accessibility is in the bones — but 4.4:1 secondary ink is a documented weakness, not a fix." → secondary ink darkened to `#6F6759` (5.3:1, AA at any size); transcript-as-access principle added (§3.6, §4).
- **Elliott (fountain-pen journaler):** "Earned, not cosplay — but the pen's job was thinking. The summary is the marginalia." → lineage rewritten around reflection; annotation-as-marginalia recorded as product direction (§1).

*Design history: the three-concept exploration and the Marginalia deep-dive (ink study, mark rounds 1–2, type study) live as artifacts — see `brand/README.md`.*
