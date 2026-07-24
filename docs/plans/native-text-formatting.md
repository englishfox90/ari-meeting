# Plan: native text formatting in the rich summary editor

**Status: PLAN (2026-07-24).** Step 1 (runtime investigation) is **DONE** —
`docs/plans/native-text-formatting-findings.md` is authoritative and this plan is written against
it. Closes **R1** in `docs/plans/rich-summary-editor.md`.

Entirely on the Swift side (`AriKit/` + the `Ari` app target). Nothing touches `frontend/src-tauri/`.

---

## 1. Goal

1. **Font ▸ Bold / Font ▸ Italic** in the `TextEditor` context menu (present today) must produce
   emphasis that survives the formatting definition and round-trips to `**…**` / `*…*`. Today they
   silently no-op (findings §4).
2. **⌘B / ⌘I** must be bound at all — they are bound to nothing today, because
   `Ari/App/AriApp.swift` declares no `.commands` (findings §8).
3. **Non-grammar native formatting** (Underline / Highlight / Strikethrough) must be visibly inert
   rather than a dead checkmark that quietly loses data on save (findings §9, No-Fake-State).

---

## 2. Module boundaries

| Concern | Lives in |
|---|---|
| Pure canonical-font normalization | **new** `AriKit/Sources/AriKit/DesignSystem/SummaryCanonicalFont.swift` (extracted from `MarginaliaSummaryFormattingDefinition.swift:114-165`) |
| Constraints + definition | `MarginaliaSummaryFormattingDefinition.swift` |
| Editor-side transforms | `SummaryEditing.swift` |
| Font source of truth | `SummaryRichText.swift` → `SummaryFontVariant` — **unchanged, never forked** |
| `Font.Context` plumbing + Format menu | `Ari/UI/MeetingDetails/{SummaryRichEditor,SummaryEditorModel,MeetingDetailView}.swift`, `Ari/App/AriApp.swift` |

**Untouched (hard constraint):** `MeetingDetailViewModel.saveSummaryEdit`, `SummaryRepository`,
`MarginaliaMarkdownView`, `SummaryRichText.present`/`serialize`, `SummaryEditDocument`,
`SummaryBlockAttribute` / the `AriAttributes` scope.

---

## 3. Surface changes

### 3.1 `SummaryCanonicalFont` (moved + upgraded, module-internal as today)

```swift
enum SummaryCanonicalFont {
    private static let families: [SummaryBlockKind] = [.paragraph, .heading(level: 1), .heading(level: 3)]

    static func font(for kind: SummaryBlockKind, bold: Bool, italic: Bool) -> Font   // unchanged

    // NEW: `context` is the only addition. `nil` ⇒ exactly today's equality-only behaviour.
    static func emphasis(of font: Font?, for kind: SummaryBlockKind,
                         context: Font.Context?) -> (bold: Bool, italic: Bool)

    // NEW: reimplemented as font(for:bold:italic:) ∘ emphasis(of:for:context:) so the toolbar read
    // and the constraint write can never disagree.
    static func coerce(_ font: Font?, to kind: SummaryBlockKind, context: Font.Context?) -> Font

    // NEW: the pure decision core — Bool in / Bool out, exhaustively table-testable without
    // constructing a `Font.Resolved` (which has no public initializer).
    static func emphasisRelative(resolvedIsBold: Bool, resolvedIsItalic: Bool,
                                 baseIsBold: Bool, baseIsItalic: Bool) -> (bold: Bool, italic: Bool)
}
```

No default value for `context:` — an omitted context is exactly the bug being fixed, so it must be
spelled at every call site.

### 3.2 Constraints + definition

```swift
struct SummaryFontConstraint: AttributedTextValueConstraint {
    let fontContext: Font.Context?                       // NEW stored property
}

// NEW, stateless, each unconditionally writes nil for its own key:
struct SummaryNoUnderlineConstraint      // UnderlineStyleAttribute
struct SummaryNoStrikethroughConstraint  // StrikethroughStyleAttribute
struct SummaryNoHighlightConstraint      // BackgroundColorAttribute

public struct MarginaliaSummaryFormattingDefinition {
    public init(scheme: ColorScheme, fontContext: Font.Context?)   // REPLACES init(scheme:)
    public var body: some AttributedTextFormattingDefinition<Scope> {
        SummaryBlockDefaultConstraint()
        SummaryFontConstraint(fontContext: fontContext)
        SummaryInkConstraint(scheme: scheme)
        SummaryNoUnderlineConstraint()
        SummaryNoStrikethroughConstraint()
        SummaryNoHighlightConstraint()
    }
}
```

