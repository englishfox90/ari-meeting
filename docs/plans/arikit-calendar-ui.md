# Plan: Native Calendar Page (`Ari/UI/Calendar/`)

**Status:** ✅ LANDED 2026-07-22 (slices 1–3: `a675372`, `0e65f93`, review fixes `e74c4f2`; plus HTML-notes parsing follow-on `abc6a55` — `RichNotes` in AriViewModels, used by `EventDetailSheet`) · **Author:** swift-architect · **Date:** 2026-07-22
**Replaces:** the `.calendar` placeholder in `Ari/UI/AppShell/RootSplitView.swift:109-110`
**Depends on:** S7 EventKit calendar (landed, commit 9b7ad1c) — `CalendarSyncEngine`,
`CalendarEventRepository`, `EventKitCalendarSource`, `CalendarSyncScheduler`.

> **Open decisions — resolved 2026-07-22 (recommendations adopted):** week start follows the
> system locale (`Calendar.current.firstWeekday`); the pending calendar link persists across a
> consent-cancel (like `pendingTitle`) — it is always visible as a removable chip, never silent.

## 1. Goal & seam

A real Calendar page in the Swift app: a week grid of synced events (tinted with each
calendar's real EventKit color), an event-detail sheet with attendees, manual link/unlink
to meetings, and a "Start meeting from this event" handoff into the existing recording
flow. Pure Swift-side UI over data S7 already syncs — net-new Swift capability on the
target side of the cut seam; nothing touches the frozen Rust app. The Rust calendar page
(`frontend/src/app/calendar/page.tsx`, `WeekGrid.tsx`) is a *behavior* reference only
(local-DB-first render, sync-on-view, overlap layout, all-day handling) — visuals are
Marginalia, not a port.

This is UI within the already-open calendar phase (S7 follow-on). No new migration phase
is opened. **Read-only toward EventKit** — we never write events; all writes are to our
own store via `CalendarEventRepository`.

## 2. Scope cut (v1)

**In:**
- **Week view only.** 7-day grid (locale week start via `Calendar.current`), 24 hour rows,
  vertical scroll with initial offset ~7 AM, sticky day header, all-day row (only shown
  when the week has any all-day events), a "now" line on today's column, side-by-side
  overlap layout. Ported behaviors from `WeekGrid.tsx:45-117` (overlap clustering,
  min-height / min-duration clamps, exclusive all-day end dates).
- **One navigation affordance set:** `‹  Today  ›` week pager + week-range label. **No
  mini-month navigator.**
- Event blocks tinted from the calendar's stored color (`calendarSyncSetting.color`, via
  `CalendarEventRepository.syncSettings()`). Real data, not a design token — same stance
  as `WeekGrid.tsx:17-32`.
- **Event detail sheet:** title, time range, location, notes, organizer, attendees
  (decoded `[Attendee]` — `CalendarEventRepository` only ever surfaces the real array),
  linked-meeting row, and three actions: Start meeting, Link/Unlink meeting, Open linked
  meeting.
- **Link a meeting:** picker over existing meetings (newest first, text filter) →
  `setManualLink`; Unlink → `unlinkMeeting`. Manual links survive re-sync (syncUpsert
  never touches `meetingId`/`linkSource`).
- **Start a meeting from an event** (see §5).
- **Honest states:** no access → message + "Open Settings" jump; access but never synced
  (`latestSyncedAt() == nil`) → "No events synced yet" + Sync now; synced but empty week
  → the empty grid itself (real).
- Background `syncDefaultWindow()` on appear, at most once per appearance, with the same
  guards as `CalendarSyncScheduler.runOnce` (CalendarSyncScheduler.swift:42-47).

**Out (explicitly):** day/month/year view modes; mini-month; drag/resize/edit/create
(read-only calendar); event search; recurrence expansion UI; declined-event filtering;
notifications/record-prompt (F5 — separate feature); any EventKit write.

## 3. Module & surface

### Files

| File | Contents |
|---|---|
| `AriKit/Sources/AriViewModels/CalendarPageViewModel.swift` | `@MainActor @Observable` page VM |
| `AriKit/Sources/AriViewModels/CalendarWeekLayout.swift` | **Pure** layout math (no UI imports): week/day math, overlap clustering, all-day bucketing |
| `Ari/UI/Calendar/CalendarPageView.swift` | Page root: header (pager/Today/range label), state switch, sheet presentation |
| `Ari/UI/Calendar/CalendarWeekGrid.swift` | The grid (hour rows, day columns, now line, all-day row) |
| `Ari/UI/Calendar/CalendarEventBlock.swift` | One tinted event block (+ hex→Color helper, see below) |
| `Ari/UI/Calendar/EventDetailSheet.swift` | Detail + actions |
| `Ari/UI/Calendar/LinkMeetingSheet.swift` | Meeting picker |

