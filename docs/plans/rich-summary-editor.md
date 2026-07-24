# Plan: Rich-text summary editor (macOS 26 AttributedString `TextEditor`)

**Status: PLAN (2026-07-23).** Plan-only; executed by `swift-implementer`, gated by `swift-code-reviewer`. Builds on the shipped plain-markdown edit feature — replaces only the *editing surface*; the save path is untouched.

**Decisions (RESOLVED 2026-07-24):**
- **D1 — Canonicalization on save → ACCEPT.** An open→Save with zero typing may rewrite `bodyMarkdown` to its canonical form (bullets `- `, renumbered lists, single blank lines between blocks, `\r\n → \n`, trimmed trailing whitespace). Accepted: the canonical form re-parses to identical blocks (test 20), it's a fixed point (test 21, tidies at most once), summaries are rendered not raw-edited, and there's no version history to keep clean. `saveSummaryEdit`'s `markdown != bodyMarkdown` guard (`MeetingDetailViewModel.swift:101`) still no-ops a true no-op. The stricter view-side-skip alternative was declined.
- **D2 — Italic scope → IN SCOPE.** `*…*`, `***…***` round-trip alongside bold.
- **D3 — Spike gate → PASSED (SDK + compile level), runtime deferred to Step 5.** See §7 Step 0 verdict below. The bold-via-font mechanism is API-supported; the R1 runtime check folds into Step 5 (no separate throwaway run needed), and both R1 and R4 have documented fallbacks that don't touch the transform core.

