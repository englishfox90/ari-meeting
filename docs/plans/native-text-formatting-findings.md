# Step-1 findings: what the native macOS text affordances actually write

Investigated 2026-07-24 on macOS 26 / Xcode 26.6 (SDK `MacOSX26.5.sdk`) with a standalone SwiftUI
probe that mirrors Ari's attribute scope (a paragraph-scoped block attribute + `SwiftUIAttributes`)
but applies **no constraints**, so a native write survives unmodified and can be observed. The
probe drove the real code paths in-process — the exact `addFontTrait:` action the Font menu sends,
and synthesized ⌘B/⌘I `NSEvent`s through the responder chain — so no Accessibility grant was
involved. Probe source + raw logs: session scratchpad `NativeFormatProbe/`.

This closes R1 in `rich-summary-editor.md`.

## 1. The editor's backing view

`TextEditor(text: Binding<AttributedString>, selection:)` is backed by `AttributedPlatformTextView`
(an `NSTextView` subclass), with `isRichText = true`, `usesFontPanel = true`, `allowsUndo = true`.

## 2. The real context menu

Enumerated from `textView.menu(for:)`. The **Font** submenu and the selector each item sends:

| Item | Action | Target | Tag |
|------|--------|--------|-----|
| Show Fonts | `orderFrontFontPanel:` | `NSFontManager` | 0 |
| **Bold** | `addFontTrait:` | `NSFontManager` | 2 (`boldFontMask`) |
| **Italic** | `addFontTrait:` | `NSFontManager` | 1 (`italicFontMask`) |
| Underline | `underline:` | responder chain | 0 |
| Outline | `outline:` | responder chain | 0 |
| Highlight ▸ (7 colors) | `highlight:` | responder chain | 0 |
| Styles… | `orderFrontStylesPanel:` | `NSFontManager` | 0 |
| Show Colors | `orderFrontColorPanel:` | responder chain | 0 |
| Format… | `_showTextFormattingOptions:` | responder chain | 0 |

The rest of the menu: Look Up, Translate, Search With Google, Cut/Copy/Paste/Paste and Match Style,
Share, Writing Tools (Proofread / Rewrite), Spelling and Grammar, Substitutions.

Note there is **no Strikethrough** item in this menu; the non-grammar formatting items actually
present are Underline, Outline, and Highlight.

## 3. What native Bold/Italic write — the answer

**They replace `container.font`.** Nothing else.

- It is **not** a separate `fontWeight` attribute — `AttributeScopes.SwiftUIAttributes` declares no
  such key (verified against the SDK `.swiftinterface`: `font`, `foregroundColor`,
  `backgroundColor`, `strikethroughStyle`, `underlineStyle`, `kern`, `tracking`, `baselineOffset`,
  `alignment`, `lineHeight`, `adaptiveImageGlyph`, plus nested `accessibility` + `foundation`).
- It is **not** `\.inlinePresentationIntent` — observed `nil` before and after every native command.
- It is **not** `underlineStyle` / `strikethroughStyle` — both `nil` throughout.

The replacement `Font` is boxed over a **concrete resolved `NSFont`**, i.e.
`FontBox<Font.PlatformFontProvider>`, whereas every canonical Ari font is
`FontBox<Font.TextStyleProvider>`. Observed after Font ▸ Bold on body text:

```
SwiftUI.Font = Font(provider: SwiftUI.FontBox<SwiftUI.Font.PlatformFontProvider>)
NSFont       = ".SFNS-Semibold 13.00 pt."
```

Applying Italic on top accumulated the trait on the concrete font → `.SFNS-SemiboldItalic`.

## 4. Why it silently no-ops today

Value equality across the two box kinds is `false`:

```
Font(nsBold)    == Font.body.bold() → false
Font(nsRegular) == Font.body        → false
```

`SummaryCanonicalFont.coerce` matches only by value-equality against `SummaryFontVariant`, so the
native write matches nothing and falls through to `return SummaryFontVariant.base(for: kind)` —
the emphasis is stripped on the very next constraint pass. The probe reported
`canonical-match: NONE` for the natively-bolded run. Menu checkmark, no durable effect. Confirmed.

## 5. The recovery mechanism

macOS 26 adds `Font.resolve(in: Font.Context) -> Font.Resolved`, exposing `isBold`, `isItalic`,
`weight`, `pointSize`, `ctFont`. It **does** recover traits from platform-font-boxed fonts:

```
Font(nsRegular)    : isBold=false isItalic=false weight=0.0
Font(nsBold)       : isBold=true  isItalic=false weight=0.4
Font(nsItalic)     : isBold=false isItalic=true  weight=0.0
Font(nsBoldItalic) : isBold=true  isItalic=true  weight=0.4
```

`Font.Context` has no public initializer — it comes from
`EnvironmentValues.fontResolutionContext` (and `EnvironmentValues()` does have a public init).

