# Brief: Leverage the native text-formatting tools in the rich summary editor

**Status: PROMPT / investigation-first (2026-07-24).** Hand off to `swift-architect` → `swift-implementer` → `swift-code-reviewer`. Builds on the shipped rich summary editor (`docs/plans/rich-summary-editor.md`); this closes its **R1** residual.

## Goal

Make the **native macOS text affordances** first-class in the summary editor — the right-click context menu's **Font ▸ Bold / Italic** and the **⌘B / ⌘I** shortcuts — so they visibly format the selection AND persist byte-faithfully to the closed Marginalia markdown grammar (`**…**` / `*…*`). **Leverage** the built-in tools rather than suppress them; keep the editor's Marginalia styling and aesthetics unchanged. The existing inline Liquid-Glass formatting bar stays and must keep working.

## Why native formatting currently no-ops

The editor is a macOS 26 `TextEditor(text: Binding<AttributedString>, selection:)` governed by a closed-grammar `AttributedTextFormattingDefinition`. Today, emphasis is represented **solely as font identity**: bold = one canonical `Font` (`SummaryFontVariant.bold(for:kind)`), italic/both likewise. Two pieces are coupled to that exact identity:

- `SummaryFontConstraint` → `SummaryCanonicalFont.coerce(_:to:)` (in `AriKit/Sources/AriKit/DesignSystem/MarginaliaSummaryFormattingDefinition.swift`) runs on every mutation and **flattens any unrecognized font back to plain `base`**.
- `SummaryRichText.serialize` (in `.../SummaryRichText.swift`) recovers `**`/`*`/`***` by matching `run.font` against those canonical values.

So when the native Font ▸ Bold writes *its own* representation, the constraint strips it (menu shows a checkmark; text doesn't change) and it would never serialize to `**…**`.

## Step 1 — Investigate on a real Mac (cannot be done on Linux/CI)

Build & launch the signed app (XcodeBuildMCP), open a saved meeting → Edit summary → select text → apply native **Font ▸ Bold**, then **Italic**, then **⌘B / ⌘I**. Instrument the editor to dump the selected run's attributes (mirror the deleted `RichEditorSpike` run-dump, or a temporary `#if DEBUG` overlay) and record **exactly what each native command writes**:

- Is `container.font` replaced with a bold/italic variant?
- Is it a separate `\.fontWeight` / symbolic trait?
- Is it **`\.inlinePresentationIntent`** (`.stronglyEmphasized` / `.emphasized`)? ← most likely, and the key question.
- Anything else?

Capture the concrete values. **This answer picks the implementation.**

## Step 2 — Implement (keep the closed grammar + Marginalia look)

**Recommended direction (if Step 1 confirms `inlinePresentationIntent`):** make emphasis **intent-driven** and derive the font from it, instead of treating raw font identity as the source of truth. This naturally leverages native tools AND aligns the editor with the read view — `MarginaliaMarkdownView` already parses markdown into `inlinePresentationIntent` via `AttributedString(markdown:)`.

- Add `inlinePresentationIntent` to the editor's attribute scope (`AttributeScopes.AriAttributes`).
- `SummaryFontConstraint` reads `(block kind, inlinePresentationIntent)` and SETS the canonical `SummaryFontVariant` font as *derived presentation* — so bold text shows the canonical bold font regardless of who set the intent (native menu, ⌘B, or our bar).
- `SummaryEditing.toggleBold/Italic` and the inline bar set the **intent**, not the font, so there is one source of truth.
- `SummaryRichText.serialize` reads the **intent** (not font identity) to emit `**`/`*`/`***`; `present` sets the intent (keep the derived font for immediate display).
- Net: native Bold/⌘B and the inline bar produce identical, round-trippable results, and the font stays on the Marginalia ramp.

**Fallback (if native uses a font/weight, not intent):** extend `SummaryCanonicalFont` to detect that signal and normalize it to the canonical `SummaryFontVariant.{bold,italic,boldItalic}(for:kind)`, clearing the native signal so there's one representation. Reuse `SummaryFontVariant` as the single font source — do **not** fork the mapping.

**Formats with no grammar representation (Underline, Strikethrough, Outline, Color):** the closed markdown grammar can't round-trip these. Decide per the "leverage" intent — default: leave the native menu intact but **strip these on serialize** (they apply visually in-session, don't persist) OR minimally remove only the truly-unrepresentable items. Do **not** leave items that toggle a checkmark with a durable-looking but silently-dropped effect (No-Fake-State). Extending the grammar to add underline/etc. is out of scope unless explicitly requested. Keep Cut/Copy/Paste/Look Up.

## Invariants & constraints (hard)

Swift 6 strict concurrency (no `@unchecked Sendable` / `nonisolated(unsafe)`); macOS 26 floor (no `@available` shims); `@Observable`-MVVM; Marginalia design system; the closed `MarginaliaMarkdownBlock` grammar and **byte-faithful round-trip** are load-bearing. Preserve the green transform suite (block-stable round-trip test 20, fixed-point test 21) and add pure-function tests for the new emphasis normalization. Do **not** change `MeetingDetailViewModel.saveSummaryEdit`, `SummaryRepository`, or `MarginaliaMarkdownView`'s rendering paths. Editor appearance must be unchanged in light **and** dark.

## Files of interest

`AriKit/Sources/AriKit/DesignSystem/`: `MarginaliaSummaryFormattingDefinition.swift` (constraints + `SummaryCanonicalFont`), `SummaryRichText.swift` (`SummaryFontVariant`, `present`/`serialize`), `SummaryEditing.swift` (bar transforms), `SummaryBlockAttribute.swift` (scope). App target `Ari/UI/MeetingDetails/`: `SummaryRichEditor.swift`, `SummaryEditorModel.swift`, `MeetingDetailView.swift` (inline bar). Context: `docs/plans/rich-summary-editor.md` (R1).

## Acceptance

Right-click Font ▸ Bold and Italic, and ⌘B/⌘I, visibly format the selection AND survive Save→reopen as `**…**` / `*…*` (verify by reading `bodyMarkdown`); the inline bar still works; emphasis has ONE representation (native + bar agree); non-grammar formats are handled honestly (no dead checkmarks); round-trip tests green; editor appearance unchanged, light and dark.

## Process

`swift-architect` (plan) → `swift-implementer` → `swift-code-reviewer`. Step-1 discovery and final verification must run in the **running signed app on a Mac** (build/launch/screenshot/UI-drive); the transform-core changes can be reasoned about offline, but the native-attribute discovery cannot.
