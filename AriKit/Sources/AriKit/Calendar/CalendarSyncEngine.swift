//
//  CalendarSyncEngine.swift — the S7 sync core: fetch → upsert (link-preserving) → prune-in-range
//  → auto-match, one full pass (plan §2.2, §4). Pure orchestration over `CalendarSourcing` +
//  repositories — zero EventKit import, fully headless (Lane-1 testable with a fake source).
//
//  Parity with `sync_range_core` (`sync.rs:28-81`), minus the series-detection and
//  attendee→person reconcile hooks (`sync.rs:72, 78, 85-131` — deferred to the Series Track I
//  and F2-bridge slices respectively; both attach at the same range this engine already computes,
//  plan §4 item 8).
//
import Foundation

public struct CalendarSyncReport: Sendable, Equatable {
    /// Events returned by the source this pass (parity: `sync.rs:80` return value).
    public var fetched: Int
    public var pruned: Int
    public var autoLinked: Int

    public init(fetched: Int, pruned: Int, autoLinked: Int) {
        self.fetched = fetched
        self.pruned = pruned
        self.autoLinked = autoLinked
    }
}

public struct CalendarSyncEngine: Sendable {
    /// Auto-match slack window (parity: `sync.rs:16` `AUTO_MATCH_SLACK_MINUTES`).
    private static let autoMatchSlack: TimeInterval = 15 * 60
    /// Background window (parity: `sync.rs:20-22`).
    private static let backgroundPastDays: TimeInterval = 30 * 24 * 60 * 60
    private static let backgroundFutureDays: TimeInterval = 90 * 24 * 60 * 60

    private let source: any CalendarSourcing
    private let database: AppDatabase

    public init(source: any CalendarSourcing, database: AppDatabase) {
        self.source = source
        self.database = database
    }

    /// Fetch → upsert (link-preserving) → prune-in-range → auto-match. One full pass.
    ///
    /// Only calendars currently `selected` are fetched (parity: `calendar.rs:133-138` +
    /// `eventkit.rs:184-186` — an empty selection is a source-level short-circuit to `[]`, which
    /// naturally falls out of passing an empty id list through to `source.fetchEvents`; nothing
    /// syncs until the user opts calendars in, plan §4 item 5).
    public func syncRange(from start: Date, to end: Date, now: Date = Date()) async throws -> CalendarSyncReport {
        let selectedIds = try await database.calendarEvents.selectedCalendarIds()
        let nativeEvents = try await source.fetchEvents(calendarIds: selectedIds, from: start, to: end)
        let events = nativeEvents.map(Self.asCalendarEvent)

        try await database.calendarEvents.syncUpsert(events, at: now)

        let range = start ... end
        let fetchedIds = Set(events.map(\.id))
        let pruned = try await database.calendarEvents.pruneStaleEvents(
            startingIn: range,
            keeping: fetchedIds,
            at: now
        )

        let autoLinked = try await runAutoMatch(in: range)

        return CalendarSyncReport(fetched: events.count, pruned: pruned, autoLinked: autoLinked)
    }

    /// Convenience matching the Rust background window: now-30d … now+90d (`sync.rs:21-22`).
    public func syncDefaultWindow(now: Date = Date()) async throws -> CalendarSyncReport {
        let start = now.addingTimeInterval(-Self.backgroundPastDays)
        let end = now.addingTimeInterval(Self.backgroundFutureDays)
        return try await syncRange(from: start, to: end, now: now)
    }

    /// Refresh `calendarSyncSetting` identities from the source, preserving `selected` (parity:
    /// `calendar_list_calendars_impl`, `commands.rs:58-83`). Returns rows for the VM.
    public func refreshCalendarList() async throws
        -> [(calendarId: String, calendarTitle: String?, color: String?, selected: Bool)] {
        let calendars = try await source.listCalendars()
        var rows: [(calendarId: String, calendarTitle: String?, color: String?, selected: Bool)] = []
        rows.reserveCapacity(calendars.count)
        for calendar in calendars {
            let row = try await database.calendarEvents.upsertCalendarIdentity(
                calendarId: calendar.id,
                title: calendar.title,
                color: calendar.color
            )
            rows.append(row)
        }
        return rows
    }

    // MARK: - Auto-match (parity: `sync.rs:136-174` + `calendar.rs:254-271, 324-341, 399-423`)

    /// For each event in `range` whose link is not manual, find the meeting whose `createdAt`
    /// falls in `[event.start − 15min, event.end + 15min]`, closest to `event.start`, and link
    /// it (re-guarded against manual at the write site). Already-auto-linked events are
    /// re-evaluated every pass and may be re-pointed at a closer meeting; if no meeting matches,
    /// an existing auto link is left as-is (no candidate ⇒ no write). Manual links are never
    /// touched. Returns the number of events for which an auto link was written this pass.
    private func runAutoMatch(in range: ClosedRange<Date>) async throws -> Int {
        let candidates = try await database.calendarEvents.autoLinkableEvents(startingIn: range)
        var autoLinkedCount = 0
        for event in candidates {
            let windowStart = event.startTime.addingTimeInterval(-Self.autoMatchSlack)
            let windowEnd = event.endTime.addingTimeInterval(Self.autoMatchSlack)
            guard let meetingId = try await database.meetings.closestMeetingID(
                createdBetween: windowStart,
                and: windowEnd,
                to: event.startTime
            ) else {
                continue
            }
            try await database.calendarEvents.setAutoLink(eventId: event.id, meetingId: meetingId)
            autoLinkedCount += 1
        }
        return autoLinkedCount
    }

    private static func asCalendarEvent(_ native: NativeEvent) -> CalendarEvent {
        CalendarEvent(
            id: CalendarEventID(native.id),
            calendarId: native.calendarId,
            calendarTitle: native.calendarTitle,
            title: native.title,
            startTime: native.startTime,
            endTime: native.endTime,
            isAllDay: native.isAllDay,
            location: native.location,
            notes: native.notes,
            organizer: native.organizer,
            attendees: native.attendees,
            seriesKey: native.seriesKey,
            hasRecurrence: native.hasRecurrence,
            occurrenceDate: native.occurrenceDate,
            isDetached: native.isDetached
        )
    }
}
