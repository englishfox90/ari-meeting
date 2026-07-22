# Plan: AriKit Calendar — S7 EventKit slice (live calendar source + sync engine)

**Status:** approved · **Author:** swift-architect · **Date:** 2026-07-21
**Slice:** S7 (EventKit part only) of `docs/plans/arikit-native-shell.md` §2.5 / §11.
**Out of S7 here (later tail):** notch panel, notifications/menu bar, F5 record prompt, Series
Track I (`docs/plans/arikit-engine-providers.md` Slice I), and any week-grid calendar page
(read-UI follow-on — noted, not planned here).

> **Open decisions — resolved 2026-07-21 (architect recommendations adopted):**
> 1. `CalendarLinkSource` gains `case auto` (rawValue `"auto"`); Swift auto-match writes `"auto"`,
>    uniform with imported rows.
> 2. Empty-selection prune keeps frozen parity (tombstones make it non-destructive).
> 3. The 15-min background scheduler lands in C4.

## 1. Goal & seam

Port the frozen Rust calendar subsystem (F4) to native Swift: an EventKit source (permission
status/request, list calendars, fetch events in range) plus the sync engine (upsert + prune +
auto-match) writing through the existing `CalendarEventRepository`, and wire the honest-disabled
Settings surfaces (`CalendarSettingsViewModel` + `SettingsCalendarSection`) live.

