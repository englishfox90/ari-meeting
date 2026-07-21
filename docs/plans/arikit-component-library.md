# AriKit — Marginalia Component Library + Design Gallery — plan

> **STATUS: PLAN.** Gates the component-library build-out for the native `Ari` macOS app (and future iOS `Ari Lite`). Extends the S6 read-UI (`docs/plans/arikit-native-read-ui.md`) and the button-system precedent (`AriKit/Sources/AriKit/DesignSystem/MarginaliaButtonStyle.swift`). PLAN ONLY — the architect writes no code.

## 1. Goal & seam

**Goal.** Turn the requested UI into real, reusable, editable-and-live Marginalia components — edit the component, and both the app and the DEBUG Design Gallery update — then showcase each in the gallery. Three tiers: (1) foundational primitives, (2) transcript+list extraction, (3) AI/Ask+chat UI.

**Seam & phase.** Phase 2 native shell, on the **target Swift side**. This is **net-new Swift UI**, not a port of a frozen Rust feature — it factors the existing S6 SwiftUI screens (`Ari/UI/**`, already landed) into a shared component layer and adds net-new primitives. The Rust/React app is untouched. The Ask/chat tier renders **UI only** over already-landed AriKit Recall value types (`AskMessage`, `RecallSource`); it does **not** wire the `RecallEngine` flow (that is the separate Ask-screen feature that fills the `.ask` sidebar placeholder, `RootSplitView.swift:77`).

**WIP check.** One feature, one phase. This work is additive to S6 and does not open a second migration phase. The **Ask conversation screen** (streaming `RecallStream` → live bubbles, filling `.ask`) is a *separate* follow-on feature — this plan builds the *bubble component* it will consume, with sample data, and explicitly stops at the component boundary. Flagged in §8.

## 2. Architectural split: where components live

Two homes, decided by one line: **does the component reference domain `Models`/`Recall` types?**

- **Generic primitives → `AriKit/Sources/AriKit/DesignSystem/`.** They must stay domain-free (generic over passed-in data / bindings), so both the macOS `Ari` app and the future iOS `Ari Lite` consume them (BRAND.md §10 rationale, encoded in `MarginaliaColor.swift:8`; resolved S6 decision `arikit-native-read-ui.md` §2.2).
  - **New precedent, sanctioned:** DesignSystem today ships only tokens/styles/modifiers — no standalone `View` structs. Tier-1 introduces the first `View` structs into DesignSystem. Constraint that keeps it honest: **DesignSystem must not `import` Models/Recall/AriViewModels** — a primitive that needs a domain type is misfiled and belongs in the app.
- **Domain/app components → `Ari/UI/Components/`** (Xcode `Ari` target, `PBXFileSystemSynchronizedRootGroup` — new files auto-include). Anything referencing `Transcript`, `AskMessage`, `RecallSource`, `LoadState` lives here, alongside `CardRow`/`StateContainer`/`SectionHeader`/`MarkdownText`.

**Testability consequence (drives §6).** AriKit/DesignSystem code is unit-testable via `swift test` (`AriKitTests`). App-target `Ari/UI/**` views are **not** in any `swift test` harness (they build under `xcodebuild`). Therefore: every tier-1 primitive gets a **plain-data spec type + Swift Testing parity test in `AriKitTests`**, mirroring `MarginaliaButtonStyleParityTests.swift`; every tier-2/3 domain view gets **gallery visual coverage**, and any pure logic it needs is pushed **down into an AriKit function** so it can be parity-tested (timecode formatter; citation label).

**Universal conventions.** Every component takes an explicit `scheme: ColorScheme` read at the call site via `@Environment(\.colorScheme)` (the established pattern, `MarginaliaButtonStyle.swift:93`). Value-type SwiftUI; `@Observable` classes only where state is genuinely stateful (the toast presenter, deferred). No TCA. Theme purely from Marginalia tokens. SF Symbols only (BRAND.md §7). Stock controls first (BRAND.md §9).

## 3. Concurrency model (Swift 6 strict)

