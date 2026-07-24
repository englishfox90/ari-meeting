# Plan: Native SwiftUI "Ask" / recall chat UI

## 0. Framing & what differs from the initial brief

This is **net-new Swift UI**, not a port of a frozen Rust feature. The recall *engine* port (F7) already landed in `AriKit/Sources/AriKit/Recall/`; this task wires it to a UI. It lands on the Swift side of the store/recall seam (migration principle 8) and closes the single largest "AriKit can do it / the app can't" gap in `plans/swift-migration-plan.md`.

Corrections verified against source:

- `RecallStream.swift` lives in `Recall/Orchestrator/`, not `Recall/Shell/`. Signatures as briefed.
- **`AskConversationStore` is already exposed** on `AppDatabase` as `public nonisolated var askConversations` (`AppDatabase.swift:96-98`). No new store construction needed; UI goes through `db.askConversations` (the writer is module-internal).
- **The conversation store cannot represent series-scoped threads.** `AskConversation.meetingId` is `MeetingID?` only (`nil` = global); `list/create` key on `meetingId` exclusively. No `seriesId` column. **Blocking open decision — see §12.**
- **`speakers` is always `[]` today** (`PeopleContext.attachPeople` is an honest no-op until diarization labeling). Person tags render only when non-empty → effectively never shown yet (No-Fake-State).
- `StoreBackedRecallSettingsReading` (app target) already conforms to `RecallSettingsReading`; `KeychainSecretStore()` conforms to `RecallSecretsReading`.
- **The engine already reconciles citations** before the UI sees text: `.done` carries a citation-verified answer; invalid `[S<n>]` and out-of-range/global `@ref(MM:SS)` are already stripped. **The UI must not re-verify** — it only tokenizes the already-safe string for display.

## 1. Goal & seam

Connect the built `RecallEngine` (+ `AskConversationStore`) to two SwiftUI surfaces sharing one console body:

1. The `.ask` sidebar route (section already exists; renders a placeholder at `RootSplitView.swift:191-192`).
2. An app-wide amber floating "AI" button (bottom-right) opening an overlay chat panel, mounted inside `readyShell` so it is absent during launch/import/failed/onboarding.

Seam #2 (DB/repository) + seam #4 (summary/context) consumed read-only through the engine. No engine behavior is re-implemented in the UI.

## 2. Module & file layout

### New files
**`AriKit/Sources/AriViewModels/Ask/`** (headless, testable):
- `AskScope.swift` — scope value type + `AskScopeResolver`.
- `AskViewModel.swift` — `@MainActor @Observable` console VM (closure-injected designated init + `public convenience init`).
- `AskTranscriptItem.swift` — render model for one chat row (user/assistant/thinking/error) + `[RecallSource]`.

**`Ari/UI/Ask/`** (app target):
- `AskConsoleView.swift` — shared console body (list, composer, empty/thinking/error states, recent list).
- `AskPageView.swift` — the `.ask` route host.
- `AskOverlayHost.swift` — app-wide FAB + overlay panel.
- `AskAnswerText.swift` — inline `[S<n>]` → chip + `@ref(MM:SS)` → non-interactive pill tokenizer (display-only; no verification).
- `AskSourceCard.swift` + `AskSourcePopover.swift` — source rendering (person tags gated on non-empty `speakers`).
- `AskScopePill.swift` — This meeting / This series / All meetings toggle.

**Tests** — `AriKit/Tests/AriViewModelsTests/Ask/AskViewModelTests.swift`, `AskScopeResolverTests.swift` (Swift Testing; stubs `StubRecallSettingsReading`/`StubRecallSecretsReading`/`StubLLMClient`).

### Files to edit
- `Ari/App/AppEnvironment.swift` — construct + expose `RecallEngine` (§6).
- `Ari/UI/AppShell/RootSplitView.swift` — replace `.ask` placeholder with `AskPageView`; attach `AskOverlayHost` in `readyShell`.
- No sidebar edit — `.ask` row already renders.

## 3. Public Swift surface

### `AskScope` (`AriViewModels`)
```
public enum AskScope: Sendable, Hashable {
    case global
    case series(SeriesID, title: String)
    case meeting(MeetingID, title: String)
}
```
`.meeting` → engine `meetingId`; `.series` → `seriesId`; `.global` → neither. `persistenceKey` helper resolves to the store's scope key for all three (meeting id / series id / nil-global) — series now persistable after the Phase 0 store change (§12).

### `AskScopeResolver` (pure)
Given a minimal nav descriptor (current `SidebarSection` + top-of-`path`), returns precedence-ordered `availableScopes` and a narrowest `defaultScope`. Series offered only when `db.series.seriesIds(forMeeting:)` is non-empty. Pill row shows only when `available.count > 1`. `AriViewModels` never imports the app-target `SidebarSection`.

