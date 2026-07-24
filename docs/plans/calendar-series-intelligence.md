# Calendar–Series Intelligence (detection + consent, ledger-on-add, linked-event card, strict 1:1)

Status: IMPLEMENTED (2026-07-23) — all four features + review fixes landed; 1135 AriKit tests green
Author: swift-architect, 2026-07-23
Rust incumbents read: `ari-engine/src/meeting_series/detection.rs:22-84`,
`frontend/src-tauri/src/calendar/sync.rs:28-131`, `ari-engine/src/database/repositories/calendar.rs:283-321`,
`ari-engine/src/database/repositories/meeting_series.rs:185-210`.

## 1. Goal & seam

Four features that close the last deferred hook of the S7 calendar port and finish the F9 series
loop on the Swift side:

1. **Series auto-detection in calendar sync** — the port of `detect_series_for_event`
   (`detection.rs:22-84`) called from `sync_range_core` (`sync.rs:72, 85-105`), explicitly
   deferred by `CalendarSyncEngine.swift:6-9` ("Series Track I", `docs/plans/arikit-calendar.md:223-224`,
   `docs/plans/arikit-engine-extras.md §3`). **Plus a product twist the Rust version lacks:** a
   visible consent affordance — no silent membership that feeds content into a ledger.
2. **Ledger fold on add-to-series** — wire `SeriesLedgerReducer.foldMeeting`
   (`SeriesLedgerReducer.swift:168`) to fire when a meeting with a finished summary is added to a
   series (manual and auto paths), fire-and-forget.
3. **Linked-calendar-event card on meeting detail** — surface the (at most one) linked event on
   `MeetingDetailView`, with unlink + link-picker, via a new reverse-lookup repository read
   (mirror of `get_event_by_meeting_id`, `calendar.rs:288`).
4. **Strict 1:1 meeting ↔ calendar event** — repository-transaction semantics + a partial UNIQUE
   index on `calendarEvent.meetingId`.

**Seam check (plan principle 8):** all four land on the target Swift side — AriKit
Calendar/Store/Engine + AriViewModels + the Ari app. The Rust app is frozen; feature 1 is a
port-with-divergence of a frozen Rust behavior (`detect_series_for_event` — the divergence, the
consent affordance, is net-new product behavior and is called out as such below); features 2–4 are
net-new Swift capability (the Rust app links silently and has no meeting-side event card).
This is one feature bundle inside the already-open calendar/series track — no second migration
phase is opened.

**Non-goal:** heuristic (no-calendar) series detection (`rescan_heuristic_series`,
`detection.rs:145-211`) is NOT ported here — Rust deliberately gates v1 detection on
seriesKey+recurrence (`detection.rs:4-6`) and so do we.

## 2. Module & surface

### 2.1 AriKit `Store` (feature 4 + reads for 1 and 3)

**`SchemaMigrator.swift` — extend `v1_baseline` in place** (its own documented policy while
unshipped, `SchemaMigrator.swift:7-17`; see §4 for the shipped-fallback):

- After the `calendarEvent` CREATE TABLE (`SchemaMigrator.swift:308-335`):
  ```swift
  try db.execute(sql: """
  CREATE UNIQUE INDEX idx_calendarEvent_meetingId
  ON calendarEvent(meetingId) WHERE meetingId IS NOT NULL
  """)
  ```
  (Partial index — tombstoned rows keep their `meetingId`, so the repository must clear
  competitors *including tombstoned rows*, below.)
- On the `series` CREATE TABLE (`SchemaMigrator.swift:254-270`), add:
  ```swift
  t.column("autoAddMode", .text).notNull().defaults(to: "ask")   // 'ask' | 'always' | 'never'
  ```

**`CalendarEventRepository.swift`:**

```swift
/// The (at most one) non-tombstoned event linked to `meetingId`
/// (← get_event_by_meeting_id, calendar.rs:288).
public func linkedEvent(forMeeting meetingId: MeetingID) async throws -> CalendarEvent?

/// Observation for the meeting-detail card (mirrors observeAll(), CalendarEventRepository.swift:214).
public func observeLinkedEvent(forMeeting meetingId: MeetingID) -> AsyncStream<CalendarEvent?>
```

