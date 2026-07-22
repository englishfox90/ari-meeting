//
//  CalendarBriefViewModel.swift — Home's "From your calendar" brief (the Swift port of the frozen
//  Rust `UpcomingMeetingsPanel`, frontend/src/components/recording/UpcomingMeetingsPanel.tsx).
//
//  Surfaces the synced calendar events that are happening NOW or about to start, so the owner can
//  start a recording — pre-named after the meeting — straight from Home. This is the "I opened the
//  app mid-meeting and forgot to hit record" shortcut: it never auto-starts anything, it's a
//  shortcut over the existing manual start flow (the same handoff the Calendar page uses).
//
//  Local-DB-first, exactly like `CalendarPageViewModel`: reads already-synced rows from
//  `CalendarEventRepository` (no live EventKit call, no permission prompt, no sync trigger — the
//  15-min background `CalendarSyncScheduler` keeps the store fresh). Gated on a real `.fullAccess`
//  read (No-Fake-State: never surfaces calendar rows the owner has since revoked access to). When
//  nothing qualifies, `events` is empty and the brief hides entirely — Home is not another place
//  to nag about calendar setup; that lives in Settings.
//
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class CalendarBriefViewModel {
    /// How far ahead an event counts as "worth a start shortcut for" (parity: Rust `LOOKAHEAD_HOURS`).
    public static let lookaheadHours = 3
    /// How long after its scheduled start a late join still gets a shortcut — covers showing up
    /// late to a short meeting whose calendar end time has already passed (parity: `LATE_JOIN_MINUTES`).
    public static let lateJoinMinutes = 30
    /// At most this many rows on the brief (parity: `MAX_EVENTS`).
    public static let maxEvents = 3

    /// The qualifying events, soonest first — real DB rows, never fabricated. Empty hides the brief.
    public private(set) var events: [CalendarEvent] = []

    private let database: AppDatabase
    private let source: (any CalendarSourcing)?
    private let now: @Sendable () -> Date

    public init(
        database: AppDatabase,
        source: (any CalendarSourcing)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.database = database
        self.source = source
        self.now = now
    }

    /// Permission gate → local read → in-memory brief filter. Best-effort throughout: no access,
    /// no source, or a failed read all leave `events` empty (the brief simply doesn't render) —
    /// never a fabricated row. The view calls this from `.task`, so it re-evaluates against a
    /// fresh `now()` every time Home appears (a meeting that has since started/passed re-sorts or
    /// drops off accordingly).
    public func load() async {
        guard let source, await source.permissionStatus() == .fullAccess else {
            events = []
            return
        }
        let reference = now()
        // The lower bound is pushed well past the late-join window (24h back, matching the Rust
        // panel's `daysPast: 1` fetch) so a long meeting that began hours ago but is STILL in
        // progress is fetched — `events(startingIn:)` filters on `startTime`, so a wide lower
        // bound is what lets the in-memory filter below decide such a meeting on its `endTime`.
        let lowerBound = reference.addingTimeInterval(-24 * 60 * 60)
        let upperBound = reference.addingTimeInterval(Double(Self.lookaheadHours) * 60 * 60)
        let fetched = (try? await database.calendarEvents.events(startingIn: lowerBound ... upperBound)) ?? []
        events = Self.brief(from: fetched, now: reference)
    }

    /// Pure filter (parity: the Rust `upcoming` `useMemo`) — kept `static` and side-effect-free so
    /// the time-window logic is unit-testable without a source/DB. Drops all-day and already-linked
    /// events (a linked event already has a recording), keeps those still in progress (`now < end`)
    /// or started within the late-join grace, excludes anything starting beyond the lookahead,
    /// sorts soonest-first, and caps at `maxEvents`.
    static func brief(from events: [CalendarEvent], now: Date) -> [CalendarEvent] {
        let lateJoin = TimeInterval(lateJoinMinutes * 60)
        let lookahead = TimeInterval(lookaheadHours * 60 * 60)
        return events
            .filter { !$0.isAllDay }
            .filter { $0.meetingId == nil }
            .filter { event in
                // Too far in the future to be worth a shortcut yet.
                if event.startTime.timeIntervalSince(now) > lookahead { return false }
                // Still in progress by the calendar's own end time, or started within the
                // late-join window — whichever gives the longer runway.
                let stillInProgress = now < event.endTime
                let startedRecently = now.timeIntervalSince(event.startTime) <= lateJoin
                return stillInProgress || startedRecently
            }
            .sorted { $0.startTime < $1.startTime }
            .prefix(maxEvents)
            .map { $0 }
    }

    /// Whether an event is happening right now (started, not yet ended) — the display signal Home
    /// uses to mark a live meeting distinctly from an upcoming one. A display helper only; the
    /// caller passes the render-time `Date` so this never captures the VM's injected clock.
    public static func isInProgress(_ event: CalendarEvent, now: Date) -> Bool {
        event.startTime <= now && now < event.endTime
    }
}