### `AskViewModel` (`@MainActor @Observable`)
State (`private(set)`, honest): `scope`, `availableScopes`, `items: [AskTranscriptItem]`, `composerText` (bindable), `isStreaming`, `recentConversations`, `activeConversationId`, `suggestionChips` (scope-aware static copy).

Closure-injected `@Sendable` operations: `streamAnswer`, `listConversations`, `loadConversation`, `createConversation`, `appendMessage`, `deleteConversation` (see §12). `public convenience init(recallEngine:conversationStore:scope:)` composes the real engine/store. Methods: `send()`, `setScope(_:)`, `newConversation()`, `load(_:)`, `delete(_:)`, `loadRecent()`.

## 4. Concurrency model
- `AskViewModel` is `@MainActor`; all published state mutates on main.
- Engine work is off-main: `RecallEngine` is `Sendable`; its stream producer runs in an internal `Task`; `AppleContextualEmbedder` is an `actor`. Retrieval/prompt/LLM streaming never touch main.
- Cancellation: VM holds `streamTask: Task<Void, Never>?`. `send()`/`setScope()` cancel then restart. `AsyncThrowingStream.onTermination` cancels the engine's producer, so cancelling the consumer tears down the chain. Scope change drops the half-streamed placeholder (No-Fake-State).
- First-ask latency: embedder may OTA-download once; honest `.thinking` row covers it; semantic arm degrades to lexical-only on failure, never fails the ask.
- All injected closures `@Sendable`; all crossed types `Sendable`. No `@unchecked Sendable`.

**Streaming accumulation:** on `send()`, append user row + empty `.assistant(streaming)` placeholder; per `.delta` append text; on the single `.done`, **replace** accumulated text with `response.answer` (reconciled) and attach `response.sources`. On error, drop placeholder, append `.error` row.

## 5. Persistence
No new schema (subject to §12). Reuse `db.askConversations`: `list(meetingId:)`/`get(_:)`/`create(meetingId:title:)`/`appendMessage(conversationId:role:content:sources:)`. 7-day auto-prune. Per ask (meeting/global): lazily `create` on first user message (title = first ~40 chars), append user, then on `.done` append assistant with `sources`. Recent list = `list(meetingId:)`. Only `user`/`assistant` roles written. Series-scoped threads persist too after the Phase 0 store change (§12); delete via the new `AskConversationStore.delete(_:)`.

## 6. AppEnvironment wiring
Inside `bootstrap()`, reusing the existing MLX `clientFactory` local:
```
let embedder = AppleContextualEmbedder()
let hybridSearch = HybridSearch(recallIndex: db.recallIndex, meetings: db.meetings,
    summaries: db.summaries, transcripts: db.transcripts, embedder: embedder)
let peopleContext = PeopleContext(persons: db.persons, profileFacts: db.profileFacts,
    calendarEvents: db.calendarEvents)
let recallEngine = RecallEngine(db: db, hybridSearch: hybridSearch, peopleContext: peopleContext,
    settings: StoreBackedRecallSettingsReading(database: db), secrets: KeychainSecretStore(),
    clientFactory: clientFactory)   // MLX-aware — REQUIRED; default omits MLX and .mlx configs throw
self.recallEngine = recallEngine
```
Expose `private(set) var recallEngine: RecallEngine?`. `AskConversationStore` needs no new property (`database.askConversations`). The MLX factory is non-negotiable (product default is `.mlx`).

## 7. Two surfaces + FAB attachment
- **`AskPageView`** (`.ask` route): `AskConsoleView` at global scope + recent list; no scope pill. `MarginaliaCanvasWash`.
- **`AskOverlayHost`**: `.overlay(alignment:.bottomTrailing)` inside `readyShell`; collapsed amber FAB → floating panel hosting `AskConsoleView` with a scope pill. Absent during `.launching/.importing/.failed`/onboarding. **Suppressed when `selectedSection == .newMeeting`, during active recording, and on the `.ask` page** (one Signal per screen — recording owns the red Signal).
- **Scope auto-derivation** from `selectedSection` + top of `path`: meeting detail → `[.meeting,.series?,.global]`; series detail → `[.series,.global]`; else `[.global]`. Override confined to `availableScopes`; changing it cancels in-flight + starts a fresh thread. "Open meeting →" appends `MeetingID` to `path`.