## 6. Trap: an absolute `isBold` test is wrong

⚠️ **Correction:** an earlier pass of this document measured the *stock* `Font.body` / `Font.title2`
/ `Font.headline`. Ari's canonical bases are **not** those. Per `MarginaliaTypography.swift`:

| Kind | `SummaryFontVariant.base(for:)` resolves to |
|------|--------------------------------------------|
| `paragraph` / `bulletItem` / `numberedItem` | `Font.system(size: 14, weight: .regular)` |
| `heading` level ≤ 2 | `Font.custom("Bricolage Grotesque SemiBold", size: 19, relativeTo: .title2)` |
| `heading` level ≥ 3 | `Font.custom("Bricolage Grotesque SemiBold", size: 17, relativeTo: .headline)` |

Re-measured with the brand face **registered exactly as `AppFonts` does** (so these are the
shipping fonts):

```
ari body            : isBold=false isItalic=false weight=0.0  size=14
ari body.bold()     : isBold=true  isItalic=false weight=0.4  size=14
ari body.italic()   : isBold=false isItalic=true  weight=0.0  size=14

ari title2          : isBold=true  isItalic=false weight=0.3  size=19   ← already bold
ari title2.bold()   : isBold=true  isItalic=false weight=0.3  size=19   ← identical to base
ari title2.italic() : isBold=true  isItalic=false weight=0.3  size=19   ← identical to base

ari headline        : isBold=true  isItalic=false weight=0.3  size=17   ← already bold
ari headline.bold() : isBold=true  isItalic=false weight=0.3  size=17   ← identical to base
ari headline.ital() : isBold=true  isItalic=false weight=0.3  size=17   ← identical to base
```

Both heading families already resolve `isBold=true`. A naive `resolved.isBold ⇒ bold` would misread
every plain heading run as bold and wrap it in `**…**`. **Emphasis must be derived relative to the
resolution of the kind's own base font**, not absolutely.

The body family is clean on both axes, so body/list emphasis recovery is unambiguous.

## 7. Inherent limit: heading families carry NEITHER bold NOR italic

Stronger than previously stated, and it applies to **both** heading families and **both** axes. The
app registers the brand face as two *separate static families* ("Bricolage Grotesque SemiBold" /
"… Bold") with **no italic cut at all**, so `NSFontManager` has nothing to convert to:

```
Bricolage Grotesque SemiBold: base=…-SemiBold  bold=…-SemiBold  italic=…-SemiBold
Bricolage Grotesque Bold:     base=…-Bold      bold=…-Bold      italic=…-Bold
```

Consequences, all pre-existing and not introduced by this work:

- `SummaryFontVariant.bold(for: .heading(…))` and `.italic(for: .heading(…))` **render identically
  to base**. They remain distinct `Font` *values*, so Tier-1 value equality still tells them apart
  and `serialize` still emits `**…**` / `*…*` — the markdown is durable even though the glyphs
  don't change. The toolbar / ⌘B path on headings therefore still "works" in the round-trip sense.
- Native Font ▸ Bold/Italic on a heading is a **no-op at the AppKit level** — nothing to recover.
- Edge case worth documenting: if AppKit swaps the box to `PlatformFontProvider` while returning an
  identical face, Tier-1 equality is lost and a heading run that *was* bold would flatten to base.
  That is today's behaviour too (it already flattens), so this is a documented limitation rather
  than a regression.

Contrast the body family, where bold and italic both convert cleanly
(`.SFNS-Regular` → `.SFNS-Semibold` / `.SFNS-SemiboldItalic`) and recovery works fully.

## 8. ⌘B / ⌘I are not bound at all in Ari

`Ari/App/AriApp.swift` declares no `.commands` — there is no Format menu in the app's menu bar, so
**nothing is bound to ⌘B/⌘I today**; fixing the constraint alone will not make the shortcuts work.
The probe reproduced this: with no main menu, `performKeyEquivalent` returned `false` and the text
storage was untouched by a synthesized ⌘B.

`SwiftUI.TextFormattingCommands` (macOS 11+) is the stock way to add Format ▸ Bold/Italic with the
standard shortcuts. Note it also brings the non-grammar items along, so it interacts with §9.

## 9. Non-grammar formatting that is currently applicable but unserializable

These keys are in the editor's scope, so a native command CAN write them, and nothing in the
grammar can round-trip them — a dead checkmark / silent data loss on save (No-Fake-State):

- `underlineStyle` (Font ▸ Underline)
- `backgroundColor` (Font ▸ Highlight ▸ any color)
- `strikethroughStyle` (no menu item, but reachable via the Font panel / Format…)
- `foregroundColor` (Show Colors) — already neutralized by the existing `SummaryInkConstraint`,
  which force-overwrites it every pass.

Outline has no attribute representation in the SwiftUI scope and appears inert here.