Modify **in the same write transaction** (feature 4a): `setManualLink` (`:191`),
`setAutoLink` (`:175`), and `upsert` (`:57`, the legacy-importer path — `LegacyDatabaseImporter.swift:483`)
each first execute, when about to persist a non-nil `meetingId`:

```sql
UPDATE calendarEvent SET meetingId = NULL, linkSource = NULL
WHERE meetingId = :meetingId AND id <> :eventId
```

`setAutoLink` keeps its existing manual re-guard (`:180`) *and* must not steal a link **from** a
manually-linked event: the clearing UPDATE runs only after the guard passes, and adds
`AND (linkSource IS NULL OR linkSource <> 'manual')` — if the same meeting is manually linked
elsewhere, the auto link is skipped entirely (manual always wins, the standing S7 invariant,
`CalendarSyncEngine.swift:104-109`). `setManualLink`'s clearing UPDATE has no such filter (manual
may steal from anything).

**`SeriesRepository.swift`:**

```swift
/// Find a series by its stable recurrence key, INCLUDING tombstoned rows (seriesKey is UNIQUE,
/// SchemaMigrator.swift:256 — a tombstoned holder must be visible so detection can honor the
/// user's deletion instead of hitting the UNIQUE constraint). (← find_series_by_key)
public func findByKey(_ seriesKey: String) async throws -> Series?   // add `isDeleted` to Series? NO —
// return a small internal tuple instead: (series: Series, isDeleted: Bool), or expose
// `findByKeyIncludingDeleted` returning `(SeriesID, isDeleted: Bool)?`. Implementer's choice;
// do not add isDeleted to the domain Series type.

/// Membership rows for suggestion UI (linkSource == "suggested").
public func suggestedSeriesIds(forMeeting meetingId: MeetingID) async throws -> [SeriesID]
public func suggestedMeetingIds(inSeries seriesId: SeriesID) async throws -> [MeetingID]

/// Consent transitions — each ONE write transaction.
public func confirmSuggestedMember(seriesId: SeriesID, meetingId: MeetingID, at date: Date) async throws
// flips that seriesMember.linkSource 'suggested' → 'auto' AND sets series.autoAddMode = 'always'.
public func declineSuggestedMember(seriesId: SeriesID, meetingId: MeetingID, at date: Date) async throws
// deletes the suggested row AND sets series.autoAddMode = 'never'; if the series is left with
// ZERO member rows of any kind, tombstones the series (it only ever existed as a suggestion).
```

**Suggested rows are invisible to series *content* semantics.** Add
`WHERE (linkSource IS NULL OR linkSource <> 'suggested')` to:
- `seriesIds(forMeeting:)` (`SeriesRepository.swift:206`) — callers: ledger fold
  (`SeriesLedgerReducer.swift:170`), summary-context ledger injection
  (`SummaryContextAssembler.swift:186`), `AddToSeriesViewModel.load` (`:57`).
- `orderedMeetingIds(inSeries:)` (`:340`) — the `@mref` citation index; suggested members must not
  consume an index (No-Fake-State: citations only over accepted members).