**Deferred (post-core, explicit one-shot — NOT in this plan's scope):**
- **Corpus backfill.** Run the canonicalizer (`SummaryEditDocument.make(from: bodyMarkdown).serialized()`) over every stored summary once, so old never-edited meetings match the canonical form. Deferred by decision (2026-07-24) until after the core lands and its round-trip suite is green (test 20 is the safety proof). Must be **safe-by-construction**: verify-before-write (only replace a row when `parse(canonical) == parse(original)`, else leave untouched + log), `VACUUM INTO` backup first, run as an **explicit** action (marker-gated one-shot like the legacy import — never a silent startup migration), idempotent. Benefit is cosmetic (stored bytes only; summaries render identically either way), so revisit whether it's worth doing at all once the lazy-on-save path exists.

## 1. Goal & seam

Replace the raw-markdown `MarginaliaTextEditor` editing surface in `MeetingDetailView`'s summary column (`Ari/UI/MeetingDetails/MeetingDetailView.swift:502-508`) with a **rich, WYSIWYG-faithful editor** built on macOS 26's `TextEditor(text: Binding<AttributedString>, selection:)` + `AttributedTextFormattingDefinition`, serializing back to the exact `MarginaliaMarkdown` block grammar on Save.

- **Seam/phase:** Swift-native UI (the `arikit-native-read-ui` / detail-screen track). Lands entirely on the **target (Swift) side** — no Rust/React code touched. The frozen Rust app's BlockNote editor is precedent, not the deliverable; this is the Swift tree's own editing surface, layered on the already-shipped Swift plain-markdown editor (allowed under principle 8: parity/enhancement work lands target-side only).
- **Unchanged contract:** `MeetingDetailViewModel.saveSummaryEdit(_ markdown: String)` (`AriKit/Sources/AriViewModels/MeetingDetailViewModel.swift:98-107`) — persists via `database.summaries.upsert`, re-parses `ReferencedMoments`, never creates a summary that doesn't exist. **This plan changes zero lines of it.**
- **Grammar ceiling (hard):** exactly the closed `MarginaliaMarkdownBlock` set — `heading(level:text:)`, `paragraph`, `bulletList`, `numberedList`, `table(header:rows:)` (`AriKit/Sources/AriKit/DesignSystem/MarginaliaMarkdown.swift:23-36`) plus inline bold/italic and citations-as-literal-text. Nothing more.
- **WIP note:** one feature, one screen. `MarginaliaTextEditor` itself is untouched (Notes / person-facts still use it).

## 2. Module & surface

All transforms are grammar-and-token-coupled to Marginalia, so they live beside the parser in **`AriKit/Sources/AriKit/DesignSystem/`**. The editor view is app-only.

### 2.1 `SummaryBlockAttribute.swift` (new, AriKit DesignSystem)

```swift
/// The structural identity of one editor paragraph. Serialization reads THIS, never fonts.
public enum SummaryBlockKind: Codable, Hashable, Sendable {
    case paragraph
    case heading(level: Int)   // 1...6, clamped
    case bulletItem
    case numberedItem          // source numbering dropped; serializer renumbers from 1
}

public enum SummaryBlockAttribute: CodableAttributedStringKey {
    public typealias Value = SummaryBlockKind
    public static let name = "com.arivo.ari.summaryBlock"
    /// Typed text inside/continuing a paragraph keeps its block kind (Enter continues a list).
    public static let inheritedByAddedText = true
    /// The attribute is paragraph-scoped: AttributedString coalesces it per paragraph and keeps
    /// it consistent across edits — the mechanism that makes "attribute, not font" reliable.
    public static let runBoundaries: AttributedString.AttributeRunBoundaries? = .paragraph
}

public extension AttributeScopes {
    struct AriAttributes: AttributeScope {
        public let summaryBlock: SummaryBlockAttribute
        public let swiftUI: SwiftUIAttributes   // font, foregroundColor, etc.
    }
    var ari: AriAttributes.Type { AriAttributes.self }
}
public extension AttributeDynamicLookup {
    subscript<T: AttributedStringKey>(
        dynamicMember keyPath: KeyPath<AttributeScopes.AriAttributes, T>
    ) -> T { self[T.self] }
}
```

(API names per Apple's macOS 26 rich-text stack — `AttributedTextFormattingDefinition` / `AttributedTextValueConstraint` / `TextEditor(text:selection:)`; see [WWDC25 session 280](https://developer.apple.com/videos/play/wwdc2025/280/), [AttributedTextValueConstraint docs](https://developer.apple.com/documentation/swiftui/attributedtextvalueconstraint), [createwithswift walkthrough](https://www.createwithswift.com/using-rich-text-in-the-texteditor-with-swiftui/). Exact trait spellings (`inheritedByAddedText`, `runBoundaries`) are Foundation `AttributedStringKey` API; Step 0 pins them against the GA SDK.)

### 2.2 `SummaryEditDocument.swift` (new, AriKit DesignSystem) — the segment model

Tables are read-only islands, so the document is an **alternating list of editable runs and verbatim table slabs**, split from the *raw source lines* using the same table detection the parser uses (header row + `|---|` separator; expose `MarginaliaMarkdown.isTableRow/isTableSeparator` as `package`/`public` helpers rather than duplicating the grammar).

```swift
public struct SummaryEditDocument: Equatable, Sendable {
    public enum Segment: Equatable, Sendable, Identifiable {
        /// A styled, block-kind-stamped editable run (possibly empty).
        case editable(id: Int, text: AttributedString)
        /// A table slab: the EXACT source lines, joined verbatim. Never editable, never rewritten.
        case table(id: Int, rawMarkdown: String)
        public var id: Int { … }
    }
    public var segments: [Segment]

    /// Split + present: raw markdown → segments. Table line-runs (contiguous per the parser's
    /// own scan: header, separator, then rows while isTableRow) become verbatim `.table` slabs;
    /// everything between becomes ONE `.editable` run via SummaryRichText.present.
    public static func make(from markdown: String) -> SummaryEditDocument

    /// Rejoin + serialize: segments → markdown. Editable runs via SummaryRichText.serialize;
    /// table slabs byte-identical; segments joined by exactly one blank line, with empty
    /// editable runs contributing nothing beyond that separator. No trailing newline.
    public func serialized() -> String
}
```

**Segment rules (explicit):**
- The segment list **always begins and ends with an `.editable` segment** (empty if the document starts/ends with a table) so the user can type before the first / after the last table.
- **Between any two `.table` segments there is always exactly one `.editable` segment** (empty when the source had only blank lines there) — the insertion point between adjacent tables. Note: two tables with *no* blank line between them are one table by the parser's scan (`MarginaliaMarkdown.swift:100-105`, rows continue while `isTableRow`) and therefore one slab here too.
- A `.table` slab stores the source lines **byte-identical** — alignment colons, trailing spaces, ragged rows, everything (only the surrounding blank lines are owned by the joiner).

### 2.3 `SummaryRichText.swift` (new, AriKit DesignSystem) — presenter + serializer

```swift
public enum SummaryRichText {
    /// blocks → one styled AttributedString. Every paragraph stamped with \.summaryBlock;
    /// fonts/inks from the Marginalia ramp; citations kept VERBATIM as literal text.
    public static func present(_ blocks: [MarginaliaMarkdownBlock]) -> AttributedString
    /// Convenience: parse + present one editable run's source.
    public static func present(markdown: String) -> AttributedString

    /// AttributedString → markdown for the closed grammar. Reads \.summaryBlock for structure;
    /// reads font identity ONLY for bold/italic. Never drops characters.
    public static func serialize(_ text: AttributedString) -> String
}
```

**Presentation rules:**
- Editor paragraphs are separated by `\n`. A source paragraph's *internal* hard line breaks (the parser joins soft-wrapped stacks with `\n`, `MarginaliaMarkdown.swift:76`) are presented as **U+2028 LINE SEPARATOR** so the stack stays *one* editor paragraph / one block attribute; the serializer maps U+2028 back to `\n`. Typing Enter produces `\n` = a genuinely new block.
- Fonts mirror the read view's mapping (`MarginaliaMarkdownView.swift:54-59`): heading level ≤ 2 → `.title2` ramp font, level ≥ 3 → `.headline`; body text → `.body` (`MarginaliaTypography.swift:102-106`); inks via the ramp's `MarginaliaColorRole`. The **level** lives in the attribute, so h1 vs h2 (same font) still round-trips.
- List items are presented as their own paragraphs stamped `bulletItem`/`numberedItem`, with a **literal visible marker prefix** in the text: `"•\t"` for bullets, `"1.\t"` (renumbered) for numbered. Structure comes from the attribute; the marker is presentation that happens to be editable text.
- Bold/italic: the editable run's inline markdown is parsed (`.inlineOnlyPreservingWhitespace`, same as the read view, `MarginaliaMarkdownView.swift:276-282`) and mapped to explicit fonts: `.bold` weight variant of the paragraph's ramp font, `.italic()` variant, and both combined. The formatting definition (§2.4) keeps this the *only* bold/italic representation in the document.
- **Citations stay verbatim**: `[MM:SS]`, `@ref(MM:SS)` (and any `@mref(...)`) are ordinary literal characters — no chips, no `displayText` normalization (normalizing `@ref` → `[…]` would be a lossy rewrite; `@mref` would even drop its member index). Zero transformation = zero loss.

**Serialization rules (per paragraph, attribute-first):**
- `heading(level: n)` → `"#"*n + " " + text` (inline emphasis serialized inside).
- `paragraph` → text with U+2028 → `\n`; consecutive `paragraph` blocks separated by a blank line.
- `bulletItem` → `- ` + text **after stripping at most one leading marker** (`•`/`-`/`*` + whitespace, or `\t`); consecutive list items on adjacent lines, no blank line between them; a blank line before/after the list run.
- `numberedItem` → `N. ` renumbered from 1 within each contiguous run, stripping at most one leading `digits.`/`digits)` marker.
- A paragraph with **no** `\.summaryBlock` attribute (typed into a fresh empty segment) serializes as `paragraph`.
- Bold run → `**…**`, italic → `*…*`, both → `***…***`; runs coalesced so `**a****b**` never appears.
- Empty paragraphs serialize to nothing (they only shape blank-line separation).

**Canonicalization (the explicit answer to "what may change on a no-op edit"):** bullets normalize to `- `; numbered lists renumber `1.`-style with `. `; exactly one blank line between blocks (list-item lines adjacent); `\r\n` → `\n`; leading/trailing indentation on non-table lines trimmed (the parser already trims, `MarginaliaMarkdown.swift:85`); no trailing newline. **Never** canonicalized: table slabs (byte-identical), citation markers, emphasis markers' content, unrecognized constructs (a `#foo` no-space pseudo-heading, block quotes, fenced code — all of which the parser downgrades to paragraph text — survive as their literal characters).

### 2.4 `MarginaliaSummaryFormattingDefinition.swift` (new, AriKit DesignSystem)

An `AttributedTextFormattingDefinition` whose `Scope` = `AttributeScopes.AriAttributes` (block kind + SwiftUI font/foregroundColor), applied to each segment editor via `.attributedTextFormattingDefinition(_:)`. Its constraints (`AttributedTextValueConstraint`, `constrain(_ container: inout Attributes)`) run over typed, pasted, and shortcut-toggled text, which is what makes rich paste safe:

- **`SummaryFontConstraint`** — coerces every run's font to the closed set derived from its paragraph's `SummaryBlockKind` + emphasis: `{heading(≤2): title2, heading(≥3): headline, body, bodyBold, bodyItalic, bodyBoldItalic}`. A pasted 48 pt Comic Sans run lands as canonical body; a Cmd+B-produced "bold-modified body font" is normalized to the *identity-canonical* `bodyBold` the serializer compares against.
- **`SummaryInkConstraint`** — foreground color forced to the block's Marginalia ink role (headings `inkHeading`, body `inkBody`).
- **`SummaryBlockDefaultConstraint`** — absent `\.summaryBlock` defaults to `.paragraph`; heading levels clamped 1…6.

This is also what makes the editor **visually indistinguishable from the read view**: same fonts, same inks, canvas background (`scrollContentBackground(.hidden)` over `MarginaliaCanvasWash`), no field chrome — deliberately *not* `MarginaliaTextEditor`'s boxed `MarginaliaFieldSpec` treatment.

### 2.5 `SummaryRichEditor.swift` (new, app target: `Ari/UI/MeetingDetails/`)

```swift
struct SummaryRichEditor: View {
    @Binding var document: SummaryEditDocument
    let scheme: ColorScheme
    // VStack of segments: .editable → TextEditor(text: segmentBinding, selection:) with the
    // formatting definition; .table → MarginaliaMarkdownView(markdown: rawMarkdown) with no
    // handlers (inert timecodes, MarginaliaMarkdownView.swift:222-225 — honest, no dead chips).
}
```

One `@State AttributedTextSelection` per editable segment (selection is single-editor). No formatting toolbar in v1 — native Cmd+B/Cmd+I and the system Format menu only.

## 3. Concurrency model

- **Everything user-facing is `@MainActor`** (SwiftUI views + `MeetingDetailViewModel`, already `@MainActor @Observable`, `MeetingDetailViewModel.swift:21-23`).
- **Presenter / serializer / segmenter are pure, synchronous, value-type functions** — `Sendable` in/out (`AttributedString`, `String`, `SummaryBlockKind` all `Sendable`), no I/O, no shared state, trivially callable from tests off-main. Summaries are small (tens of KB); Save-time serialization on the main actor is fine — **no** background hop, **no** `@unchecked Sendable` anywhere.
- Nothing here touches the audio hot path or STT.

## 4. Persistence

**None.** No schema change, no new repository methods. The single write remains `SummaryRepository.upsert` via `saveSummaryEdit` — repository-layer-only, single-DB-owner preserved, `v1_baseline` untouched.

## 5. Acceptance tests (written first)

New suites in `AriKit/Tests/AriKitTests/` (Swift Testing), beside the existing `MarginaliaMarkdownTests.swift`. All agent-runnable via `swift test`.

**`SummaryEditDocumentTests`**
1. `splitNoTablesYieldsSingleEditableSegment`
2. `splitTableOnlyDocumentBracketsWithEmptyEditables` (leading + trailing editable always present)
3. `splitBlankLineSeparatedTablesKeepEmptyEditableBetween` (adjacent-table insertion point)
4. `splitContiguousTableLinesAreOneSlab` (no blank line → one table, matching the parser's scan)
5. `tableSlabIsByteIdentical` (alignment colons, trailing spaces, ragged rows survive `serialized()` exactly)
6. `serializedJoinsSegmentsWithSingleBlankLine` / `emptyEditableSegmentsContributeNothing`
7. `emptyBodyMakesOneEmptyEditableAndSerializesEmpty`

**`SummaryRichTextPresenterTests`**
8. `headingsStampLevelAndRampFont` (levels 1–6; level in attribute even where fonts collide)
9. `paragraphInternalNewlinesBecomeLineSeparators` (U+2028, one block attribute)
10. `bulletAndNumberedItemsStampKindWithLiteralMarkers` (renumbered)
11. `boldItalicMapToCanonicalFontSet`
12. `citationsRemainVerbatimLiteralText` (`[03:09]`, `@ref(03:09)`, `@mref(m2@04:10)` — character-identical)

**`SummaryRichTextSerializerTests`** — round-trip = `parse → present → serialize`
13. `roundTripHeadingEachLevel` · 14. `roundTripParagraphWithHardBreaks` · 15. `roundTripBulletList` · 16. `roundTripNumberedListRenumbers` · 17. `roundTripBoldItalicCombined` · 18. `roundTripCitationsByteIdentical` · 19. `roundTripMixedRealSummaryCorpus` (fixture bodies incl. a real action-items table)
20. `roundTripIsBlockStable` — for every fixture: `MarginaliaMarkdown.parse(roundTrip(md)) == MarginaliaMarkdown.parse(md)` (the load-bearing fidelity invariant)
21. `canonicalFormIsFixedPoint` — `roundTrip(roundTrip(md)) == roundTrip(md)` (bounds D1's rewrite to one step)
22. `noSilentContentLossForUnrecognizedConstructs` — fenced code, blockquote, `#foo` survive as literal paragraph text
23. `unstampedParagraphSerializesAsParagraph` · 24. `inheritedBulletKindWithoutMarkerTextStillSerializesAsListItem` (Enter-continued item; attribute authoritative) · 25. `markerStrippedAtMostOnce` (`• • second marker stays`)
26. `degenerateInputs` — empty string, whitespace-only, trailing-blank-line stacks, single citation-only line

**Existing suites must stay green untouched:** `MarginaliaMarkdownTests`, `MeetingDetailViewModel`'s `saveSummaryEdit` tests (no VM change).

**Manual/visual checklist (signed app, XcodeBuildMCP screenshots):** read↔edit visual parity (same measure/canvas, no chrome); Cmd+B/Cmd+I round-trip; rich paste from Safari coerced to Marginalia set; tables inert in edit mode; Cancel and meeting-switch discard; write-failure alert keeps draft open.

No numeric eval / S1–S4 gate applies — the bar is the round-trip suite plus the Step-0 spike checklist.

## 6. Invariants preserved

- **No-Fake-State** — editing still never *creates* a summary (`saveSummaryEdit` guard untouched, `MeetingDetailViewModel.swift:99-101`); table islands render inert citation timecodes, never dead play chips (`MarginaliaMarkdownView.swift:8-11, 222-225`); write failure surfaces via the existing `actionError` alert with the draft intact (`MeetingDetailView.swift:677-681`); no fabricated content on any degenerate input (test 22 is the "no silent loss" invariant as code).
- **Citation honesty** — markers pass through byte-identical, so `ReferencedMoments.parse` on Save (`MeetingDetailViewModel.swift:106`) sees exactly what the user kept; the editor can neither invent nor silently reformat a citation.
- **Recall safety shell / consent-before-record** — untouched (no recall, no capture code in scope).
- **Single-DB-owner / repositories-only** — no new persistence surface.

## 7. Risks & sequencing

**Risks**
- **R1 — Cmd+B font identity.** Native bold toggling writes SwiftUI `font` values whose equality against our canonical `bodyBold` is not guaranteed. Mitigation is architectural: `SummaryFontConstraint` normalizes *every* mutation to the closed set, so the serializer only ever compares canonical values. If the GA SDK's constraint pass doesn't fire on shortcut toggles, fallback = a custom Cmd+B/Cmd+I `keyboardShortcut` that calls `transformAttributes(in: &selection)` directly. **Step 0 gates this.**
- **R2 — Attribute traits under live editing.** `inheritedByAddedText` + `runBoundaries: .paragraph` must give: Enter in a bullet → new paragraph inherits `bulletItem` (serializer already tolerates the missing marker text, test 24); typing at paragraph start keeps the kind. Verify in Step 0; fallback = a lightweight `onChange`-style re-stamp pass before serialization.
- **R3 — Paste.** Rich paste must be coerced by the definition (attachment paste is unsupported in SwiftUI rich `TextEditor` today — acceptable, we have no attachments). Verify plain-text and Safari-rich paste in Step 0.
- **R4 — U+2028 handling** in `TextEditor` (caret/wrap behavior). If hostile, fallback: present hard-break stacks as separate `paragraph` blocks and accept the (canonicalization-documented) blank-line rewrite — a D1 amendment.
- **R5 — Markdown-lookalike text.** A user typing `- foo` inside a paragraph serializes as literal text but re-parses as a bullet on next open. Accepted v1 behavior (markdown-ish typing "promotes" on reopen); documented, not defended against.
- **R6 — List ergonomics honesty (v1).** No auto-marker insertion while typing: Enter continues the *kind* (serializes correctly) but the visible `•` appears only on next present. No list indent/outdent, no block-kind toolbar. Stated plainly as v1 scope.

**Sequencing** (each step independently testable; core lands before any UI):
0. **API spike — DONE 2026-07-24, verdict GO (SDK + compile).** Throwaway `#if DEBUG` view `Ari/UI/Spike/RichEditorSpike.swift` (not merged; seed for Step 5, deletable). Findings against `MacOSX26.5.sdk`:
   - ✅ `TextEditor(text: Binding<AttributedString>, selection: Binding<AttributedTextSelection>?)` — present (SwiftUI).
   - ✅ `AttributeRunBoundaries` / `inheritedByAddedText` / `runBoundaries` — present (Foundation), exact spellings as §2.1.
   - ⚠️ **`AttributedTextFormattingDefinition`, `AttributedTextValueConstraint`, and `.attributedTextFormattingDefinition(_:)` live in `SwiftUICore`, not `SwiftUI`** — import is transitive via `import SwiftUI`, but note it. The custom-constraint protocol requires `constrain(_ container: inout Attributes)` where `Attributes` is a `@dynamicMemberLookup` `AttributeContainerProxy` that **reads sibling attributes (block kind) and writes its own key (font)** — the exact §2.4 mechanism.
   - ✅ R1 fallback `transformAttributes(in: &selection, body:)` — present, if the constraint doesn't fire on Cmd+B.
   - ✅ The whole chain (custom key + scope + `AttributeDynamicLookup` subscript + custom constraint + definition result-builder + `TextEditor(text:selection:)` + `.attributedTextFormattingDefinition`) **compiles clean in the `Ari` target.**
   - **Residual (runtime-only, verified at Step 5):** R1 constraint-fires-on-Cmd+B/paste, R2 trait behavior under live typing, R4 U+2028 caret/wrap. All have fallbacks (R1 → `transformAttributes` shortcut; R4 → separate paragraphs) that leave the transform core (steps 1–4) intact — so the core is safe to build now regardless of how they resolve.
1. `SummaryBlockAttribute` + `SummaryBlockKind` + `AriAttributes` scope (+ expose the parser's table-line helpers). → compiles, Sendable/Codable tests.
2. `SummaryEditDocument` segmenter + `serialized()`. → tests 1–7.
3. `SummaryRichText.present`. → tests 8–12.
4. `SummaryRichText.serialize` + full round-trip suite. → tests 13–26.
5. `MarginaliaSummaryFormattingDefinition` + `SummaryRichEditor`; swap into `MeetingDetailView`: `summaryDraft: String` → `summaryDocument: SummaryEditDocument?`; `beginSummaryEdit` builds via `SummaryEditDocument.make(from: summary.bodyMarkdown)` (`MeetingDetailView.swift:659-663`); `commitSummaryEdit` calls `viewModel.saveSummaryEdit(document.serialized())` with unchanged error handling (`:670-683`); Save disabled when the serialized, trimmed document is empty (`:699` equivalent); Cancel and the `.task(id: meetingId)` reset clear the document (`:196-198`). `MarginaliaTextEditor` stays for Notes.
6. Visual/manual checklist in the signed app.

## Files this plan touches

New: `AriKit/Sources/AriKit/DesignSystem/SummaryBlockAttribute.swift`, `.../SummaryEditDocument.swift`, `.../SummaryRichText.swift`, `.../MarginaliaSummaryFormattingDefinition.swift`; `Ari/UI/MeetingDetails/SummaryRichEditor.swift`; `AriKit/Tests/AriKitTests/SummaryEditDocumentTests.swift`, `.../SummaryRichTextPresenterTests.swift`, `.../SummaryRichTextSerializerTests.swift`.
Edited: `AriKit/Sources/AriKit/DesignSystem/MarginaliaMarkdown.swift` (expose table-line classification only), `Ari/UI/MeetingDetails/MeetingDetailView.swift` (draft state + begin/commit/cancel wiring).
Untouched by design: `MeetingDetailViewModel.swift`, `SummaryRepository`, `MarginaliaTextEditor.swift`, `MarginaliaMarkdownView.swift` rendering paths.

Apple-framework sources: [WWDC25 — Cook up a rich text experience in SwiftUI with AttributedString](https://developer.apple.com/videos/play/wwdc2025/280/) · [AttributedTextValueConstraint](https://developer.apple.com/documentation/swiftui/attributedtextvalueconstraint) · [AttributedTextFormattingDefinition](https://developer.apple.com/documentation/swiftui/attributedtextformattingdefinition) · [Using rich text in the TextEditor with SwiftUI (createwithswift)](https://www.createwithswift.com/using-rich-text-in-the-texteditor-with-swiftui/) — noting attachments are unsupported in rich `TextEditor` today and exact trait spellings are pinned in Step 0.
