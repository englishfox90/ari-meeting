//
//  FakeCalendarSource.swift — the `CalendarSourcing` test double for `CalendarSettingsViewModel`
//  and `CalendarPageViewModel` tests (docs/plans/arikit-calendar.md §6,
//  docs/plans/arikit-calendar-ui.md §6). A separate, minimal double from `AriKitTests`'
//  `FakeCalendarSource` (test targets don't share test-only sources) — same scripted-state shape,
//  plus call tracking + error injection for the page VM's sync-on-appear guard/failure tests.
//
import AriKit
import Foundation

actor FakeCalendarSource: CalendarSourcing {
    private var permission: CalendarPermission
    private var calendars: [NativeCalendar]
    private var events: [NativeEvent]
    private var fetchError: (any Error)?
    private(set) var fetchEventsCallCount = 0

    init(
        permission: CalendarPermission = .fullAccess,
        calendars: [NativeCalendar] = [],
        events: [NativeEvent] = [],
        fetchError: (any Error)? = nil
    ) {
        self.permission = permission
        self.calendars = calendars
        self.events = events
        self.fetchError = fetchError
    }

    func permissionStatus() async -> CalendarPermission {
        permission
    }

    func requestFullAccess() async throws -> CalendarPermission {
        permission = .fullAccess
        return permission
    }

    func setPermission(_ newPermission: CalendarPermission) {
        permission = newPermission
    }

    func listCalendars() async throws -> [NativeCalendar] {
        calendars
    }

    func fetchEvents(calendarIds: [String], from start: Date, to end: Date) async throws -> [NativeEvent] {
        fetchEventsCallCount += 1
        if let fetchError {
            throw fetchError
        }
        guard !calendarIds.isEmpty else { return [] }
        return events.filter { !$0.id.isEmpty && calendarIds.contains($0.calendarId) }
    }
}