- `meetingIds(inSeries:)` (`:192`) — callers: `SeriesDetailViewModel:62` docs, `RecallEngine.swift:217`
  (Ask-over-series must not read a meeting the user hasn't accepted into the series).
- `fetchSummaries` member aggregates (`:60-69`): `AND (sm.linkSource IS NULL OR sm.linkSource <> 'suggested')`
  on the `seriesMember` join — counts shown in UI are accepted members only.

`addMember` (`:217`) is unchanged (it already takes `linkSource`); detection uses INSERT-only
semantics via a new guard — see §2.2. **Deliberate divergence from Rust:** `upsert_member`
(`meeting_series.rs:198-199`) overwrites `link_source` on conflict, so Rust detection can downgrade
a manual membership to `auto`. Swift detection never writes over an existing row.

### 2.2 AriKit `Calendar` (feature 1)

**New file `AriKit/Sources/AriKit/Calendar/SeriesDetector.swift`:**

```swift
/// F9 series detection (← detect_series_for_event, detection.rs:22-84), consent-aware.
public struct SeriesDetector: Sendable {
    public enum Outcome: Sendable, Equatable {
        case skipped              // guards failed / existing membership / mode 'never' / deleted series
        case suggested(SeriesID)  // new 'suggested' membership written (mode 'ask')
        case autoAdded(SeriesID)  // new 'auto' membership written (mode 'always')
    }
    public init(database: AppDatabase)
    /// Guards (parity detection.rs:26-36): event.meetingId != nil, hasRecurrence == true,
    /// seriesKey non-empty after trim. Then find-or-create by key + insert membership per the
    /// series' autoAddMode. occurrenceTime = occurrenceDate ?? startTime (detection.rs:67-71),
    /// stored ISO-8601 (match the importer's existing occurrenceTime string convention).
    /// Idempotent: an existing seriesMember row for (series, meeting) — ANY linkSource,
    /// including a row another series holds is irrelevant — means .skipped, never an update.
    public func detect(for event: CalendarEvent, at now: Date) async throws -> Outcome
}
```

Series creation (no live series for key): title = event title, fallback `"Recurring meeting"`
(`detection.rs:45-49`); `autoAddMode = "ask"`; no ledger row. A **tombstoned** series holding the
key → `.skipped` (the user deleted it; never resurrect — consent).

**`CalendarSyncEngine.swift`:**

- `init(source:database:onAutoSeriesMembership: (@Sendable (MeetingID) async -> Void)? = nil)` —
  the fold hook for the consented `'always'` path only.
- New `private func runSeriesDetection(in range: ClosedRange<Date>) async -> Int` inserted in
  `syncRange` between `runAutoMatch` and `runAttendeeImport` (Rust order: `sync.rs:68-78`).
  Reads `database.calendarEvents.events(startingIn: range)` (persisted rows carry `meetingId`,
  same rationale as `runAttendeeImport`, `CalendarSyncEngine.swift:131-133`), calls
  `SeriesDetector.detect` per event inside a per-event `do/catch` that logs (`os.Logger`,
  subsystem `com.arivo.ari.AriKit`, category `calendar.series`) and continues — **best-effort,
  never breaks sync** (parity `sync.rs:83-105`). On `.autoAdded`, invokes `onAutoSeriesMembership`
  fire-and-forget (`Task.detached(priority: .utility)`). Returns the count of NEW memberships
  written (suggested + auto — honest telemetry, re-runs report 0).
- `CalendarSyncReport` gains `public var seriesMemberships: Int` with a defaulted init parameter
  (`= 0`) so the 19 existing test call sites stay source-compatible.

### 2.3 AriKit `Engine` (feature 2 — no changes)

`SeriesLedgerReducer` is used as-is; its `foldMeeting` no-ops without a finished summary
(`SeriesLedgerReducer.swift:176-187`) and now — via the §2.1 filter — also no-ops for a
merely-suggested membership (`seriesIds(forMeeting:).first` returns none).

### 2.4 `AriViewModels`

**`AddToSeriesViewModel.swift`** (feature 2 + consent UI state):

```swift
/// Fire-and-forget ledger fold on membership add. Settable var (not init) because
/// MeetingDetailView constructs this VM in init (MeetingDetailView.swift:84) before
/// @Environment(AppEnvironment.self) is readable; the view assigns it in .task.
public var ledgerReducer: SeriesLedgerReducer?

/// Suggested (pending-consent) series for the loaded meeting — loaded in load(meetingId:)
/// via database.series.suggestedSeriesIds(forMeeting:) joined against allSummaries.
public private(set) var suggestedSeries: [SeriesSummary] = []

public func confirmSuggestion(seriesId: SeriesID, meetingId: MeetingID) async
// repo.confirmSuggestedMember → reload → fire fold (this is the moment consented content
// may enter the ledger).
public func declineSuggestion(seriesId: SeriesID, meetingId: MeetingID) async
// repo.declineSuggestedMember → reload. No fold.
```

`addToExisting` (`:67`) and `createAndAdd` (`:82`): after the successful mutation (inside `mutate`'s
success branch, before/independent of the reload), fire
`Task.detached(priority: .utility) { try? await reducer.foldMeeting(meetingId:) }` — the exact
`SummaryRunner.swift:204-214` pattern. Never on `remove`. **No double-fold:** the two triggers are
disjoint events — fold-on-add no-ops when no summary exists yet; `SummaryRunner`'s
fold-on-generation covers that case later; a meeting added *after* summarization folds here and
`SummaryRunner` never re-runs unless the summary is regenerated (existing behavior).

**New `AriViewModels/LinkedCalendarEventViewModel.swift`** (feature 3):

```swift
@MainActor @Observable
public final class LinkedCalendarEventViewModel {
    public private(set) var event: CalendarEvent?      // nil = honestly no linked event
    public private(set) var candidateEvents: [CalendarEvent] = []  // picker
    public private(set) var errorMessage: String?
    public private(set) var isBusy = false
    public init(database: AppDatabase)
    public func load(meetingId: MeetingID) async                    // linkedEvent(forMeeting:)
    public func loadCandidates(around meetingDate: Date) async      // events(startingIn: date ± 7d)
    public func link(eventId: CalendarEventID, meetingId: MeetingID) async   // setManualLink (steals per §2.1)
    public func unlink() async                                      // unlinkMeeting(eventId:)
}
```

Follows `AddToSeriesViewModel`'s shape exactly (direct `AppDatabase`, honest `errorMessage`,
busy flag, reload-on-success-only, `AddToSeriesViewModel.swift:96-109`).