`init(scheme:)` is **replaced, not overloaded** — an overload would let a call site silently
reintroduce the bug.

### 3.3 `SummaryEditing`

All three gain `context: Font.Context?`. `setBlockKind` needs it too: it calls `emphasis(of:for:)`
to carry emphasis across a kind change, and would otherwise drop a natively-applied bold.

### 3.4 App target

```swift
// SummaryEditorModel — same pattern as `focusedSegment`
var fontContext: Font.Context?                     // forwarded by toggleBold/toggleItalic/setBlockKind

// SummaryRichEditor
@Environment(\.fontResolutionContext) private var fontContext
.attributedTextFormattingDefinition(
    MarginaliaSummaryFormattingDefinition(scheme: scheme, fontContext: fontContext))
.onAppear { model.fontContext = fontContext }       // + .onChange(of: fontContext)
```

---

## 4. How `Font.Context` reaches the constraint — SETTLED

**The same way `scheme` already does.** The definition is built per render in
`SummaryRichEditor.body`; the context is read there via `@Environment(\.fontResolutionContext)`,
which is where the editor's own font environment lives, so resolution matches the context the runs
actually render in.

SDK-verified (`SwiftUICore.swiftinterface`): `EnvironmentValues.fontResolutionContext` `:3377` ·
`Font.Context: Hashable, Sendable`, **no public init** `:3357` · `Font.resolve(in:) -> Font.Resolved`
`:9094` (macOS 26+) · `Font.Resolved: Hashable, Sendable` with `isBold`/`isItalic`/`weight`/
`pointSize` `:9056-9074` · `AttributedTextValueConstraint: Hashable & Sendable` `:9517` · public
`EnvironmentValues.init()` `:11685`.

`Optional<Font.Context>` being Hashable + Sendable is what keeps the constraint's conformances
**synthesized** — the identical mechanism `SummaryInkConstraint` already uses for its `ColorScheme`.
Tests obtain a context via `EnvironmentValues().fontResolutionContext`.

**Rejected:** having the constraint synthesize its own context internally — it would run per-run
per-mutation, use the *default* environment rather than the editor's, and hide a real input inside a
supposedly pure transform.

---

## 5. The emphasis-recovery algorithm — SETTLED

### Tier 1 — exact value equality (unchanged, always first)

Walk `families` in order, testing `boldItalic → bold → italic → base` per family; first match wins.
Covers everything `present` produces, everything the toolbar writes, everything already normalized
by a prior pass, and every native *no-op* write (where AppKit returned an identical font). **Zero
behaviour change, no `Font.Context` needed.** This is what keeps round-trip test 20 and fixed-point
test 21 bit-identical.

### Tier 2 — resolve-based recovery, keyed RELATIVE to the kind's own base

Reached only when Tier 1 matched nothing **and** `context != nil`:

```
let r    = font.resolve(in: context)
let base = SummaryFontVariant.base(for: kind).resolve(in: context)
bold   = r.isBold   && !base.isBold
italic = r.isItalic && !base.isItalic
```

Bold is `true` only when the run resolves bold **and its kind's base does not**. This is the direct
fix for findings §6: for a family whose base already resolves bold, plain and "bolded" runs are
indistinguishable, so we report `false` and never wrap plain text in `**…**`.

**Weight is deliberately not used.** `Font.Weight` is Hashable but **not Comparable**, and its
`value` storage is `package`, not public (`SwiftUICore.swiftinterface:12236-12237`) — there is no
supported way to compare two weights. Findings §7 also shows weight is *identical* in exactly the
ambiguous case, so it wouldn't help. `pointSize` is likewise ignored: a size-only native write
(Bigger/Smaller) correctly resolves to `(false, false)` and flattens to the canonical size.

### 5.1 The heading families — measured, not assumed

Findings §6/§7 measured Ari's **real** bases with the brand face registered as `AppFonts` does:

- **body / lists** — clean on both axes (`isBold=false`, `isItalic=false`), and NSFontManager
  converts cleanly (`.SFNS-Regular` → `.SFNS-Semibold` / `.SFNS-SemiboldItalic`). Recovery works
  fully. **This is where Tier 2 earns its keep.**
- **both heading families** — base already resolves `isBold=true`, and `.bold()`/`.italic()` resolve
  *identically to base*, because the app registers two separate static Bricolage cuts with **no
  italic cut**. NSFontManager has nothing to convert to (`…-SemiBold` → `…-SemiBold` for both
  traits).

So native Bold/Italic on a heading is an **AppKit-level no-op**: an identical font comes back, which
hits Tier 1, reads `(false, false)`, and leaves the run untouched. Correct and honest.