## 8. Marginalia tokens per piece
- FAB: `MarginaliaButtonStyle` `.primary` `.large`, symbol `sparkle.magnifyingglass`, `Color.marginalia(.accent, in: scheme)` — legitimate ≤8% amber Signal.
- Panel/canvas: `MarginaliaCanvasWash`; surface `.surface`, border `.hairline`.
- User bubble: `.elevated`/`.surface`; text `.marginaliaTextStyle(.body)`.
- Assistant text: `.marginaliaTextStyle(.body)`; headings `.inkHeading`.
- `[S<n>]` chip: `.caption`, ink `.inkSecondary` on `.surface` (accent only on hover/press). Tap → popover.
- `@ref(MM:SS)` pill: non-interactive `.caption` `.inkSecondary`, no accent, no tap (display-only, honest).
- Scope pill: unselected `.quiet`; selected `.selectionWash`, never accent.
- Thinking: `.inkSecondary` dots + "Searching local meeting excerpts…".
- Empty state: `DictationMark` + `.inkSecondary` heading + privacy line + scope-aware suggestion chips (`.quiet`).
- Error: `MarginaliaBanner` `.error` with `error.localizedDescription` verbatim + "Open Settings" for model errors.
- Source card: `.surface`+`.hairline`; person tags only when `speakers` non-empty (max 4).

## 9. Invariants preserved
- **Never-invents-citations / No-Fake-State**: render only the engine's reconciled answer + engine-built sources; never re-verify; `[S<n>]` resolves strictly to `sources[n-1]`; person tags only when truthfully populated.
- **Loopback-only / bounded context / unsupported-refusal**: entirely inside the engine; UI only surfaces `RecallEngineError.localizedDescription` verbatim.
- **History windowing**: pass last 8 turns; engine re-clamps.
- **Single DB owner**: all persistence via `db.askConversations`.
- Engine invariant suite (`RecallEngineTests`) is the baseline; this UI adds no bypass.

## 10. Acceptance tests (Swift Testing, written first)
1. Streaming accumulation (deltas show mid-stream).
2. Final `.done` replaces accumulated raw text.
3. Sources attach only from `.done`; no person tags when `speakers:[]`.
4. Error surfacing verbatim + "Open Settings" flag.
5. Empty-question guard (no-op).
6. History windowing to last 8, alternating roles, newest kept.
7. Scope derivation precedence (meeting/series/global; no series when absent).
8. Scope override cancels in-flight + drops placeholder + clears thread.
9. New question mid-stream cancels prior.
10. Conversation persist (create once, append user then assistant-with-sources).
11. Conversation load hydration in order incl. sources.
12. Recent list keyed to scope (`nil` for global).
13. Unsupported-question frozen refusal copy verbatim.
14. `AskAnswerText` tokenizer: text runs + chip + non-interactive pill; defensive literal fallback.

## 11. Sequencing
- **Phase A** — `AskScope`/`AskScopeResolver`/`AskViewModel` + tests 1–13; AppEnvironment wiring. Gates everything.
- **Phase B** — `AskConsoleView` + `AskAnswerText` (test 14) + source card/popover; replace `.ask` placeholder with `AskPageView`. Usable page.
- **Phase C** — `AskOverlayHost` FAB/panel, scope pill, auto-derivation, suppression.
- **Phase D** — `AskConversationStore` create/append/list/load; per-scope recent lists; delete (pending §12).
- **Phase E** — suggestion chips, keyboard (Enter/Shift+Enter, 1000-char cap), accessibility, reduce-motion.

## 12. Resolved decisions (settled with user)
1. **Series-scoped conversation persistence — ADD `seriesId` to the store now.** This task includes an AriKit store change (Phase 0): a nullable `seriesId TEXT` column on the `ask_conversations` table via an **additive migration**, `AskConversation.seriesId: SeriesID?`, and `list(seriesId:)`/`create(seriesId:title:)` overloads (or a generalized scope key so exactly one of meeting/series is set, or neither = global). Series threads then persist + reload like meeting/global. Preserve the single-DB-owner rule and 7-day prune. Use the `grdb` + `sqlite-schema` skills.
2. **Conversation delete — ADD a delete method now.** `AskConversationStore.delete(_ id:)` (deletes the conversation + its messages), plus a delete affordance in the recent list. Covered by a store test.
3. **Overlay host layer** — detail-column-trailing (never covers the rail).

## Phase 0 (prepended to §11 sequencing): AriKit store change
Before Phase A: add the `seriesId` column migration, extend `AskConversation`/`AskConversationStore` (series overloads + `delete`), and add store tests (series create/list/get round-trip; delete removes conversation + messages; 7-day prune unaffected; global/meeting keying unchanged). This is the only engine-side change; everything else is UI + wiring. ⚠️ **The `askConversation.seriesId` in-place addition to `v1_baseline` was the LAST legal in-place edit — the baseline was FROZEN on 2026-07-22 after it (with `eraseDatabaseOnSchemaChange`) silently wiped a real DB; future changes are new `v2+` migrations (`docs/plans/robust-migration-and-backup.md`).**