**`CalendarPageViewModel` / `CalendarSettingsViewModel`:** both construct their own
`CalendarSyncEngine` (`CalendarPageViewModel.swift:110`, `CalendarSettingsViewModel.swift:144-145`).
Add an optional `onAutoSeriesMembership: (@Sendable (MeetingID) async -> Void)?` init parameter
(default `nil`) threaded into their engine constructions, so VM-triggered syncs fold too.

### 2.5 Ari app target

- **`Ari/App/AppEnvironment.swift`:** at `:331`, pass the fold hook into the scheduler's engine:
  `CalendarSyncEngine(source: source, database: db, onAutoSeriesMembership: { [ledgerReducer] mid in try? await ledgerReducer.foldMeeting(meetingId: mid) })`
  (capture the local `ledgerReducer` value from `:229`, never `self` — same discipline as the
  coordinator closures, `AppEnvironment.swift:284-288`). Thread the same closure where
  `CalendarPageViewModel`/`CalendarSettingsViewModel` are constructed.
- **New `Ari/UI/MeetingDetails/LinkedEventCard.swift`** (feature 3): a Marginalia-styled card in
  the meeting-detail right rail (near the source-record/provenance block): event title, time range
  (reuse the `timeRangeText` formatting from `EventDetailSheet.swift:82-92`), calendar name
  (`calendarTitle`), attendee initials row (reuse the `attendeeRow`/`initial` pattern,
  `EventDetailSheet.swift:151-174` — extract into a small shared `AttendeeRow` view rather than
  duplicating), an "Unlink" quiet button, and — when `event == nil` — a "Link calendar event…"
  affordance opening a picker sheet (candidate events ±7 days around `meeting.createdAt`, each row
  showing title/time and a "linked elsewhere" caption when `meetingId != nil` — linking such a row
  visibly *moves* the link, per §2.1 semantics; the picker copy must say so). Reuse
  `LinkMeetingSheet`'s structure inverted (meeting→event instead of event→meeting).
- **New `Ari/UI/MeetingDetails/SeriesSuggestionBanner.swift`** (feature 1 consent UI): rendered in
  the meeting header area (next to the existing Add-to-series affordance,
  `MeetingDetailView.swift:38-43`) when `seriesViewModel.suggestedSeries` is non-empty. Copy:
  *"This looks like an occurrence of the recurring series '<title>'."* Buttons: **"Add — and add
  future occurrences"** (→ `confirmSuggestion`) and **"No thanks"** (→ `declineSuggestion`).
  Renders only from the persisted suggested row — a fact about the store, not UI optimism
  (`EventDetailSheet.swift:6-8` posture). No amber unless it is genuinely the one signal on screen
  (Signal Rule).

