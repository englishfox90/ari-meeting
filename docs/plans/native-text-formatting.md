# Plan: Native text formatting in the rich summary editor (Font ▸ Bold/Italic, ⌘B/⌘I)

**Status: PLAN (2026-07-24) — architect stage complete, Step 1 BLOCKED pending a Mac.**
Plan-only. Executed by `swift-implementer`, gated by `swift-code-reviewer`. Closes **R1** of
`rich-summary-editor.md` (§208, §222, §230) — the one risk that plan left runtime-unverified.

> **Why this doc exists instead of a diff.** The implementation is determined by a fact that can
> only be observed in the running signed app on macOS 26: *what attribute does the native
> Font ▸ Bold / ⌘B actually write into the `AttributedString`?* The session that produced this plan
> ran on Linux with no Swift toolchain and no Xcode (`xcodebuild` → `ENOENT`), so it could not
> build, run, or even syntax-check a candidate implementation. Guessing the attribute and pushing
> uncompilable Swift would have put the green transform suite at risk for no gain. §2 below is the
> instrumentation to run; §3 is a decision table that turns each possible observation into a
> concrete diff. Everything after §2 is reasoned offline and ready to apply.

## 1. Goal & seam

Make the native macOS text affordances — the right-click context menu's **Font ▸ Bold / Italic**
and **⌘B / ⌘I** — actually apply and persist in the saved-meeting rich summary editor, without
changing the editor's look or breaking the byte-faithful markdown round-trip.

- **Seam:** `MarginaliaSummaryFormattingDefinition` (`AriKit/Sources/AriKit/DesignSystem/`) — the
  constraint pass that already runs over *every* editor mutation. Native commands are just another
  mutation; the fix is to teach the constraint pass to recognize what they write.
- **Unchanged contracts (hard):** `MeetingDetailViewModel.saveSummaryEdit`, `SummaryRepository`,
  and `MarginaliaMarkdownView`'s rendering paths. Zero lines.
- **Grammar ceiling:** unchanged — the closed `MarginaliaMarkdownBlock` set plus inline
  bold/italic. Native commands may not introduce constructs the grammar can't express.

### Why native formatting currently no-ops

Emphasis in this document is represented **solely as font identity**: bold is one specific
canonical `Font` value, `SummaryFontVariant.bold(for: kind)` (= `base(for: kind).bold()`). Two
pieces are coupled to that exact identity by `==`:

| Piece | File | Coupling |
|---|---|---|
| `SummaryFontConstraint` → `SummaryCanonicalFont.coerce(_:to:)` | `MarginaliaSummaryFormattingDefinition.swift:78-139` | Matches `container.font` against the canonical set; **anything unrecognized flattens to plain `base`**. |
| `SummaryRichText.emphasisSerialized` | `SummaryRichText.swift:237-254` | Recovers `**`/`*`/`***` by `run.font == SummaryFontVariant.bold(for: kind)` etc. |

So when the native command writes *its own* representation of bold — a system bold `Font` that is
not structurally `==` to ours, or a separate `\.fontWeight`, or an
`\.inlinePresentationIntent(.stronglyEmphasized)` — `coerce` doesn't recognize it and strips it.
The menu shows a checkmark, the text doesn't change, and it would never serialize to `**…**`.

### The scope-visibility trap (read this before instrumenting)

`AttributedTextValueConstraint.constrain(_ container: inout Attributes)` receives a proxy over the
**definition's `Scope`**, and `AttributeScopes.AriAttributes` currently declares only:

```swift
public let summaryBlock: SummaryBlockAttribute
public let swiftUI: SwiftUIAttributes
```

Consequences that shape the whole implementation:

1. **If the native command writes a Foundation attribute** (`\.inlinePresentationIntent`) **or an
   AppKit one** (`NSFont` via `\.appKit`), the constraint currently **cannot see it and cannot
   clear it.** Fixing this requires extending `AriAttributes` with `let foundation:
   FoundationAttributes` (and/or `appKit`) *before* any normalization can work. This is the single
   most likely reason a naive fix fails.
2. **A constraint may only write its own `AttributeKey`.** `SummaryFontConstraint`'s key is
   `FontAttribute`, so it *reads* the native signal but **cannot null it**. Clearing requires a
   second constraint keyed to that attribute. See §4.2 for the ordering hazard this creates.
3. Therefore Step 1 must dump **every** attribute on the run, not just in-scope ones — this is
   where the deleted `RichEditorSpike` was insufficient (it printed only
   `font = "set" | "—"`, never a value).

## 2. Step 1 — Instrumentation (MUST run on a Mac; blocks §3)

Add a temporary `#if DEBUG` run-dump beside the editor in `SummaryRichEditor.swift`. Unlike the old
spike, print **whole containers**, since the unknown may be out of scope:

