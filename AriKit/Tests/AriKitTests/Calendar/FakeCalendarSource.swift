//
//  FakeCalendarSource.swift — the Lane-1 `CalendarSourcing` test double (plan §6).
//
//  Scripted calendars/events/permission, headless. Models the source-level contract an
//  `EventKitCalendarSource` conformer must uphold so `CalendarSyncEngineTests` exercises the same
//  invariants the app-target actor is code-reviewed against in C3:
//    - events with an empty/missing identifier are skipped before they ever reach the engine
//      (parity: `eventkit.rs:221-226`);
//    - an empty `calendarIds` list short-circuits to `[]` (parity: `eventkit.rs:184-186`).
//
//  An `actor` (not a plain struct) so tests can script/replace events between two `syncRange`
//  passes and inspect recorded calls — no `@unchecked Sendable` needed; actor isolation covers it.
//
import Foundation
@testable import AriKit

actor FakeCalendarSource: CalendarSourcing {
    private var permission: CalendarPermission
    private var calendars: [NativeCalendar]
    private var events: [NativeEvent]
    private(set) var fetchCalls: [(ids: [String], start: Date, end: Date)] = []

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

    func setCalendars(_ newCalendars: [NativeCalendar]) {
        calendars = newCalendars
    }

    func setEvents(_ newEvents: [NativeEvent]) {
        events = newEvents
    }

    func fetchEvents(calendarIds: [String], from start: Date, to end: Date) async throws -> [NativeEvent] {
        fetchCalls.append((calendarIds, start, end))
        guard !calendarIds.isEmpty else { return [] }
        return events.filter { !$0.id.isEmpty && calendarIds.contains($0.calendarId) }
    }
}