**Consent-mechanism decision & justification (the product twist):** *ask-then-act via a persisted
`'suggested'` membership state + a per-series `autoAddMode` memory*, rather than
act-then-undo. Rationale: (a) the ledger fold is not cleanly reversible — silent auto-add followed
by fold would bake unconsented content into the series memory an undo can't cleanly remove;
(b) member counts and `@mref` citation indexes must never include, then lose, a member (index
shifts are the documented L2 hazard, `SeriesRepository.swift:333-339` — suggestions never consume
an index until confirmed); (c) `'suggested'` is idempotent under the 15-minute sync loop
(`CalendarSyncScheduler.swift:18-19`) — the row's existence is itself the "already asked" marker,
no extra suppression table; (d) `autoAddMode 'always'/'never'` makes it a *one-time* question per
series, exactly matching "always add this meeting['s series]": after confirm, future occurrences
add silently as `'auto'` (consented) and fold; after decline, the series never nags again. This is
the consent-before-record spirit applied to memory: nothing irreversible happens without a visible
yes.

## 3. Concurrency model

- Everything stays on the existing isolation pattern: repositories and `SeriesDetector`/
  `CalendarSyncEngine` are `Sendable` structs over GRDB's `DatabaseWriter` (off-main via GRDB's
  own queue); view models are `@MainActor @Observable` classes. No new actors.
- The fold hook and VM fold calls are `Task.detached(priority: .utility)` — never block the UI
  membership write, sync pass, or summary return (`SummaryRunner.swift:200-214` precedent).
  `onAutoSeriesMembership` is `@Sendable`; the AppEnvironment closure captures only the `Sendable`
  `SeriesLedgerReducer` value.
- No `@unchecked Sendable`, no `nonisolated(unsafe)` anywhere in this bundle. `CalendarSyncReport`
  stays `Sendable Equatable`. Nothing here touches the audio/STT hot path.
- 1:1 enforcement is transactional: the clear-competitors UPDATE and the link write share one
  `dbWriter.write` block, so no interleaving writer can observe two events linked to one meeting;
  the partial UNIQUE index is the backstop for any future code path that forgets.

## 4. Persistence

- **Single DB owner unchanged:** the Ari app process owns the GRDB store; every touch above goes
  through `AppDatabase` repositories (Store rule, `swift-conventions.md`). No raw handles in
  feature code; the two raw-SQL statements (partial index DDL, clear-competitors UPDATE) live
  inside `SchemaMigrator`/`CalendarEventRepository` respectively.
- **Migration:** extend `v1_baseline` in place (index + `series.autoAddMode`) per the file's own
  standing policy for the unshipped baseline (`SchemaMigrator.swift:7-17`). **Fallback if the
  implementer finds `v1_baseline` has been declared shipped by then:** register
  `v2_calendar_series_consent` instead, whose body first dedupes
  (`UPDATE calendarEvent SET meetingId = NULL, linkSource = NULL WHERE meetingId IS NOT NULL AND id NOT IN
  (SELECT id FROM calendarEvent ce2 WHERE ce2.meetingId = calendarEvent.meetingId ORDER BY ce2.startTime DESC, ce2.id DESC LIMIT 1)`
  — keep the most recent link by `startTime`, tie-break `id`), then creates the index, then
  `ALTER TABLE series ADD COLUMN autoAddMode TEXT NOT NULL DEFAULT 'ask'`.
- **Legacy importer (`LegacyDatabaseImporter.importCalendarEvents`, `:466-489`):** the Rust DB can
  in principle carry multi-links ("shouldn't happen", `calendar.rs:286-287`). Pre-pass the fetched
  rows: group by `meeting_id`, keep the latest `start_time` (tie-break id), null out
  `meetingId`/`linkSource` on the rest, appending a warning per dropped link. Without this, the
  second `upsert` would silently *steal* the link under the new §2.1 semantics (order-dependent) —
  the pre-pass makes it deterministic and reported.
- New/changed rows summarized: `series.autoAddMode` ('ask'|'always'|'never'); `seriesMember.linkSource`
  gains the value `"suggested"` (column already free text); `calendarEvent` gains the partial
  unique index. No new tables.

## 5. Acceptance tests (written first — Swift Testing)