```swift
#if DEBUG
    /// TEMPORARY — Step-1 instrumentation for docs/plans/native-text-formatting.md. Delete once
    /// the decision table in §3 is resolved and recorded.
    private var runDump: some View {
        let text = /* the focused segment's AttributedString */
        return ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(text.runs.enumerated()), id: \.offset) { index, run in
                    // `run.attributes` is the FULL container — prints attributes that are NOT in
                    // AriAttributes scope, which is exactly what we're hunting.
                    Text("[\(index)] \"\(String(text.characters[run.range]).prefix(24))\"\n\(String(describing: run.attributes))")
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }
#endif
```

**Procedure** (signed bundle — `tauri dev`-equivalent bare binaries are fine here since no TCC
permission is involved, but use the real app target):

1. Build & launch `Ari.xcodeproj` (XcodeBuildMCP `build_run_macos`).
2. Open a saved meeting → **Edit** the summary.
3. Select a word in a body paragraph. Record the dump (baseline).
4. Right-click → **Font ▸ Bold**. Record the dump. Diff against baseline.
5. Repeat for **Font ▸ Italic**, then **⌘B**, then **⌘I**, then Bold-then-Italic (combined).
6. Repeat steps 3–5 with the selection inside a **heading** and inside a **bullet item** (the
   canonical font family differs — `title2` / `headline` / `body` — and the answer may differ with it).
7. Also record what **Underline** and a **Color** write, for §5.

**Record verbatim in §3's "Observed" column, then delete the instrumentation.** Note explicitly
whether the constraint pass fired at all (does the dump show our canonical font restored, or the
native value persisting?) — R1's other half.

## 3. Decision table — observation → diff

Exactly one of these should match. All four share the funnel in §4.