- All components are SwiftUI `View`s → implicitly `@MainActor`. No off-main work — pure render surfaces.
- All spec/enum/config types are `Sendable` plain data (mirrors `MarginaliaButtonSpec: Sendable, Equatable`). Generic value parameters constrain to `Hashable` (segmented control).
- The **only** stateful piece is the optional toast presenter (deferred): if built, `@MainActor @Observable` with a `Task`-based auto-dismiss timer — no `@unchecked Sendable`, no `nonisolated(unsafe)`.
- The chat bubble is **render-only**: streaming (`RecallStream` → `AsyncThrowingStream`) is consumed by a *future* Ask view model in `AriViewModels` (off this plan's scope); the bubble takes finished/accumulating `content: String` + `sources: [RecallSource]` and never touches the stream.

## 4. Persistence

**None.** No component touches the database. The chat bubble consumes `AskMessage`/`RecallSource` **values** passed in by a caller; the single-DB-owner rule is unaffected.

## 5. Components — per-component spec

### Wave 0 (prerequisite): shared timecode formatter — AriKit

`MM:SS` is duplicated verbatim in `AudioPlayerBar.swift:33` and `TranscriptListView.swift:64`. Tier 2 adds a third caller. DRY it first.

- **Home:** `MarginaliaTimecode.mmss(_ seconds: Double) -> String` in `AriKit/Sources/AriKit/DesignSystem/MarginaliaTimecode.swift` (pure, Sendable enum namespace).
- **API:** `public enum MarginaliaTimecode { public static func mmss(_ seconds: Double) -> String }`. Verbatim logic (`Int(seconds.rounded())`, `%02d:%02d`).
- **Acceptance:** `MarginaliaTimecodeTests` — `0→"00:00"`, `61→"01:01"`, `599→"09:59"`, `89.6→"01:30"`.
- **Extraction safety:** `AudioPlayerBar` and `TranscriptListView` swap their private `timecode` static for `MarginaliaTimecode.mmss` — identical output.

### Tier 1 — Foundational primitives (all → AriKit/DesignSystem)

**1.1 Text field / search input.** `MarginaliaTextField(text:prompt:scheme:)` wraps stock `TextField(.plain)`; `MarginaliaSearchField(text:prompt:scheme:onSubmit:)` adds a leading `magnifyingglass` + trailing `xmark.circle.fill` clear button (shown only when `!text.isEmpty`), focus via `@FocusState`. `.surface` fill, `MarginaliaRadius.control`, `.hairline` stroke → `.accent` on focus. Height 26pt. Spec `MarginaliaFieldSpec { fill:.surface, stroke:.hairline, focusStroke:.accent, radius:.control, height:26 }` + `MarginaliaFieldSpecParityTests`.

**1.2 Dropdown (Menu/Picker).** `MarginaliaMenuLabel(title:scheme:)` — themed closed-state label (title + `chevron.up.chevron.down`, `.surface`/`.hairline`/`.control`, 26pt), matching the text field. Callers use stock `Picker(.menu)` (bound selection) or stock `Menu { } label: { MarginaliaMenuLabel }` (actions); popover is stock system material. Reuses `MarginaliaFieldSpec`; parity test asserts the shared spec + `chevronSymbol` constant.

**1.3 Segmented switcher.** `MarginaliaSegmentedControl<Value: Hashable>(selection:segments:scheme:)` with `MarginaliaSegment<Value>{value,title,id}`. Reproduces `MeetingDetailView.sectionSwitcher` exactly — selected `.buttonStyle(.marginalia(.secondary,.regular,in:))`, unselected `.marginalia(.quiet,.regular,in:)` (NOT solid accent — preserves `accentSolidFillExclusive`). `role(selected:) -> MarginaliaButtonRole` + `MarginaliaSegmentedControlParityTests` (selected→`.secondary`, unselected→`.quiet`).

**1.4 Badge / chip.** `MarginaliaBadge(_:style:symbol:scheme:action:)` — tappable when `action` non-nil. `MarginaliaBadgeStyle{neutral,accent,success,recording}` → (fill,label,stroke): neutral `.elevated`/`.inkSecondary`/`.hairline`; accent `.selectionWash`/`.accent`/none (the citation/selection look, accent-allowed); success `.success` + required `checkmark.seal`; recording `.recordingRed` + required `record.circle`. `MarginaliaRadius.control`. `spec -> (fill,label,stroke)` + `MarginaliaBadgeStyleParityTests` (roles + required-symbol on success/recording).

**1.5 Labeled toggle row.** `MarginaliaToggleRow(_:description:isOn:scheme:)` — stock `Toggle(.switch)` tinted by the app-root global `.tint(AccentShinKai)` (BRAND.md §10; do not hand-color). Title `.body`, description `.callout`/`.inkSecondary`. Gallery-only coverage (nothing to lock beyond ramp roles).

**1.6 Toast / banner.** `MarginaliaBanner(kind:message:action:scheme:)` — the inline **view** ships now. `MarginaliaBannerKind{info,success,error}` → leading SF Symbol (`info.circle`/`checkmark.seal`/`exclamationmark.triangle`) + tint (`.inkSecondary`/`.success`/`.recordingRed`), always with label. `.surface`/`.hairline`/`MarginaliaRadius.card`. `kind.spec -> (symbol,tint)` + `MarginaliaBannerStyleParityTests`. **Deferred:** the transient auto-dismiss presentation mechanism (`.marginaliaToast` + `@Observable ToastCenter`).

### Tier 2 — Transcript + list extraction (→ Ari/UI/Components, domain)

**2.1 `TranscriptSegmentRow`.** `Ari/UI/Components/TranscriptSegmentRow.swift`. `TranscriptSegmentRow(line:Transcript, speakerName:String?, onSeek:(Double)->Void)` — the exact shape of today's private `TranscriptLineView` (`TranscriptListView.swift:38`). Lift the body verbatim, replace the private struct's use (`TranscriptListView.swift:29`), swap `timecode` for `MarginaliaTimecode.mmss`. No style change (`.subheadline` speaker, `.quiet` timecode button, `.body` text). Gallery section with a DEBUG `Transcript.sample` fixture.

**2.2 `CardListScaffold`.** `Ari/UI/Components/CardListScaffold.swift`. Generic `<Item: Identifiable, Destination: Hashable>` wrapping `StateContainer → List(.inset) → NavigationLink(value:) → CardRow`, `.background(.canvas)`, `.navigationTitle`. `MeetingsListView`/`PeopleListView`/`SeriesListView` are structurally identical → refactor each `body` to one call. **Keep** each screen's `@State viewModel` + `.task { await viewModel.observe() }`. Identical rendering + navigation values. Existing list-VM tests stay green.

### Tier 3 — AI/Ask + chat UI (→ Ari/UI/Components, domain; UI only)

**3.1 `AskButton`.** `Ari/UI/Components/AskButton.swift`. `AskButton(title:"Ask", scheme:, action:)` — `sparkles` symbol + title, built on `.buttonStyle(.marginalia(.quiet,.regular,in:))` so it does not consume the screen's single solid-accent primary slot. No fake "thinking…" affordance. Gallery section; expose `AskButton.symbol` for a cheap assert.

**3.2 `AskMessageBubble`.** `Ari/UI/Components/AskMessageBubble.swift`. `AskMessageBubble(message:AskMessage, scheme:, onSelectSource:((RecallSource)->Void)?)`. User turn: trailing, `.elevated`/`.surface` bubble. Assistant turn: leading, `.surface`, `content` via `MarkdownText`; then **only if `!message.sources.isEmpty`** a wrapped row of `MarginaliaBadge(.accent, symbol:"text.quote", action:)` chips labeled `[S1]…[Sn]`, tappable → `onSelectSource`. **No-Fake-State (load-bearing):** chips render **only** from `message.sources` (app-supplied, `AskConversation.swift:41`), never parsed from `content`; empty sources → no chip row. Render-only, `@MainActor`. Pushdown: `AskCitationLabel.forIndex(_:) -> String` (`"[S\(i+1)]"`) in AriKit + test. Gallery samples: user; assistant w/ sources; assistant w/ empty sources (honest no-chip case).

## 6. Acceptance tests (written first)

`AriKitTests` (Swift Testing, mirroring `MarginaliaButtonStyleParityTests`):
1. `MarginaliaTimecodeTests`
2. `MarginaliaFieldSpecParityTests`
3. `MarginaliaSegmentedControlParityTests` (selected→`.secondary`, unselected→`.quiet`)
4. `MarginaliaBadgeStyleParityTests` (roles + required-symbol on success/recording)
5. `MarginaliaBannerStyleParityTests` (kind→symbol/tint; always-labeled)
6. `AskCitationLabelTests` (`forIndex(0)=="[S1]"`)
7. Symbol-constant asserts for `AskButton`/`MarginaliaMenuLabel` (if constants exposed)

App-target views: Design Gallery is the visual acceptance surface — each component gets a section. The three refactored list screens are guarded by existing, unchanged `AriViewModelsTests`.

### Gallery mapping
- **New `Ari/UI/DesignSystem/DesignGalleryPrimitivesView.swift`** — tier 1 (field, search, menu-label, segmented, badges, toggle row, banner), live/interactive, wrapped in `.galleryComponentSurface(glass:scheme:)` where a container surface applies.
- **Extend `DesignGalleryComponentsView.swift`** — add `TranscriptSegmentRow` + `CardListScaffold` samples.
- **New `DesignGalleryAskView.swift`** — `AskButton` + `AskMessageBubble` (user/assistant/empty-sources).
- Wire both into `DesignGalleryView.body` (pass `scheme: previewScheme, glass: glassEnabled`). The existing light/dark picker + glass toggle cover them for free. All `#if DEBUG`.

## 7. Invariants preserved

- **No-Fake-State**: banners/badges/chips/bubble render only real passed-in data; empty → absent; chat citations come only from app-supplied `AskMessage.sources`, never parsed from model text — carrying the recall "never invents citations" invariant into the UI.
- **Signal Rule ≤8% + one-primary-per-view**: accent only on selection/citation/link (field focus, segmented-selected via `.secondary`, citation chips via `.selectionWash`+accent-text, `AskButton` via `.quiet`). No new solid-accent fills.
- **Warm-neutrals-only + two-ink**: every role via `Color.marginalia(_:in:)`; no cool grays, no hardcoded hex.
- **Stock-controls-first / SF-Symbols-only / no bespoke chrome**: `TextField`/`Toggle`/`Menu`/`Picker` stock and themed; symbols only; system materials for popovers.

## 8. Risks, open decisions & sequencing

**Sequencing (each step keeps `swift build` + `swift test` green; gallery grows incrementally):**
- **Wave 0** — `MarginaliaTimecode` + test; swap the two existing call sites.
- **Wave 1** — tier-1 primitives into AriKit/DesignSystem, one at a time (view + spec + parity test + gallery row). Order: **badge → toggle row → text/search field → menu-label → segmented control → banner view** (badge first: tier-3 chips depend on it; segmented before tier-2).
- **Wave 2** — tier-2 extraction, behavior-preserving: `TranscriptSegmentRow` + refactor `TranscriptListView`; `CardListScaffold` + refactor the three list screens; adopt `MarginaliaSegmentedControl` in `MeetingDetailView.sectionSwitcher`.
- **Wave 3** — tier-3 UI-only: `AskButton` + `AskMessageBubble` with sample data; gallery sections. No engine wiring.

**Out of scope (deferred features):** the transient toast presenter, and the live Ask conversation screen (streaming `RecallStream` → bubbles filling `.ask`).

**Open decisions (architect recommendation in parens):**
1. `AskButton` home — app `Ari/UI/Components` (rec) vs AriKit; default role `.quiet` (rec) vs `.primary`.
2. Toast — ship inline `MarginaliaBanner` now (rec), defer auto-dismiss overlay; app-level vs DesignSystem TBD.
3. Segmented — custom button-row (rec, preserves live look) vs stock `Picker(.segmented)`.
4. Speaker-name accent — preserve current ink (rec, extraction-safe) vs adopt BRAND §3 accent.
5. AriKit promotion of `TranscriptSegmentRow`/`AskMessageBubble` for iOS Lite (Phase 6) — defer.
6. Which dropdown mechanism(s) are actually needed (`Picker(.menu)` vs `Menu`).