All in `AriKit/Tests/` following existing suites. Dual-run note: the Rust incumbent's *invariants*
(idempotency, guard conditions, never-break-sync) are encoded below and already hold in the frozen
Rust build (`detection.rs:19-21`, `sync.rs:83-84`); the Swift candidate must pass the same set plus
the consent divergences, which are asserted as deliberate deltas. No spike gate (S1–S4) applies —
no model/DSP work here.

**`Store/CalendarEventLinkUniquenessTests`** (new suite, feature 4)
1. `setManualLink` to event B for meeting M clears event A's `meetingId`/`linkSource` in the same tx.
2. `setAutoLink` re-points from a stale auto link but is skipped entirely when M is manually
   linked elsewhere (manual wins; no steal, no partial write).
3. `upsert` of an event carrying `meetingId = M` clears a competitor (importer path).
4. Raw duplicate `INSERT` violating the partial index throws (index exists and is partial:
   two rows with `meetingId NULL` coexist).
5. Tombstoned competitor rows are cleared too (index has no `isDeleted` filter).
6. Importer dedupe: two legacy rows linked to one meeting → later `start_time` keeps the link,
   warning emitted.

**`Calendar/SeriesDetectorTests`** (new suite, feature 1 — parity + consent)
7. Guard no-ops (parity `detection.rs:26-36`): unlinked event / `hasRecurrence == false` /
   nil / blank `seriesKey` → `.skipped`, zero rows written.
8. First detection for a new key: creates series (title from event; `"Recurring meeting"`
   fallback; `autoAddMode == 'ask'`) + ONE `'suggested'` member; `occurrenceTime` prefers
   `occurrenceDate`, falls back to `startTime` (parity `detection.rs:45-49, 67-71`).
9. Idempotent: second run → `.skipped`, no duplicate series (keyed by seriesKey), no member churn.
10. Existing `'manual'` membership is never overwritten (deliberate divergence from
    `meeting_series.rs:198-199` — asserted as such).
11. `autoAddMode == 'always'` → `.autoAdded`, member `linkSource == 'auto'`.
12. `autoAddMode == 'never'` → `.skipped`, nothing written.
13. Tombstoned series holds the key → `.skipped`; the series is not resurrected.

**`Calendar/CalendarSyncEngineTests` (extended — feature 1 wiring)**
14. Full `syncRange` pass over a fake source (`FakeCalendarSource`) with a recurring linked event:
    report `seriesMemberships == 1`; re-run reports 0.
15. A detector failure on one event (fault-injected via a poisoned row) does not fail `syncRange`
    and does not skip detection for subsequent events (parity `sync.rs:83-105`).
16. `.autoAdded` invokes `onAutoSeriesMembership` with the meeting id; `.suggested` does NOT.

**`Store/SeriesRepositoryTests` (extended — suggestion semantics)**
17. `'suggested'` rows are excluded from `seriesIds(forMeeting:)`, `meetingIds(inSeries:)`,
    `orderedMeetingIds(inSeries:)`, and `allSummaries` counts, but returned by
    `suggestedSeriesIds(forMeeting:)`.
18. `confirmSuggestedMember`: linkSource → `'auto'` and `autoAddMode → 'always'` atomically; the
    meeting now appears in `orderedMeetingIds` (citation index includes it only from confirm).
19. `declineSuggestedMember`: row deleted, `autoAddMode → 'never'`; a series left member-less is
    tombstoned; a series with other real members is not.

**`SeriesLedgerReducerTests` (extended)**
20. `foldMeeting` no-ops for a meeting whose only membership is `'suggested'` (ledger untouched —
    No-Fake-State: unconsented content never enters the ledger).

**`AriViewModelsTests/AddToSeriesViewModelTests` (extended — feature 2)**
21. `addToExisting` on a meeting WITH a finished summary triggers exactly one fold (spy via the
    canned `clientFactory` pattern, `SeriesLedgerReducerTests.swift:42`); ledger updated with
    validated `@mref`s only.
22. `addToExisting` on a meeting WITHOUT a summary: membership written, ledger untouched (no fold
    effect, no error).
23. `createAndAdd` folds like 21; `remove` never folds.
24. A fold failure (throwing client) leaves membership written and `errorMessage` nil — the fold
    is best-effort and detached, never poisoning the UI write.
25. `confirmSuggestion` folds (the consent moment); `declineSuggestion` never folds.