Note the pre-existing asymmetry, which this plan **documents rather than "fixes"**:
`SummaryFontVariant.bold(for: .heading(…))` renders identically to base but remains a distinct
`Font` *value*, so Tier 1 tells them apart and `serialize` still emits `**…**`. The toolbar/⌘B path
on a heading therefore produces durable markdown even though the glyphs don't change. Native Bold
does not. Both behaviours get a doc comment.

### 5.2 Why `serialize` must NOT get the same upgrade

`SummaryRichText.serialize` / `emphasisSerialized` stays pure equality-only and untouched: by the
time it runs, the constraint has already normalized the string (a native write *is* an editor
mutation), and `serialize` must remain deterministic and environment-free — tests 20/21 depend on
it. Test **N11** pins this boundary.

### 5.3 One deliberate behaviour change — flagged

Today a foreign rich paste flattens **entirely** to the kind's plain base. With Tier 2, a pasted
**bold** run now lands as canonical **body bold** instead of plain. Face, size, colour and every
other attribute are still flattened, and the output is still one of exactly four canonical variants,
so the closed grammar and byte-faithful round-trip are unaffected. Strictly better fidelity, but it
is a change to the documented paste-safety wording.

---

## 6. Non-grammar attributes: strip, don't decorate

`AriAttributes` nests the whole SwiftUI scope, so `underlineStyle`, `strikethroughStyle`, and
`backgroundColor` are all applicable and none can round-trip. Three stateless strip constraints each
unconditionally write `nil` — mirroring how `SummaryInkConstraint` already force-overwrites
`foregroundColor`. Idempotent, per-run per-mutation, so Underline/Highlight are inert the instant
they're applied: **no dead checkmark that appears to work and then loses data on save.**

`buildBlock` is variadic over a parameter pack (`SwiftUICore.swiftinterface:9410`), so six
constraints compose without splitting the definition. **Outline** has no attribute representation
and is already inert — nothing to do, nothing to fake.

**Rejected:** narrowing the `AriAttributes` scope. Cleaner in principle, but it changes the scope
the presenter, serializer, `SummaryEditDocument`, and the dynamic-lookup subscript all key off, and
it's unverified whether `TextEditor` needs other scope members internally. Too much blast radius for
the same user-visible result. Recorded as a possible later simplification.

---

## 7. ⌘B / ⌘I — minimal custom Format menu

### Decision: a minimal custom Format group with **only Bold and Italic**, wired to `SummaryEditorModel`. Do **not** adopt `SwiftUI.TextFormattingCommands`.

```swift
struct SummaryFormatCommands: Commands {
    @FocusedValue(SummaryEditorModel.self) private var editor      // SwiftUI.swiftinterface:3580

    var body: some Commands {
        CommandGroup(replacing: .textFormatting) {                 // :20644
            Button("Bold")   { editor?.toggleBold() }.keyboardShortcut("b").disabled(editor == nil)
            Button("Italic") { editor?.toggleItalic() }.keyboardShortcut("i").disabled(editor == nil)
        }
    }
}
```

plus `.focusedSceneValue(isEditingSummary ? summaryEditor : nil)` in `MeetingDetailView` (both
`@State` already exist) and `.commands { SummaryFormatCommands() }` on the main scene.

**Why not `TextFormattingCommands`:** it is a single opaque `Commands` value
(`SwiftUI.swiftinterface:13625`) with no way to cherry-pick items. Adopting it drags in Underline
(⌘U), Bigger/Smaller (⌘+/⌘−), Show Fonts, Show Colors, and alignment. Underline would be stripped
by §6 → a dead checkmark, exactly what No-Fake-State forbids. Bigger/Smaller would resolve
non-canonical and get coerced back → a **visible flash-then-revert**, worse than today's silent
no-op.

Four further reasons the model-driven path wins:

1. **Correct toggle-off.** `toggleBold()` flips the bit relative to canonical state; native
   `addFontTrait:` only ever *adds* a trait.
2. **It works where the native path provably cannot** — heading families (§5.1). ⌘B mints a durable
   `**…**` there; native Bold cannot.
3. **One canonical writer.** ⌘B and the existing inline formatting bar share the exact same call, so
   bold is minted in precisely one place. The context-menu path converges on the same four values
   via §5.
4. **Honest enablement.** No focused editor ⇒ items are *disabled*, so ⌘B in a rename field does
   nothing visible rather than something surprising.

**Deliberately not doing:** no checkmarks on Bold/Italic (per-selection emphasis isn't
authoritatively mirrored, and a checkmark we can't derive truthfully is fake state — these are
actions, not toggles); no attempt to edit the AppKit-supplied context menu (§5 makes it correct
instead); no `TextEditingCommands` (orthogonal, already works).

