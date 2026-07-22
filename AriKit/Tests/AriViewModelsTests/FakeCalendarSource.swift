//
//  FakeCalendarSource.swift — the `CalendarSourcing` test double for `CalendarSettingsViewModel`
//  tests (docs/plans/arikit-calendar.md §6). A separate, minimal double from `AriKitTests`'
//  `FakeCalendarSource` (test targets don't share test-only sources) — same scripted-state shape,
//  only what the VM's `load()`/`requestAccess()`/`syncNow()` paths need.
//
import AriKit
import Foundation

actor FakeCalendarSource: CalendarSourcing {
    private var permission: CalendarPermission
    private var calendars: [NativeCalendar]
    private var events: [NativeEvent]

    init(
        permission: CalendarPermission = .fullAccess,
        calendars: [NativeCalendar] = [],
        events: [NativeEvent] = []
    ) {
        self.permission = permission
        self.calendars = calendars
        self.events = events
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
        guard !calendarIds.isEmpty else { return [] }
        return events.filter { !$0.id.isEmpty && calendarIds.contains($0.calendarId) }
    }
}
