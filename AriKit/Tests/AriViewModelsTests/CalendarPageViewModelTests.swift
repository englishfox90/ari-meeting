//
//  CalendarPageViewModelTests.swift — docs/plans/arikit-calendar-ui.md §6, tests 1-4, 6
//  (sibling of `CalendarSettingsViewModelTests.swift`; test 5, link/unlink, lands in Slice 2
//  per the plan's own test numbering).
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

private struct TestSyncError: Error, CustomStringConvertible {
    let description: String
}

@Suite("CalendarPageViewModel")
@MainActor
struct CalendarPageViewModelTests {
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func date(year: Int, month: Int, day: Int, hour: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return utcCalendar.date(from: components)!
    }

    private static func makeEvent(
        id: CalendarEventID,
        calendarId: String = "cal-1",
        start: Date,
        end: Date
    ) -> CalendarEvent {
        CalendarEvent(
            id: id, calendarId: calendarId, calendarTitle: "Work", title: "Event",
            startTime: start, endTime: end, isAllDay: false, attendees: []
        )
    }

    // MARK: - 1. Visible-range fetch

    @Test("load() returns only events within the visible week; the pager refetches for the new range")
    func visibleRangeFetch() async throws {
        let db = try AppDatabase.makeInMemory()
        let calendar = Self.utcCalendar
        let fixedNow = Self.date(year: 2026, month: 7, day: 15, hour: 10) // a Wednesday
        try await db.calendarEvents.setSyncSetting(
            calendarId: "cal-1", calendarTitle: "Work", color: "#112233", selected: true
        )

        let weekStart = CalendarWeekLayout.weekDays(containing: fixedNow, calendar: calendar)[0]
        let thisWeekTime = calendar.date(byAdding: .day, value: 1, to: weekStart)!.addingTimeInterval(3600)
        let nextWeekTime = calendar.date(byAdding: .weekOfYear, value: 1, to: thisWeekTime)!

        try await db.calendarEvents.syncUpsert(
            [
                Self.makeEvent(id: "ev-this-week", start: thisWeekTime, end: thisWeekTime.addingTimeInterval(1800)),
                Self.makeEvent(id: "ev-next-week", start: nextWeekTime, end: nextWeekTime.addingTimeInterval(1800))
            ],
            at: fixedNow
        )

        let source = FakeCalendarSource(permission: .fullAccess)
        let viewModel = CalendarPageViewModel(database: db, source: source, calendar: calendar, now: { fixedNow })
        await viewModel.load()

        #expect(viewModel.state == .ready)
        #expect(viewModel.events.map(\.id) == ["ev-this-week"])

        await viewModel.showNextWeek()
        #expect(viewModel.events.map(\.id) == ["ev-next-week"])

        await viewModel.showPreviousWeek()
        #expect(viewModel.events.map(\.id) == ["ev-this-week"])
    }

    // MARK: - 2. Honest no-access

    @Test("denied, notDetermined, and no-source all read as honest .noAccess — never .ready")
    func honestNoAccess() async throws {
        let db = try AppDatabase.makeInMemory()

        let deniedSource = FakeCalendarSource(permission: .denied)
        let deniedVM = CalendarPageViewModel(database: db, source: deniedSource)
        await deniedVM.load()
        #expect(deniedVM.state == .noAccess)

        let notDeterminedSource = FakeCalendarSource(permission: .notDetermined)
        let notDeterminedVM = CalendarPageViewModel(database: db, source: notDeterminedSource)
        await notDeterminedVM.load()
        #expect(notDeterminedVM.state == .noAccess)

        let noSourceVM = CalendarPageViewModel(database: db)
        await noSourceVM.load()
        #expect(noSourceVM.state == .noAccess)
    }

    // MARK: - 3. Honest never-synced

    @Test("full access but never synced ⇒ .neverSynced; after a sync writes rows ⇒ .ready")
    func honestNeverSynced() async throws {
        let db = try AppDatabase.makeInMemory()
        let source = FakeCalendarSource(permission: .fullAccess)
        let viewModel = CalendarPageViewModel(database: db, source: source)

        await viewModel.load()
        #expect(viewModel.state == .neverSynced)
        #expect(viewModel.events.isEmpty)

        try await db.calendarEvents.syncUpsert(
            [Self.makeEvent(id: "ev-1", start: Date(), end: Date().addingTimeInterval(1800))],
            at: Date()
        )

        await viewModel.load()
        #expect(viewModel.state == .ready)
    }

    // MARK: - 4. Sync-on-appear guards

    @Test("syncOnAppear skips the engine unless full access AND a non-empty selection")
    func syncOnAppearGuardsSkipTheEngine() async throws {
        let db = try AppDatabase.makeInMemory()

        // No calendars selected — full access, but nothing selected.
        let noSelectionSource = FakeCalendarSource(permission: .fullAccess)
        let noSelectionVM = CalendarPageViewModel(database: db, source: noSelectionSource)
        await noSelectionVM.syncOnAppear()
        #expect(await noSelectionSource.fetchEventsCallCount == 0)

        // A selection exists, but access isn't full.
        try await db.calendarEvents.setSyncSetting(
            calendarId: "cal-1", calendarTitle: "Work", color: nil, selected: true
        )
        let deniedSource = FakeCalendarSource(permission: .denied)
        let deniedVM = CalendarPageViewModel(database: db, source: deniedSource)
        await deniedVM.syncOnAppear()
        #expect(await deniedSource.fetchEventsCallCount == 0)
    }

    @Test("syncOnAppear runs the engine exactly once when guards are satisfied, and refetches")
    func syncOnAppearRunsOnceAndRefetches() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.calendarEvents.setSyncSetting(
            calendarId: "cal-1", calendarTitle: "Work", color: nil, selected: true
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let source = FakeCalendarSource(
            permission: .fullAccess,
            events: [
                NativeEvent(
                    id: "ev-1", calendarId: "cal-1", title: "Sync",
                    startTime: now, endTime: now.addingTimeInterval(1800), isAllDay: false
                )
            ]
        )
        let viewModel = CalendarPageViewModel(database: db, source: source, now: { now })

        await viewModel.syncOnAppear()

        #expect(await source.fetchEventsCallCount == 1)
        #expect(viewModel.refreshError == nil)
        #expect(viewModel.state == .ready)
        #expect(viewModel.events.map(\.id) == ["ev-1"])
    }

    // MARK: - 6. Refresh-failure honesty

    @Test("a failing background sync keeps the stored events and surfaces the real error")
    func refreshFailureHonesty() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.calendarEvents.setSyncSetting(
            calendarId: "cal-1", calendarTitle: "Work", color: nil, selected: true
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await db.calendarEvents.syncUpsert(
            [Self.makeEvent(id: "ev-1", start: now, end: now.addingTimeInterval(1800))],
            at: now
        )

        let source = FakeCalendarSource(
            permission: .fullAccess,
            fetchError: TestSyncError(description: "network unreachable")
        )
        let viewModel = CalendarPageViewModel(database: db, source: source, now: { now })
        await viewModel.load()
        #expect(viewModel.state == .ready)
        let eventsBeforeSync = viewModel.events

        await viewModel.syncOnAppear()

        #expect(viewModel.events == eventsBeforeSync)
        #expect(viewModel.refreshError == "network unreachable")
    }
}