**First responder is safe:** NSMenu tracking does not change first responder, and menu key
equivalents dispatch before the responder chain, so ⌘B reaches our action with the editor still
focused and its selection intact. Verified manually at M2.

**Risk RN1:** `CommandGroup(replacing: .textFormatting)` may render no Format menu (SwiftUI only
materializes populated menus). Fallback is `CommandMenu("Format")` with the identical two buttons —
decided visually at M1. Two-line swap; step 5 is independent of steps 1–4.

---

## 8. Concurrency

Everything here is synchronous, `@MainActor`-or-pure. No new actors, no async, no background work,
no hot path.

- `SummaryCanonicalFont` / `SummaryEditing` / `SummaryFontVariant` — pure statics over value types.
- Constraints are `Hashable & Sendable` **by synthesis**; all stored state is Sendable (`ColorScheme`,
  `Optional<Font.Context>`). **No `@unchecked Sendable`, no `nonisolated(unsafe)` anywhere.**
- `SummaryEditorModel` stays `@MainActor @Observable`; `fontContext` is MainActor state written from
  the view body / `onChange` and read by toolbar and menu actions — all MainActor.
- `FocusedValue` is explicitly non-Sendable — a `DynamicProperty` only touched on the main actor
  from a `Commands` body. Nothing escapes.
- `Font.resolve(in:)` and `AttributedTextValueConstraint` are both macOS 26+, at or below the floor
  ⇒ **no `@available` shims**.

---

## 9. Acceptance tests (write first)

### New — `AriKit/Tests/AriKitTests/SummaryCanonicalFontTests.swift`

| # | Name | Asserts |
|---|---|---|
| N1 | `canonicalFontsAreFixedPointsUnderCoerce` | All 4 kinds × 4 variants: `coerce` returns the input, with `context: nil` **and** a real context. The fast path is untouched; Tier 2 never overrides a canonical value. |
| N2 | `unrecognizedFontWithoutContextFlattensToBase` | Legacy behaviour preserved when context is absent. |
| N3 | `crossFamilyEmphasisIsStillPreserved` | `bold(for: heading 1)` coerced to `.bulletItem` → `bold(for: .bulletItem)`. |
| N4 | `nativeBoldOnBodyIsRecoveredAsCanonicalBold` | Build the platform-boxed bold the Font menu produces (`NSFontManager.convert(_:toHaveTrait: .boldFontMask)` wrapped as `Font(_:)`) → `coerce(…, to: .paragraph, context: ctx) == SummaryFontVariant.bold(for: .paragraph)`. **Must fail on current main** — the headline criterion. |
| N5 | `nativeItalicOnBodyIsRecoveredAsCanonicalItalic` | Same via `.italicFontMask`. |
| N6 | `nativeBoldThenItalicIsRecoveredAsCanonicalBoldItalic` | Accumulated traits (findings §3). |
| N7 | `emphasisRelativeTruthTable` | All 16 rows of `emphasisRelative` — pure, font-independent. |
| N8 | `boldBaseFamilyNeverReadsAsBold` | The findings-§6 trap pinned: `(resolvedIsBold: true, baseIsBold: true).bold == false`. Guards against anyone "simplifying" to an absolute `isBold`. |
| N9 | `sizeOnlyChangeFlattensToCanonicalSize` | Bigger/Smaller can't leak a non-canonical size. |
| N10 | `nilFontAlwaysCoercesToBase` | Every kind, with and without context. |

Tier-2 font assertions use the **body/SF-Pro family only** — AriKit tests run without the app
bundle, so Bricolage is unregistered and `Font.custom` falls back to the system font. Heading
behaviour is covered by N7/N8 (font-independent) plus manual M5.

### New — `SummaryFormattingDefinitionTests.swift`

| # | Name | Asserts |
|---|---|---|
| N11 | `serializeStaysEqualityOnlyForNonCanonicalFonts` | A platform-boxed bold run serializes as plain text — pins §5.2's boundary. |
| N12 | `constraintsAreValueEqualForEqualInputs` | Constraints with equal inputs are `==` and hash equal — §4's synthesis holds. |
| N13 | `stripConstraintsTargetExactlyTheUnserializableKeys` | The three strip constraints' `AttributeKey.name`s match underline/strikethrough/backgroundColor. (The `constrain` proxy has no public initializer, so the *effect* is manual item M3 — say so in the doc comment rather than faking coverage.) |
| N14 | `definitionComposesSixConstraints` | Constructs with `(scheme:fontContext:)` and the body type-checks with six constraints. |

### New — `SummaryEditingTests.swift`