This lands entirely on the **target (Swift) side of the cut seam** (plan principle 8): the Rust
app is frozen; F4 shipped there and is the behavior-parity baseline
(`frontend/src-tauri/src/calendar/{eventkit,sync,commands}.rs`,
`ari-engine/src/database/repositories/calendar.rs`). This is a **port/re-host of a frozen
feature into the Swift tree** — exactly what the migration plan schedules for Phase 2 ("cheap
early win", `arikit-native-shell.md:156-163`) — not net-new Rust work and not a second parallel
implementation the user would run twice: the Swift app is the only go-forward app, and its
`calendarEvent`/`calendarSyncSetting` tables are currently populated only by the one-time legacy
import. S7 makes them live. The Swift store (`com.arivo.ari/ari.sqlite`) is a **different DB
file** from the frozen Rust app's — no shared-file ownership conflict (principle 3 holds).

WIP note: this opens no second phase. It is the scheduled Phase-2 tail after S0/S6/S8-lite
(`arikit-native-shell.md:438`), and consumes the diarization hint seam without touching the
diarization pipeline (out of scope per tasking).

## 2. Module boundaries & public surface

### 2.1 Placement

| Piece | Where | Why |
|---|---|---|
| `CalendarSourcing` protocol + `NativeCalendar`/`NativeEvent` + `CalendarPermission` | `AriKit/Sources/AriKit/Calendar/` (new module folder) | The sync engine must be Lane-1 testable headless against a fake source; `arikit-models.md` §2 decision 4 places `Native*` in "the Calendar capture layer", not `Models/` |
| `CalendarSyncEngine` | `AriKit/Sources/AriKit/Calendar/CalendarSyncEngine.swift` | Pure orchestration over `CalendarSourcing` + repositories — zero EventKit import, fully headless |
| `EventKitCalendarSource` (the one EventKit toucher) | **`Ari/Calendar/EventKitCalendarSource.swift` (app target)** | Per `arikit-native-shell.md:158` ("ports into `Ari/Calendar/`"). Rationale: (a) TCC prompting belongs to a bundle with Info.plist usage strings — keeping EventKit out of `AriKit` guarantees `swift test` can never trigger a Calendar prompt or link a TCC-sensitive framework into the headless package; (b) the conformer is ~150 lines — cheap to host per app. EventKit *is* available to AriKit and exists on iOS, so if iOS Lite later wants calendar, the conformer can be promoted to a small `AriCalendarEventKit` package product then (same move as the FluidAudio provider isolation, `AppEnvironment.swift:52-54`); we don't pre-build that indirection now |
| Background scheduler (15-min loop) | `Ari/Calendar/CalendarSyncScheduler.swift` (app target), started by `AppEnvironment` | App-lifecycle concern, trivial Task loop; the engine stays a pure per-call function |
| VM wiring | `AriKit/Sources/AriViewModels/CalendarSettingsViewModel.swift` (extend in place) | Already designed to go live (`CalendarSettingsViewModel.swift:5-8`) |

### 2.2 Public Swift surface

```swift
// AriKit/Calendar/CalendarSource.swift
/// Read-only calendar access state. Mirrors the frozen mapping (eventkit.rs:20-30):
/// EKAuthorizationStatus.writeOnly is useless for reads and maps to .denied.
public enum CalendarPermission: String, Sendable, Equatable {
    case notDetermined, restricted, denied, fullAccess
}

/// Native projection of one calendar (← ari-engine NativeCalendar, models.rs:79-83).
public struct NativeCalendar: Sendable, Hashable {
    public var id: String            // EKCalendar.calendarIdentifier
    public var title: String
    public var color: String?        // "#RRGGBB"; nil when unreadable — never fabricated
}

/// Native projection of one event (← NativeEvent, models.rs:87-110). Value type, Sendable —
/// EK objects never cross this boundary.
public struct NativeEvent: Sendable, Hashable {
    public var id: String            // EKEvent.eventIdentifier (skip events without one, eventkit.rs:221-226)
    public var calendarId: String
    public var calendarTitle: String?
    public var title: String
    public var startTime: Date
    public var endTime: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var organizer: String?
    public var attendees: [Attendee] // AriKit.Models.Attendee (name from EKParticipant.name; email parsed from mailto: URL, eventkit.rs:162-177)
    public var seriesKey: String?    // calendarItemExternalIdentifier (eventkit.rs:255)
    public var hasRecurrence: Bool
    public var occurrenceDate: Date?
    public var isDetached: Bool
}

/// The seam the sync engine and the VM depend on; EventKit conforms in the app target,
/// FakeCalendarSource conforms in tests.
public protocol CalendarSourcing: Sendable {
    func permissionStatus() async -> CalendarPermission
    func requestFullAccess() async throws -> CalendarPermission
    func listCalendars() async throws -> [NativeCalendar]
    func fetchEvents(calendarIds: [String], from start: Date, to end: Date) async throws -> [NativeEvent]
}

// AriKit/Calendar/CalendarSyncEngine.swift
public struct CalendarSyncReport: Sendable, Equatable {
    public var fetched: Int          // events returned by the source (parity: sync.rs:80 return)
    public var pruned: Int
    public var autoLinked: Int
}

public struct CalendarSyncEngine: Sendable {
    public init(source: any CalendarSourcing, database: AppDatabase)
    /// fetch → upsert (link-preserving) → prune-in-range → auto-match. One full pass,
    /// parity with sync_range_core (sync.rs:28-81) minus series/participant hooks (deferred).
    public func syncRange(from start: Date, to end: Date, now: Date = Date()) async throws -> CalendarSyncReport
    /// Convenience matching the Rust background window: now-30d … now+90d (sync.rs:21-22).
    public func syncDefaultWindow(now: Date = Date()) async throws -> CalendarSyncReport
    /// Refresh calendarSyncSetting identities from the source, preserving `selected`
    /// (parity: calendar_list_calendars_impl, commands.rs:58-83). Returns rows for the VM.
    public func refreshCalendarList() async throws -> [(calendarId: String, calendarTitle: String?, color: String?, selected: Bool)]
}

// Ari/Calendar/EventKitCalendarSource.swift  (app target)
public actor EventKitCalendarSource: CalendarSourcing { … }
```

### 2.3 Repository additions (`CalendarEventRepository` — the only DB path)

The existing `upsert(_:)` (`CalendarEventRepository.swift:48-52`) **cannot** be used by sync: it
rebuilds the full record with `syncedAt = nil` / link fields from the value
(`CalendarEventRecord.swift:59-66`), which would clobber links — the exact thing the Rust upsert
forbids (`calendar.rs:173-176`). Add sync-specific methods (all Lane-1 tested):

```swift
public func syncUpsert(_ events: [CalendarEvent], at syncDate: Date) async throws
//  One write tx. Per event: INSERT new row, or UPDATE all descriptive + recurrence columns +
//  syncedAt, clearing isDeleted/deletedAt (re-appearing event un-tombstones) while NEVER
//  touching meetingId/linkSource (parity: calendar.rs:144-199).

public func pruneStaleEvents(startingIn range: ClosedRange<Date>, keeping ids: Set<CalendarEventID>, at date: Date) async throws -> Int
//  Tombstone (softDelete semantics — sync-aware Store delta vs. Rust's hard DELETE,
//  calendar.rs:207-237) every non-deleted event whose startTime is in range and id ∉ keeping.
//  Empty keeping ⇒ prunes everything in range (parity: calendar.rs:213-222).

public func events(startingIn range: ClosedRange<Date>) async throws -> [CalendarEvent]        // calendar.rs:239-251
public func autoLinkableEvents(startingIn range: ClosedRange<Date>) async throws -> [CalendarEvent]  // linkSource IS NULL OR != 'manual' (calendar.rs:254-271)
public func setAutoLink(eventId: CalendarEventID, meetingId: MeetingID) async throws
//  UPDATE … WHERE id = ? AND (linkSource IS NULL OR linkSource != 'manual') (calendar.rs:324-341)
public func setManualLink(eventId: CalendarEventID, meetingId: MeetingID) async throws         // calendar.rs:343-354
public func unlinkMeeting(eventId: CalendarEventID) async throws                               // calendar.rs:356-362

public func selectedCalendarIds() async throws -> [String]                                     // calendar.rs:133-138
public func setSelectedCalendars(_ ids: [String]) async throws
//  One tx: clear-all then set (parity: calendar.rs:112-131)
public func upsertCalendarIdentity(calendarId: String, title: String?, color: String?) async throws
    -> (calendarId: String, calendarTitle: String?, color: String?, selected: Bool)
//  INSERT selected=0 / UPDATE title+color only — PRESERVES an existing `selected`
//  (parity: calendar.rs:71-100). Note: the existing setSyncSetting(...) full-row save would
//  clobber `selected`; identity refresh must use this method.
```

Plus one addition to `MeetingRepository`:

```swift
public func closestMeetingID(createdBetween start: Date, and end: Date, to anchor: Date) async throws -> MeetingID?
//  ORDER BY |createdAt - anchor| ASC LIMIT 1 (parity: calendar.rs:399-423)
```

## 3. Concurrency model (Swift 6 strict)

- **`EventKitCalendarSource` is an `actor`.** `EKEventStore`/`EKEvent`/`EKCalendar` are not
  `Sendable`; all EK objects are created, queried (`calendars(for:)`,
  `predicateForEvents(withStart:end:calendars:)` + `events(matching:)`) and immediately
  projected into `NativeCalendar`/`NativeEvent` **inside the actor's isolation** — no EK type
  ever escapes. This is the Swift analog of the Rust module keeping objc2 behind `NativeEvent`
  (`eventkit.rs:1-3`).
- **Permission:** `permissionStatus()` reads the class method
  `EKEventStore.authorizationStatus(for: .event)` (no store instance needed, `eventkit.rs:33-35`).
  `requestFullAccess()` calls the modern async API
  `try await store.requestFullAccessToEvents()` (macOS 14+; well under the macOS 26 floor — no
  availability guards). The async API replaces the entire Rust main-thread + block-keepalive
  dance (`eventkit.rs:42-90`, `commands.rs:30-56`): block lifetime and completion dispatch are
  the runtime's problem now. On `false`, re-read the authoritative status rather than assuming
  `.denied` (parity: `eventkit.rs:63-71`).
- **`CalendarSyncEngine` is a `Sendable` struct** with only async methods; every call runs off
  the main actor (repository `read`/`write` hop to GRDB's queues; the source hops to its actor).
  Nothing here touches the audio hot path or STT.
- **`CalendarSettingsViewModel` stays `@MainActor @Observable`**; it `await`s the engine/source
  and mutates its published state on the main actor. Post-sync UI refresh uses the existing
  repository read (or `observeAll()` if the read UI wants live rows later).
- **Scheduler:** a single `Task` owned by `AppEnvironment` (created at `.ready`, cancelled on
  deinit): sleep 5 s, then loop `{ guard permission == .fullAccess, !selectedIds.isEmpty else
  skip; try? await engine.syncDefaultWindow(); sleep 15 min }` — parity with
  `spawn_background_sync` (`sync.rs:19-22, 180-239`), including the skip conditions.
- **No `@unchecked Sendable` anywhere** in this slice; the actor + value types cover every
  boundary.

## 4. Persistence & sync-semantics parity list

One process owns the DB (`AppDatabase`, `AppEnvironment.swift:31`); all writes go through
`CalendarEventRepository` (§2.3). No schema migration is needed — `calendarEvent` /
`calendarSyncSetting` already exist (`SchemaMigrator.swift`; store plan §4.8);
S7 only starts writing `syncedAt` (documented gap, `CalendarEventRecord.swift:10-13`).

Exact parity commitments (each becomes a Lane-1 test):

1. **Windows.** Background: past 30 d / future 90 d, every 15 min, initial delay 5 s
   (`sync.rs:19-22`). On-demand `syncRange` takes explicit bounds (`commands.rs:143-172`).
2. **Upsert preserves links.** Re-sync updates descriptive + recurrence columns + `syncedAt`,
   never `meetingId`/`linkSource` — for **both** manual and auto links (`calendar.rs:166-176`).
3. **Prune is range-and-keep-ids scoped.** Only events whose `startTime` ∈ [start, end] and id
   not returned by the source this pass; events outside the window untouched
   (`calendar.rs:201-237`, `sync.rs:63-66`). Delta: tombstone (`isDeleted`/`deletedAt`) instead
   of hard DELETE — the Store is sync-aware; `syncUpsert` un-tombstones a re-appearing event.
   Parity edge kept: empty fetch result prunes the whole range — including when the selection
   is empty or a calendar was deselected (that *is* frozen behavior; recoverable via
   un-tombstoning here, strictly safer than Rust).
4. **Auto-match rules** (`sync.rs:16, 136-174` + `calendar.rs:254-271, 324-341, 399-423`):
   candidates = events in range with `linkSource IS NULL OR != 'manual'` (already-auto-linked
   events are re-evaluated every pass and may be re-pointed at a closer meeting; if no meeting
   matches, an existing auto link is left as-is); match = the meeting whose `createdAt` falls in
   `[event.start − 15 min, event.end + 15 min]`, closest to `event.start`; the link write itself
   re-guards against manual. **Manual links are never touched by any sync path.**
5. **Selection default:** a newly seen calendar is inserted `selected = 0` (`calendar.rs:79-84`);
   only `selected = 1` calendars sync (`calendar.rs:133-138`); empty selection ⇒ source fetch
   short-circuits to `[]` (`eventkit.rs:184-186`) and the background loop skips
   (`sync.rs:219-222`). **Nothing syncs until the user opts calendars in.**
6. **Identity refresh preserves selection:** listing calendars upserts title/color but never
   resets `selected` (`calendar.rs:71-100`, `commands.rs:63-79`).
7. **Events without an `eventIdentifier` are skipped** (`eventkit.rs:221-226`); calendar color is
   `nil` when unreadable, never fabricated (`eventkit.rs:107-145`).
8. **Deferred hooks (explicitly NOT ported here):** series detection (`sync.rs:72, 85-105` →
   Series Track I slice) and participant reconcile / attendee→person import
   (`sync.rs:78, 109-131`, `commands.rs:384-390` → F2 bridge slice). The engine's `syncRange`
   is the seam both will attach to (post-sync, same range) — noted so those slices don't
   reinvent windows.

## 5. Wiring the UI live (VM + Settings + AppEnvironment)

- `AppEnvironment.bootstrap()` constructs `EventKitCalendarSource` + `CalendarSyncEngine` after
  `database` exists, injects the source into `CalendarSettingsViewModel`, starts the scheduler.
- `CalendarSettingsViewModel` changes (deliberate, test-updated — §6/§7):
  - `permission` becomes a real read from the injected `any CalendarSourcing` (default `nil`
    source keeps today's honest `.notDetermined`, so headless construction stays truthful).
  - `grantAccessAvailability` becomes `.available` **only when a source is injected**; the
    grant button calls `requestFullAccess()` and re-reads status (honest `.denied` on refusal —
    never optimistic).
  - `load()` additionally calls `engine.refreshCalendarList()` when permission is `.fullAccess`
    (populating the honest-empty list with real calendars, `selected` preserved).
  - New `syncNow()` → `engine.syncDefaultWindow()`, surfacing the honest fetched/pruned counts
    (No-Fake-State: show the real report, or the real error).
- `SettingsCalendarSection`: enable the Grant button through the now-live availability; keep the
  toggle rows as-is (already live round-trips); replace the "hasn't been wired" empty-state copy
  with an honest permission-appropriate message ("No access granted" / "No calendars found").
- **`SpeakerCountHintProviding` seam — no downstream change (verified):** the Phase-3.5 conformer
  `StoredCalendarHintProvider` already reads `calendarEvents.forMeeting(_:)`
  (`StoredCalendarHintProvider.swift:29-33`); once S7 sync populates `calendarEvent` rows and
  auto-match writes `meetingId`, real hints flow with **zero** new code. A dedicated
  live-EventKit conformer is unnecessary for now; if one is ever wanted it conforms to the same
  protocol (`SpeakerCountHintProviding.swift:5-6`). Diarization itself is untouched.

## 6. Acceptance tests (written first, Swift Testing)

**Lane 1 — headless, `FakeCalendarSource` (scripted calendars/events/permission), in-memory DB:**

`CalendarSyncEngineTests` (new suite):
1. `syncUpsertInsertsAndUpdatesDescriptiveFields` — second pass with edited title/notes updates row, sets `syncedAt`.
2. `syncNeverClobbersManualLink` — manual-linked event survives re-sync with `meetingId`/`linkSource` intact (parity #2).
3. `syncNeverClobbersAutoLink` — same for auto links.
4. `pruneTombstonesOnlyMissingEventsInRange` — event outside range untouched; missing in-range event gets `isDeleted`, not a hard delete (parity #3).
5. `prunedEventReappearingIsUntombstoned`.
6. `emptyFetchPrunesWholeRange` (parity #3 edge).
7. `autoMatchLinksClosestMeetingWithin15MinSlack` — two candidate meetings; closest to `event.start` wins (parity #4).
8. `autoMatchSkipsManualAndReevaluatesAuto` — manual never re-linked; auto re-pointed when a closer meeting appears.
9. `autoMatchLeavesExistingAutoLinkWhenNoCandidate`.
10. `unselectedCalendarsDoNotSync` + `newCalendarDefaultsUnselected` (parity #5).
11. `refreshCalendarListPreservesSelection` (parity #6).
12. `eventsWithoutIdentifierAreSkippedBeforeEngine` (fake models the source contract; the EventKit-side skip is code-reviewed + Lane-2).
13. `storedCalendarHintGoesLiveAfterSync` — after a sync that auto-links an event with 3 attendees, `StoredCalendarHintProvider.hint(for:)` returns `.upperBound(3)`, origin `.calendarAttendees` (the seam confirmation, no downstream change).

`CalendarEventRepositoryTests` (extend): direct coverage of each §2.3 method, incl. `setAutoLink` manual-guard and `setSelectedCalendars` transactional clear+set.

`CalendarSettingsViewModelTests` (**updated deliberately, not silently broken**):
- `honestEmptyState` is **kept but re-scoped**: no injected source ⇒ `.notDetermined`, empty list, grant `.disabled` (unchanged assertions, new "source == nil" meaning documented in the test).
- `setSelectedRoundTrips` unchanged.
- New: `grantAvailableWhenSourceInjected`, `deniedPermissionReportedHonestly`, `loadPopulatesCalendarsFromSourceWhenGranted`, `syncNowReportsRealCounts`.

**Lane 2 — human checklist (TCC-gated; NOT agent-closeable — an agent cannot grant Calendar
access or observe the TCC prompt; these steps stay open until Paul runs them):**
- [ ] Build + sign the `.app` with the stable identity; launch (ad-hoc/bare binaries can never receive a Calendar grant — `build-and-run.md`).
- [ ] Settings ▸ Calendar ▸ Grant Access → real macOS prompt appears; grant → state shows `fullAccess`.
- [ ] Real calendars list with correct titles/colors; toggle two on; Sync Now → events appear (verify a known event's title/time).
- [ ] Deny path on a fresh TCC state (`tccutil reset Calendar com.arivo.ari`) → honest denied state, no fake list.
- [ ] Delete an event in Apple Calendar, re-sync → it disappears from Ari (tombstoned).
- [ ] Record (or use an existing) meeting overlapping a synced event → auto-link appears; a manually linked event survives a re-sync.
- [ ] Quit + relaunch: background sync runs (log line) without re-prompting.

No S1–S4 spike gate applies (EventKit is not a spiked subsystem); the dual-run bar is the
parity list in §4 encoded as Lane-1 tests, with the frozen Rust behavior as the spec.

## 7. Invariants preserved

- **No-Fake-State:** permission is always the re-read authoritative status (never assumed
  granted); calendar list stays empty until a real fetch; color `nil` when unreadable; sync
  report shows real counts; the honest-disabled surfaces flip to live only when the capability
  actually exists. The two existing VM tests are updated **in the same slice as the behavior
  change**, with the re-scoping documented (§6).
- **Repositories-only persistence / one DB owner:** every write in §2.3 lives in
  `CalendarEventRepository`/`MeetingRepository`; the engine and VM never see GRDB types; the
  single `AppDatabase` from `AppEnvironment` remains the sole SQLite owner.
- **Manual links are sacred** (the F4 correctness invariant, `calendar.rs:5-6`) — enforced in
  three places (upsert, auto-match candidate filter, auto-link WHERE guard) and by tests 2/8.
- **Consent-before-record / recall shell:** untouched — this slice records nothing and never
  feeds an LLM.

## 8. Info.plist / entitlements / signing deltas

- **Info.plist:** add `INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription` to both build
  configurations (alongside the existing mic/audio-capture keys, `Ari/Ari.xcodeproj/project.pbxproj`).
  Suggested copy: "Ari reads your calendars to match meetings you record with their events.
  Nothing is written to your calendar."
- **Entitlements:** **no change.** `com.apple.security.personal-information.calendars` is an App
  Sandbox entitlement; this app is hardened-runtime, NO sandbox (`Ari/Ari.entitlements`,
  Q6 posture, `arikit-native-shell.md:169-179`) — Calendar access is TCC + usage-string only.
- **Signing:** the project currently builds ad-hoc (`CODE_SIGN_IDENTITY = "-"`).
  Calendar TCC requires a bundle with stable code identity (`build-and-run.md`); Lane-2 must run
  via the signed-bundle path with the **`Ari Dev Signing`** self-signed cert
  (`arikit-native-shell.md:171-174, 182-186`) so the grant persists across rebuilds. First grant
  on `com.arivo.ari` is a fresh one-time TCC event (new identity — expected).

## 9. Slice ordering (each independently testable)

- **C1 — Protocol + native types + repository methods.** `CalendarSourcing`, `CalendarPermission`,
  `NativeCalendar`/`NativeEvent`, all §2.3 repo methods + `MeetingRepository.closestMeetingID`.
  *Accept:* repository tests green; `swift test` (AriKit) green; no EventKit anywhere in AriKit.
- **C2 — `CalendarSyncEngine` + Lane-1 suite.** Engine + `FakeCalendarSource` + tests 1–13.
  *Accept:* full engine suite green headless, incl. the hint-seam test (§6 #13).
- **C3 — `EventKitCalendarSource` (app target) + Info.plist key.** The actor conformer; usage
  string; compile-time only verification in CI (no TCC in tests).
  *Accept:* app builds; code review confirms EK objects never escape the actor; parity items
  #7 (identifier skip, color honesty) present.
- **C4 — VM/UI wiring + scheduler.** `AppEnvironment` composition, VM live paths, Settings
  section copy/enable, `CalendarSyncScheduler`. *Accept:* updated
  `CalendarSettingsViewModelTests` green; honest states verified for source-absent and
  denied paths.
- **C5 — Lane-2 signed-bundle checklist (§6).** *Accept:* every checkbox run by Paul; S7-calendar
  accept per `arikit-native-shell.md:560-561` ("Calendar grant works under the signed bundle").

**Risks:** (a) TCC can't be CI-gated — honest Lane-1/Lane-2 split, checklist explicit; (b) large
predicate fetches (120-day window) on the actor — measured in C3, chunk the fetch per-month if
slow (EventKit already splits internally at 4-year spans, far above ours); (c) tombstone-vs-hard-
delete divergence — deliberate Store delta, tested both directions (prune + un-tombstone). No
Rust sidecar fallback is needed: EventKit is the native API the Rust code was already wrapping.

## Sources

- Apple — EKEventStore / requestFullAccessToEvents (EventKit docs).
- Rust incumbent read for behavior parity: `frontend/src-tauri/src/calendar/{eventkit,sync,commands}.rs`,
  `ari-engine/src/calendar/models.rs`, `ari-engine/src/database/repositories/calendar.rs`.
