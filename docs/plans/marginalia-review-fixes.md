# Marginalia design-review fixes (Fable review, 2026-07-20)

Actioning all 20 findings from the Fable design review of the native `Ari` app vs `brand/BRAND.md`. Split into **Wave A** (AriKit + brand docs/tokens foundation) and **Wave B** (app screens, depends on A's new tokens).

## Brand-owner decisions taken (record)
- **Add `error` color role** — palette had no error color, forcing recording-red misuse (finding 4). New warm oxblood, distinct from recording-red. Tokens: light `#9A3327`, dark `#EB9A8E`.
- **Add `recordingRedPressed`** — record button had no press feedback (finding 19). Tokens: light `#A62B22`, dark `#E85548`.
- **Fixed-pt SF sanctioned on macOS** (finding 9) — amend BRAND §5; iOS Lite must revisit for Dynamic Type. (Lower risk than rewrapping every font.)
- **Codify `.canvas` on-fill label convention** (open Q2) — BRAND §4/§10.
- **Liquid Glass: deferred** (open Q4) — gallery keeps the eval demo; not adopted in product. Sidebar grounding uses `.elevated`, not glass.
- **Name → "Ari Meetings"** (finding 13) — match brand doc. Flagged for owner veto (CLAUDE.md uses "Ari Meeting").

## Wave A — AriKit + brand/tokens + BRAND.md (must stay in lockstep; parity tests enforce)
- **#4a** Add `error` role: `brand/tokens.json` (modes.light/dark), `MarginaliaColor.swift` (enum case, tokens struct + `hex(for:)`, `MarginaliaColorTokenSource.light/.dark`, `MarginaliaPalette` field + init + subscript), `MarginaliaTokenParityTests`, BRAND.md §4 role table.
- **#19** Add `recordingRedPressed` role (same lockstep set); set `.recording` button spec `pressed: .recordingRedPressed`.
- **#1b** Fix the false comment in `MarginaliaToggleRow.swift:5` (claims a root `.tint` exists — it doesn't yet; Wave B adds it).
- **#11** Button label font `.callout` → `.body` in `MarginaliaButtonStyle.makeBody` (ramp assigns Body 14 to controls).
- **#12** Apply `.textCase(.uppercase)` in `marginaliaTextStyle(_:in:...)` when `style.spec.isUppercase` (caption eyebrows) — fixes inconsistent eyebrow casing globally. De-uppercase hand-shouted source strings where trivial.
- **#8** Reduce-Motion gated motion helper: `MarginaliaMotion.animation(_:reduceMotion:) -> Animation?` (nil under reduce motion) + a `View.marginaliaAnimation` convenience reading the environment.
- **#20** Add on-fill contrast assertions (canvas-on-accent, canvas-on-recordingRed, canvas-on-success, inkSecondary-on-elevated) — new `MarginaliaContrastTests` or extend the token parity suite.
- **Docs:** BRAND.md §5 (sanction fixed-pt SF on macOS), §4/§10 (codify `.canvas` on-fill label), §6 (allow `inkSecondary` for placeholder/disabled mark states).

## Wave B — app screens (Ari/UI)
- **#1a** `.tint(Color.marginalia(.accent, in: scheme))` at the app UI root (`RootSplitView`) — closes the system-blue leak on stock controls.
- **#2 / #3** Rename "Start recording"/"Open recorder" → **"New meeting"** on both surfaces; demote the Home card button `.primary` → `.secondary` (sidebar keeps the one primary).
- **#4b / #5** Wire error text to the new `.error` role in `StateContainer`, `HomeView`, `SidebarView`; rewrite "Something went wrong" → decisive copy surfacing the actual failure.
- **#6** Sidebar backgrounds `.canvas` → `.elevated` (restore rail↔canvas two-world separation).
- **#7** Home hero rewrite: largest type names the work (page title / today), not a marketing tagline; remove the decorative "PRIVATE BY DESIGN" card (keep real library counts).
- **#10** Mic icons accent → `.inkSecondary` (HomeView capture card + recent rows).
- **#13** Wordmark "Ari Meeting" → "Ari Meetings".
- **#14** Settings/About inert rows: render explicitly disabled.
- **#15** Placeholder mark `.hairline` → `.inkSecondary` (`RootSplitView`).
- **#16** Rewrite placeholder copy in literate-plain voice (`RootSplitView`).
- **#17** Remove text "→" arrows from button labels (HomeView).
- **#18** Add `.accessibilityAddTraits(.isSelected)` to the selected sidebar row.