**`AriViewModelsTests/LinkedCalendarEventViewModelTests`** (new suite, feature 3)
26. `load` returns the linked event; `nil` (not a placeholder) when none — and `nil` when the only
    "link" is on a tombstoned event.
27. `unlink` clears and reloads to `nil`; `link` sets a manual link and steals from a previously
    linked event (asserting §2.1 semantics through the VM).
28. Error paths surface `errorMessage` honestly and keep prior state (mirror
    `AddToSeriesViewModelTests`' posture).

## 6. Invariants preserved

- **No-Fake-State:** the event card renders only persisted data and is omitted when absent; the
  suggestion banner renders only from a persisted `'suggested'` row; member counts/citation
  indexes exclude suggestions; sync-report counts are new-writes-only (tests 8, 14, 17, 20, 26).
- **Consent-first (the consent-before-record spirit):** no silent irreversible auto-linking —
  detection asks before a series membership can affect ledgers, summaries, Ask, or counts;
  `'always'` is an explicit, remembered grant; `'never'` and series deletion are honored forever
  (tests 12, 13, 19, 20, 25).
- **Ledger citation validation:** untouched — every fold path still flows through
  `SeriesLedgerCitations.validateQualifiedRefs` (`SeriesLedgerReducer.swift:139, 238`); suggested
  exclusion from `orderedMeetingIds` keeps `memberCount` (the `@mref` validity bound) honest.
- **Never break sync / never block:** detection and folds are best-effort and detached
  (tests 15, 24); the S7 link-preserving `syncUpsert` invariant (`CalendarEventRepository.swift:75-81`)
  and manual-wins rule are untouched and re-asserted (test 2).
- **Repository-only persistence, one DB owner:** unchanged; all new SQL lives in
  Store/SchemaMigrator.

## 7. Risks & sequencing

Order **4 → 3 → 2 → 1** (1 depends on 4's link semantics and on 2's fold wiring; 3 is independent
but exercises 4's new read). Each step lands with its tests green and is independently shippable.

1. **Feature 4** — schema (index + dedupe fallback + importer pre-pass) + repository tx semantics
   + `linkedEvent(forMeeting:)`. Risk: the manual-wins/steal interaction (test 2) — get the guard
   order right before anything builds on it.
2. **Feature 3** — `LinkedCalendarEventViewModel` + `LinkedEventCard` + picker. Risk: low; pure
   read/write over step 1's surface.
3. **Feature 2** — `AddToSeriesViewModel.ledgerReducer` + detached folds + `.task` wiring in
   `MeetingDetailView`. Risk: double-fold confusion — covered by tests 21–24 and the disjoint-
   trigger argument (§2.4).
4. **Feature 1** — `series.autoAddMode` + `SeriesDetector` + `CalendarSyncEngine.runSeriesDetection`
   + suggestion repo methods/filters + banner + AppEnvironment/VM hook threading. Risk: the
   `'suggested'` filter sweep (§2.1) touches four read paths and their consumers
   (`SummaryContextAssembler:186`, `RecallEngine:217`, `SeriesDetailViewModel:62`,
   `AddToSeriesViewModel:57`) — do the repository filters and their tests (17, 20) *before* the
   detector so nothing can observe a suggestion as a member even transiently.

No Rust sidecar is involved anywhere in this bundle; nothing hides behind the engine protocol.

## 8. Open decisions for the human

1. **Decline scope:** declining a suggestion sets `autoAddMode = 'never'` for the whole series
   (never ask again for any occurrence). Alternative: per-meeting decline that re-asks on the next
   occurrence. The plan picks series-wide (matches "always add… or undo" framing and avoids nag
   loops); flag if you want per-occurrence.
2. **Migration route:** the plan follows `SchemaMigrator`'s extend-`v1_baseline`-in-place policy.
   If your live Ari.app database is now considered "shipped" (release build, real data you won't
   re-import), say so and the implementer takes the `v2_calendar_series_consent` fallback (§4).
3. **Suggested members in `SeriesDetailView`:** the plan surfaces suggestions on the meeting
   detail only. Showing them (marked "suggested") on the series page too is a small optional
   follow-on — excluded here to keep the bundle minimal.