UI lives under `Ari/UI/Calendar/` (the existing `Ari/Calendar/` holds the non-UI
EventKit source + scheduler and stays as-is). The private `color(fromHex:)` in
`SettingsCalendarSection.swift` is duplicated logic — promote it to one shared internal
helper (e.g. `Ari/UI/Components/HexColor.swift`) and use it from both; returns `nil` on
unparseable input (never a fabricated color).

### `CalendarWeekLayout` (pure, unit-testable — the port of `WeekGrid.tsx:45-117`)

```swift
public enum CalendarWeekLayout {
    public struct PositionedEvent: Equatable, Sendable {
        public var event: CalendarEvent
        public var startMinutes: Int   // clamped to the day
        public var endMinutes: Int     // >= startMinutes + 15 (WeekGrid.tsx:56)
        public var column: Int         // within its overlap cluster
        public var columnCount: Int    // cluster width (WeekGrid.tsx:69-97)
    }
    public static func weekDays(containing date: Date, calendar: Calendar) -> [Date]  // 7 days
    public static func timedLayout(for day: Date, events: [CalendarEvent], calendar: Calendar) -> [PositionedEvent]
    public static func allDayEvents(for day: Date, events: [CalendarEvent], calendar: Calendar) -> [CalendarEvent]
        // exclusive end-date rule + same-day start==end case, WeekGrid.tsx:102-117
}
```

The view maps minutes → points with its own `hourHeight` constant; the layout stays
geometry-free.

### `CalendarPageViewModel`

```swift
@MainActor @Observable
public final class CalendarPageViewModel {
    public enum PageState: Equatable { case loading, noAccess, neverSynced, ready }

    public private(set) var state: PageState = .loading
    public private(set) var weekStart: Date
    public private(set) var events: [CalendarEvent] = []          // visible week only
    public private(set) var calendarColors: [String: String] = [:] // calendarId → hex
    public private(set) var linkedMeetingTitles: [MeetingID: String] = [:] // for linked-badge + detail
    public private(set) var isSyncing = false
    public private(set) var refreshError: String?                 // real error or nil

    public init(database: AppDatabase, source: (any CalendarSourcing)? = nil,
                calendar: Calendar = .current, now: @escaping @Sendable () -> Date = Date.init)

    public func load() async                 // permission → state; colors; events for week
    public func syncOnAppear() async         // guarded + single-flight; refetch on success
    public func showPreviousWeek() async
    public func showNextWeek() async
    public func showToday() async
    public func link(eventId: CalendarEventID, to meetingId: MeetingID) async
    public func unlink(eventId: CalendarEventID) async
    public func meetingsForPicker() async -> [Meeting]            // newest-first
    public var visibleRange: ClosedRange<Date> { get }            // weekStart ... weekStart+7d
}
```

Same optional-source pattern as `CalendarSettingsViewModel`: `nil` source (tests,
previews) → permission stays honest `.noAccess`-side; the app injects
`environment.calendarSource`.

### RootSplitView wiring

Replace the `.calendar` placeholder with:

```swift
case .calendar:
    CalendarPageView(
        database: database,
        calendarSource: environment.calendarSource,
        recordingSession: environment.recordingSession,
        selection: $selectedSection,                 // Settings jump + start-meeting jump
        onOpenMeeting: { path.append($0) }           // linked meeting → existing MeetingID destination
    )
```

`onOpenMeeting` rides the existing `navigationDestination(for: MeetingID.self)` — the same
push pattern `MeetingsListView` uses.

## 4. Data flow & concurrency

- **Local-DB-first:** `load()` reads `events(startingIn: visibleRange)` + `syncSettings()`
  colors, renders immediately — same posture as the Rust page (`page.tsx:57-72`). No live
  `ValueObservation` in v1: explicit refetch after week change / sync / link / unlink is
  sufficient and simpler (single-user scale). `observeAll()` exists if v2 wants it.
