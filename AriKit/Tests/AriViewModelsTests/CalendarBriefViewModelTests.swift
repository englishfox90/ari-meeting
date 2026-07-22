//
//  CalendarBriefViewModelTests.swift — the Home calendar brief's window/gating logic (the Swift
//  port of the frozen Rust `UpcomingMeetingsPanel` `upcoming` `useMemo`).
//
//  Split in two: the pure `brief(from:now:)` filter is exercised directly (no source/DB), and
//  `load()` is exercised end-to-end through an in-memory store + `FakeCalendarSource` for the
//  permission gate and DB-range read.
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("CalendarBriefViewModel")
@MainActor
struct CalendarBriefViewModelTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static func event(
        id: CalendarEventID,
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        isAllDay: Bool = false,
        meetingId: MeetingID? = nil
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            calendarId: "cal-1",
            calendarTitle: "Work",
            title: "Event \(id.rawValue)",
            startTime: now.addingTimeInterval(startOffset),
            endTime: now.addingTimeInterval(endOffset),
            isAllDay: isAllDay,
            attendees: [],
            meetingId: meetingId
        )
    }

    private static let minute: TimeInterval = 60
    private static let hour: TimeInterval = 3600

    // MARK: - Pure filter

    @Test("an in-progress meeting is kept; a long one that began hours ago but is still live too")
    func keepsInProgress() {
        let shortLive = Self.event(id: "live-short", startOffset: -10 * minute, endOffset: 20 * minute)
        let longLive = Self.event(id: "live-long", startOffset: -3 * hour, endOffset: 1 * hour)
        let result = CalendarBriefViewModel.brief(from: [shortLive, longLive], now: Self.now)
        #expect(result.map(\.id) == ["live-long", "live-short"]) // soonest start first
    }

    @Test("an upcoming meeting inside the lookahead is kept; one beyond it is dropped")
    func lookaheadBoundary() {
        let soon = Self.event(id: "soon", startOffset: 1 * hour, endOffset: 2 * hour)
        let farFuture = Self.event(id: "far", startOffset: 5 * hour, endOffset: 6 * hour)
        let result = CalendarBriefViewModel.brief(from: [soon, farFuture], now: Self.now)
        #expect(result.map(\.id) == ["soon"])
    }

    @Test("late-join grace: a short meeting that just ended within the window is still offered")
    func lateJoinGrace() {
        // Started 20 min ago, ended 5 min ago — past its end, but within the 30-min late-join grace.
        let justEnded = Self.event(id: "just-ended", startOffset: -20 * minute, endOffset: -5 * minute)
        // Started 45 min ago, ended 15 min ago — outside the grace, and not in progress.
        let staleEnded = Self.event(id: "stale", startOffset: -45 * minute, endOffset: -15 * minute)
        let result = CalendarBriefViewModel.brief(from: [justEnded, staleEnded], now: Self.now)
        #expect(result.map(\.id) == ["just-ended"])
    }

    @Test("all-day events and events already linked to a meeting are excluded")
    func excludesAllDayAndLinked() {
        let allDay = Self.event(id: "all-day", startOffset: -1 * hour, endOffset: 8 * hour, isAllDay: true)
        let linked = Self.event(id: "linked", startOffset: 0, endOffset: 1 * hour, meetingId: "m-1")
        let plain = Self.event(id: "plain", startOffset: 0, endOffset: 1 * hour)
        let result = CalendarBriefViewModel.brief(from: [allDay, linked, plain], now: Self.now)
        #expect(result.map(\.id) == ["plain"])
    }

    @Test("the brief is capped at maxEvents, keeping the soonest")
    func capsAtMaxEvents() {
        let events = (0 ..< (CalendarBriefViewModel.maxEvents + 2)).map { index in
            Self.event(
                id: CalendarEventID("ev-\(index)"),
                startOffset: TimeInterval(index) * 10 * minute,
                endOffset: TimeInterval(index) * 10 * minute + hour
            )
        }
        let result = CalendarBriefViewModel.brief(from: events.shuffled(), now: Self.now)
        #expect(result.count == CalendarBriefViewModel.maxEvents)
        #expect(result.map(\.id) == (0 ..< CalendarBriefViewModel.maxEvents).map { CalendarEventID("ev-\($0)") })
    }

    @Test("isInProgress is true only between start and end")
    func inProgressPredicate() {
        let live = Self.event(id: "live", startOffset: -10 * minute, endOffset: 10 * minute)
        let future = Self.event(id: "future", startOffset: 10 * minute, endOffset: 20 * minute)
        let past = Self.event(id: "past", startOffset: -20 * minute, endOffset: -10 * minute)
        #expect(CalendarBriefViewModel.isInProgress(live, now: Self.now))
        #expect(!CalendarBriefViewModel.isInProgress(future, now: Self.now))
        #expect(!CalendarBriefViewModel.isInProgress(past, now: Self.now))
    }

    // MARK: - load() gating + DB read

    @Test("no source / denied access ⇒ honest empty brief (never surfaces stored rows)")
    func loadHonestNoAccess() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.calendarEvents.syncUpsert(
            [Self.event(id: "live", startOffset: 0, endOffset: hour)],
            at: Self.now
        )

        let noSourceVM = CalendarBriefViewModel(database: db, now: { Self.now })
        await noSourceVM.load()
        #expect(noSourceVM.events.isEmpty)

        let deniedVM = CalendarBriefViewModel(
            database: db, source: FakeCalendarSource(permission: .denied), now: { Self.now }
        )
        await deniedVM.load()
        #expect(deniedVM.events.isEmpty)
    }

    @Test("full access ⇒ load() reads the store and applies the brief window")
    func loadFullAccessReadsStore() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.calendarEvents.syncUpsert(
            [
                Self.event(id: "live", startOffset: -10 * minute, endOffset: 20 * minute),
                Self.event(id: "soon", startOffset: 1 * hour, endOffset: 2 * hour),
                Self.event(id: "far", startOffset: 6 * hour, endOffset: 7 * hour)
            ],
            at: Self.now
        )

        let viewModel = CalendarBriefViewModel(
            database: db, source: FakeCalendarSource(permission: .fullAccess), now: { Self.now }
        )
        await viewModel.load()
        #expect(viewModel.events.map(\.id) == ["live", "soon"])
    }
}