| # | Name | Asserts |
|---|---|---|
| N15 | `toggleBoldOnNativelyBoldedRunTurnsItOff` | `emphasis(of: platformBold, for: .paragraph, context: ctx) == (true, false)` — the toolbar inverts to plain instead of double-applying. |
| N16 | `setBlockKindCarriesNativelyAppliedEmphasis` | Platform-boxed bold body run → `.heading(level: 1)` becomes `bold(for: .heading(level: 1))`. |

### Regression gates (unmodified, must stay green)

`SummaryRichTextSerializerTests` **in full** (esp. round-trip **20**, fixed-point **21**) ·
`SummaryRichTextPresenterTests` · `SummaryEditDocumentTests` · Marginalia parity suites (proof the
type ramp and therefore light/dark appearance is unchanged) · `SendableInventoryTests` · whole-package
`swift test` for `AriKit` + `xcodebuild` for `Ari`.

### Manual checklist (signed app)

M1. A Format menu is visible with only Bold and Italic; pick `CommandGroup(replacing:)` vs
`CommandMenu("Format")` per what renders.
M2. ⌘B/⌘I fire while the editor holds focus with a live selection; markdown after Save contains
`**…**` / `*…*`.
M3. Font ▸ Underline and Font ▸ Highlight are visibly inert.
M4. Context-menu Font ▸ Bold on a paragraph/bullet run round-trips to `**…**`.
M5. Context-menu Font ▸ Bold/Italic on a **heading** run — confirm the predicted no-op (§5.1) and
record the observed outcome.
M6. Format items are disabled when the summary editor isn't being edited.
M7. Appearance unchanged in **light and dark** vs the current build.
M8. Rich paste still coerces to the Marginalia set; a pasted bold run now arrives as canonical bold
(§5.3).

---

## 10. Invariants preserved

- **Byte-faithful round-trip / closed grammar.** Tier 1 unchanged ⇒ every canonical value is still a
  fixed point (N1); Tier 2's output is *always* one of the four canonical variants for the kind, so
  nothing outside the grammar can reach `serialize`, which is itself unmodified.
- **Single font source.** `SummaryFontVariant` remains the only place a canonical `Font` is minted;
  §3.1 further collapses `coerce`/`emphasis` onto one implementation so they cannot diverge.
- **No-Fake-State.** Non-grammar attributes stripped, not left as dead checkmarks (§6); menu items
  *disabled* rather than silently inert (§7); the heading limitation documented rather than given a
  fake representation (§5.1).
- **Appearance unchanged, light and dark.** No token, ramp, or `SummaryInkConstraint` change.
- **Persistence untouched.** No schema change, no migration, no repository method; the
  single-DB-owner rule is trivially intact (this plan opens no DB path).
- **Swift 6 strict concurrency.** All conformances synthesized; no `@unchecked Sendable` /
  `nonisolated(unsafe)`; macOS 26 floor with no `@available` shims.

---

## 11. Sequencing

Each step compiles, tests, and ships value on its own.

| Step | Work | Gate |
|---|---|---|
| 0 | Write N1–N16 first. N4/N5/N6/N15 must **fail** on current `main`; N1–N3/N7/N8/N10 must **pass**. | red-then-green baseline |
| 1 | Extract `SummaryCanonicalFont`; add `emphasisRelative` + `context:`; reimplement `coerce` via `emphasis`. Callers pass `nil` — **zero behaviour change**. | N1–N3, N7, N8, N10; tests 13–26 |
| 2 | Thread `Font.Context` through constraint → definition → `SummaryRichEditor`. **This step alone fixes the context-menu no-op.** | N4–N6, N9, N11, N12, N14; M4 |
| 3 | Thread context into `SummaryEditing` + `SummaryEditorModel.fontContext`. | N15, N16 |
| 4 | Add the three strip constraints. | N13; M3 |
| 5 | `SummaryFormatCommands` + `.focusedSceneValue` + `.commands`. | M1, M2, M6 |
| 6 | Close R1 in `rich-summary-editor.md`; record the heading limitation and M5's observed outcome. | M5, M7, M8 |

**Risks.** RN1 Format-menu placement (§7, fallback ready). RN2 `@Environment(\.fontResolutionContext)`
may not refresh on Dynamic Type change — worst case is degraded Tier-2 accuracy, never a wrong
canonical value, since output is always canonical. RN3 Tier 2 changes paste behaviour (§5.3) —
documented and tested. RN4 adding a stored property could in principle break synthesized
Hashable/Sendable — verified it cannot (§4), pinned by N12; fallback is a hand-written `==`/`hash`,
**never** `@unchecked Sendable`.