- **Sync-on-appear:** `syncOnAppear()` — skip unless `permissionStatus() == .fullAccess`
  AND `selectedCalendarIds()` non-empty (mirrors CalendarSyncScheduler.runOnce, and the
  revoked-grant tombstone hazard); single-flight via `isSyncing`; the view calls it from
  `.task` so it runs at most once per appearance. On success: refetch events + colors,
  clear `refreshError`. On failure: keep showing stored events, set `refreshError` to the
  real error (small non-blocking note — the stored data is honest, the failed *refresh*
  is disclosed).
- **Isolation:** VM is `@MainActor`; all awaits are repository/engine calls that hop to
  GRDB's own queues (`CalendarSyncEngine` is `Sendable`). Nothing here touches the audio
  hot path. No `@unchecked Sendable` anywhere.
- **Persistence:** zero schema changes; repository-only access; `AppDatabase` remains the
  single DB owner.

## 5. Start-meeting seam (investigated)

How recording starts today: `RecordingSession` (app-wide, owned by `AppEnvironment`)
creates the `Meeting` row inside `performStart()` *after* capture actually starts, titled
from `pendingTitle` (RecordingSession.swift:167-208). The RootSplitView `.newMeeting`
case just renders the session.

**Chosen seam — a pending-link field on `RecordingSession`, mirroring `pendingTitle`:**

```swift
/// Set by the Calendar page before handoff; consumed at meeting creation; cleared by reset().
public struct PendingCalendarLink: Equatable, Sendable {
    public var eventId: CalendarEventID
    public var eventTitle: String   // for the visible chip only
}
public var pendingCalendarLink: PendingCalendarLink?
```

- In `performStart()`, immediately after the `database.meetings.upsert(meeting)` succeeds:
  `try? await database.calendarEvents.setManualLink(eventId:, meetingId: newMeetingId)`
  and clear the field. Best-effort — a failed link never fails the recording. `reset()`
  clears it alongside `pendingTitle`.
- Calendar page's "Start meeting": only enabled when `session` exists and
  `!session.isActive` (disabled with an honest reason otherwise — one live session).
  Action: set `pendingTitle = event.title` (only if currently blank — never clobber user
  input), set `pendingCalendarLink`, flip `selection = .newMeeting`. Consent flow is
  untouched — the user still confirms consent-before-record on the recording page.
- **Visibility (No-Fake-State):** `RecordingView`'s idle screen shows a small removable
  chip under the title field when `pendingCalendarLink != nil` — "Will link to: *Event
  title*" with an ✕ — so a stale intent can't silently link the wrong event. The event
  detail sheet never shows "Linked" from intent; the linked-meeting row renders only from
  a real `event.meetingId` read back from the store.

**What v1 does / doesn't do:** the link is written at meeting-row creation (a few
hundred ms after Record is confirmed), not before — there is no meeting to link before
then, and No-Fake-State forbids pretending otherwise. If the user cancels consent, no
meeting and no link exist; the chip remains for the next attempt (removable). If the link
write itself fails, the recording proceeds and the event simply stays unlinked (the
detail sheet will honestly show no link; the user can link manually afterward — and the
S7 auto-match pass may also catch it on a later sync).

This is ~15 lines in `RecordingSession` and the only durable seam — a view-scoped
observer on the calendar page would die when navigation switches sections.

## 6. Tests (Lane 1, Swift Testing — written first)

`AriKit/Tests/AriViewModelsTests/CalendarPageViewModelTests.swift` (sibling of
`CalendarSettingsViewModelTests.swift`), in-memory `AppDatabase` + the existing fake
`CalendarSourcing` test double:

1. **Visible-range fetch** — seed events inside/outside the week; `load()` returns only
   the week's, sorted; week pager (`showNextWeek` etc.) refetches the new range.
2. **Honest no-access** — source reports denied/notDetermined → `state == .noAccess`;
   no source injected → same; never `.ready` over an unreadable calendar.
3. **Honest never-synced** — full access but `latestSyncedAt() == nil` →
   `state == .neverSynced`; after a sync writes rows → `.ready`.
4. **Sync-on-appear guards** — no selected calendars, or non-fullAccess → the engine is
   never invoked (spy source); with both satisfied it runs exactly once per call and
   refetches.
5. **Link/unlink round-trip** — `link(eventId:to:)` → row re-read has
   `meetingId` + `linkSource == .manual`; `unlink` clears both; a subsequent
   `syncUpsert` pass preserves the manual link (regression on the S7 invariant).
6. **Refresh-failure honesty** — throwing engine → stored events still returned,
   `refreshError` carries the real error string.