| # | Observed | Response |
|---|---|---|
| **A** | `\.font` replaced with a non-canonical `Font` (e.g. a system bold), no other attribute changed | Add `Font.resolve(in:)`-based introspection to `SummaryCanonicalFont`: resolve the incoming font and read its weight/italic traits rather than relying on `==`. Map to `SummaryFontVariant.{bold,italic,boldItalic}(for: kind)`. **No scope change needed.** Lowest-risk outcome. |
| **B** | A separate `\.fontWeight` (SwiftUI `FontWeightAttribute`) appears, font untouched | Read `container.fontWeight` in `SummaryFontConstraint`; treat `.bold`/`.heavy`/`.black`/`.semibold` as bold. Add `SummaryFontWeightConstraint` (key `FontWeightAttribute`) forcing `nil`. **No scope change** (it's in `SwiftUIAttributes`). Mind §4.2 ordering. |
| **C** | `\.inlinePresentationIntent` gains `.stronglyEmphasized` / `.emphasized` | **Extend `AriAttributes` with `let foundation: FoundationAttributes`** first — otherwise invisible. Then read the intent in `SummaryFontConstraint` and add `SummaryInlineIntentConstraint` (key `InlinePresentationIntentAttribute`) forcing `nil`. Precedent for the type exists at `AriKit/Sources/AriViewModels/RichNotes.swift:86-89`. |
| **D** | An AppKit `NSFont` / `.appKit` attribute appears | Extend `AriAttributes` with `let appKit: AppKitAttributes`; derive emphasis from `font.fontDescriptor.symbolicTraits` (`.bold` / `.italic`) exactly as `RichNotes.swift:85-88` already does; clear via a dedicated constraint. Highest-friction outcome — confirm before committing to it. |

**If the dump shows the constraint pass never fires on native commands at all**, none of the above
helps: fall back to the route `rich-summary-editor.md` §230 already sanctions — intercept ⌘B/⌘I
with explicit `keyboardShortcut` commands routed to the *already-working, already-compiling*
`SummaryEditing.toggleBold` / `toggleItalic` (`SummaryEditing.swift:20-39`) via
`SummaryEditorModel.toggleBold()`. That covers the shortcuts but **not** the context menu; in that
case the Font submenu items must be treated as §5 non-grammar items (stripped), and this should be
recorded as a known limitation rather than papered over.

## 4. Implementation shape (applies to all outcomes)

### 4.1 One funnel, one representation

Do **not** fork the mapping. `SummaryFontVariant` stays the single font source. Extend
`SummaryCanonicalFont` with one pure, testable entry point:

```swift
/// The emphasis a run carries, from ANY representation: our canonical font identity, or the
/// native signal discovered in Step 1. Pure — no SwiftUI environment, no isolation requirement.
struct SummaryEmphasis: Equatable { var bold: Bool; var italic: Bool }

/// Reads emphasis from the union of (canonical font identity, native signal), preferring the
/// native signal when present — a native command's intent is newer than the font it replaced.
static func emphasis(
    ofFont font: Font?, nativeSignal: SummaryNativeEmphasis?, for kind: SummaryBlockKind
) -> SummaryEmphasis
```

`SummaryFontConstraint.constrain` then becomes: resolve `kind` → read emphasis from the union →
write `container.font = SummaryCanonicalFont.font(for: kind, bold:italic:)`. The existing
`coerce(_:to:)` collapses into this path; keep its "unrecognized → plain base" default, which is
what makes foreign paste safe.

**Idempotence is required** (the pass runs on every mutation): applying the funnel to its own
output must be a fixed point. This is directly testable — see §6.

### 4.2 Ordering hazard (call out to the reviewer)

The font constraint *reads* the native signal; a separate constraint *clears* it. If the clearing
constraint runs first, the font constraint sees nothing and the emphasis is lost. The existing
code's comment asserts constraint order is "only for clarity" and the constraints are
order-independent — **that assumption no longer holds** once one constraint's input is another's
output. Two acceptable resolutions, decide with the Step-1 build in hand:

1. **Preferred:** verify empirically that `body` composition order is sequential, place
   `SummaryFontConstraint` before the clearing constraint, and comment the dependency loudly.
2. **Order-independent alternative:** don't clear at all — instead have the *rendering* be driven
   purely by `\.font` and accept a vestigial signal. **Rejected by default**: it violates "exactly
   one representation" and risks double-bold rendering. Only take it if (1) proves unreliable.

### 4.3 Appearance is not allowed to change

Fonts stay on the canonical Marginalia ramp; `SummaryInkConstraint` continues to own ink, so
scheme-correctness is unaffected. Verify light **and** dark before/after screenshots.

## 5. Non-grammar formatting (No-Fake-State)

The Marginalia grammar has no representation for Underline, Outline, Strikethrough, or Colors.
Leaving those menu items toggling a checkmark with no durable effect is a No-Fake-State violation.

- **Colors are already neutralized** — `SummaryInkConstraint` unconditionally overwrites
  `foregroundColor` every pass. That is *already* a dead checkmark today and is in scope to note,
  not to newly break.
- **Decision: strip in the constraint, don't try to remove the menu items.** The Font/Colors
  submenus come from AppKit's standard text-view context menu; SwiftUI's `TextEditor` exposes no
  supported hook to prune them without dropping to an `NSViewRepresentable`, which would be a far
  larger change than this task warrants and would put the whole editor surface at risk. Stripping
  is explicitly sanctioned by the task.
- Add constraints forcing `nil` for `UnderlineStyleAttribute`, `StrikethroughStyleAttribute`, and
  `BackgroundColorAttribute` (all in `SwiftUIAttributes`, so no scope change).
- **Keep** Cut/Copy/Paste/Look Up/Bold/Italic working.

## 6. Tests (add; all pure-function, run in the existing suite)

New `AriKit/Tests/AriKitTests/SummaryNativeEmphasisTests.swift` (Swift Testing, matching the
existing suites' style):

1. Native bold signal + plain canonical font → `bold(for: kind)`, for each of the three font
   families (`paragraph`, `heading(1)`, `heading(3)`).
2. Native italic signal over an already-canonical **bold** font → `boldItalic(for: kind)` (the
   axes compose; neither is lost).
3. Native signal on a **foreign** font → canonical emphasis for the kind, foreign face discarded.
4. **Idempotence:** funnel(funnel(x)) == funnel(x) for every (font × signal × kind) combination.
5. Non-grammar strip: underline/strikethrough/background constraints yield `nil`.
6. **End-to-end:** a run carrying the native signal, pushed through
   `SummaryRichText.serialize`, emits `**…**` / `*…*` / `***…***`.

**Preserve unchanged:** the whole `SummaryEditDocument` / `Presenter` / `Serializer` suite,
specifically the block-stable round-trip (test 20) and fixed-point (test 21) invariants.

## 7. Acceptance

- [ ] Right-click **Font ▸ Bold** and **Font ▸ Italic** visibly format the selection.
- [ ] **⌘B** / **⌘I** do the same.
- [ ] Both survive **Save → reopen** as `**…**` / `*…*` — verified by reading `bodyMarkdown` from
      the store, not by eye.
- [ ] Non-grammar formatting is cleanly prevented; no dead checkmarks beyond the documented
      AppKit-menu limitation in §5.
- [ ] The inline Liquid-Glass bar still works (Bold, Italic, Heading, Body, Bulleted, Numbered).
- [ ] Editor appearance unchanged in light **and** dark (screenshot diff).
- [ ] Round-trip suite green; new §6 tests green.

## 8. Constraints & invariants (hard)

Swift 6 strict concurrency — no `@unchecked Sendable`, no `nonisolated(unsafe)`. macOS 26 floor —
no `@available` shims. `@Observable`-MVVM. Marginalia design system. The closed
`MarginaliaMarkdownBlock` grammar and byte-faithful round-trip are load-bearing. Do not touch
`MeetingDetailViewModel.saveSummaryEdit`, `SummaryRepository`, or `MarginaliaMarkdownView`.

## 9. Files

**Change:** `AriKit/Sources/AriKit/DesignSystem/MarginaliaSummaryFormattingDefinition.swift`
(constraints + `SummaryCanonicalFont`), `SummaryBlockAttribute.swift` (scope extension — only if
outcome C or D). **Read/verify:** `SummaryRichText.swift` (`SummaryFontVariant`, `serialize`),
`SummaryEditing.swift` (toolbar transforms must keep producing identical values).
**Temporarily instrument, then revert:** `Ari/UI/MeetingDetails/SummaryRichEditor.swift`.
**Add:** `AriKit/Tests/AriKitTests/SummaryNativeEmphasisTests.swift`.