`CalendarWeekLayoutTests.swift` (pure functions):

7. **Overlap clustering parity** — cases mirrored from `WeekGrid.tsx:69-97`: disjoint
   events (1 column), two overlapping (2 columns each), transitive chain shares one
   column count, column reuse after an event ends; min 15-minute duration clamp.
8. **All-day bucketing** — exclusive end date, same-day `start == end` case, multi-day
   span appears in every covered day (`WeekGrid.tsx:102-117`).

`RecordingSessionTests` additions:

9. **Pending-link consumption** — `pendingCalendarLink` set → after a successful start,
   the event row is manually linked to the new `meetingId` and the field is cleared.
10. **Pending-link never blocks** — link write failure (event deleted) → phase still
    reaches `.recording`; consent-cancel path writes no link.
11. **Reset clears the pending link** (alongside the existing reset assertions).

The grid/sheet visuals are Lane-2: eyeballed live (Paul is testing) via `/swift-run`;
no snapshot harness in v1.

## 7. Invariants preserved

- **No-Fake-State:** every page state is backed by a real read (permission, `MAX(syncedAt)`,
  row fetch); "linked" renders only from persisted `meetingId`; colors absent → neutral
  Marginalia surface tint, never an invented color; sync failures disclosed, not hidden.
- **Consent-before-record:** untouched — the handoff lands on the recording page *before*
  the consent gate; `confirmConsent*` remains the only edge into capture.
- **Recall safety shell:** not touched by this feature.
- **Single DB owner / repositories-only:** all reads and writes via `AppDatabase`
  repositories; no new schema.

## 8. Slices & sequencing

1. **Slice 1 — Read-only week grid.** `CalendarWeekLayout` + tests (7, 8);
   `CalendarPageViewModel` (load, states, pager, sync-on-appear) + tests (1–4, 6);
   `CalendarPageView` + `CalendarWeekGrid` + `CalendarEventBlock`; RootSplitView swap;
   shared hex-color helper. *Accept:* Paul sees his real week, tinted, honest states for
   no-access/never-synced, pager + Today work, background refresh on open.
2. **Slice 2 — Event detail + linking.** `EventDetailSheet` (attendees from the real
   array), `LinkMeetingSheet`, VM `link`/`unlink`/`meetingsForPicker` + test (5),
   open-linked-meeting push. *Accept:* click event → full details incl. attendees;
   link/unlink an existing meeting; linked meeting opens in MeetingDetail; link survives
   a manual "Sync now".
3. **Slice 3 — Start meeting from event.** `PendingCalendarLink` on `RecordingSession`
   + tests (9–11); the RecordingView chip; the sheet's Start action + active-session
   disable. *Accept:* Start from an event lands on New meeting pre-titled with a visible
   removable "Will link to" chip; after Record→Stop, the event shows the linked meeting.

**Follow-on — Home calendar brief (2026-07-22).** A "From your calendar" brief on the Home
screen (`Ari/UI/Home/CalendarBriefSection.swift` + `CalendarBriefViewModel` in AriViewModels),
the Swift port of the frozen Rust `UpcomingMeetingsPanel`. Local-DB-first read of already-synced
events gated on `.fullAccess` (never a live EventKit call), filtered to the meetings happening now
or about to start (lookahead 3h / late-join grace 30m; all-day + already-linked excluded; capped
at 3), each with a one-tap **Record** that reuses this slice's exact start-meeting seam
(`RecordingSession.reset()` → seed `pendingTitle` when blank → `pendingCalendarLink` →
`selection = .newMeeting`). Answers "I opened the app mid-meeting and forgot to hit record":
in-progress meetings carry a live "Now" badge so current meetings read distinctly from future
ones. Hidden entirely when nothing qualifies (No-Fake-State — Home never nags about calendar
setup; that stays in Settings). Filter logic is a pure `static` under
`CalendarBriefViewModelTests`.

**Risks:** (a) SwiftUI grid alignment once a scrollbar appears — mitigated by the Rust
page's lesson (one shared scroll container, `WeekGrid.tsx:144-148`); keep header + grid
in one `ScrollView` with a pinned header. (b) Stale pending link — mitigated by the
visible chip (§5). (c) Timezone/DST week math — use `Calendar.current` everywhere and an
injected `Calendar` in layout functions so tests pin a fixed zone. No sidecar fallback
needed — this is pure UI over landed subsystems.
