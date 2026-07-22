//
//  CalendarSource.swift — the calendar-capture-layer seam (S7, plan §2.2).
//
//  `CalendarSourcing` is what `CalendarSyncEngine` depends on; `EventKitCalendarSource` (the app
//  target, `Ari/Calendar/EventKitCalendarSource.swift`) is the one production conformer, and a
//  `FakeCalendarSource` test double conforms in `AriKitTests`. No `import EventKit` anywhere in
//  this module — EK objects never cross into AriKit; `NativeCalendar`/`NativeEvent` are the
//  Sendable value-type projections the app-target actor produces internally.
//
import Foundation

/// Read-only calendar access state. Mirrors the frozen mapping (`eventkit.rs:20-30`):
/// `EKAuthorizationStatus.writeOnly` is useless for reads and maps to `.denied`.
public enum CalendarPermission: String, Sendable, Equatable {
    case notDetermined
    case restricted
    case denied
    case fullAccess
}

/// Native projection of one calendar (← Rust `NativeCalendar`, `models.rs:79-83`).
public struct NativeCalendar: Sendable, Hashable {
    public var id: String // EKCalendar.calendarIdentifier
    public var title: String
    public var color: String? // "#RRGGBB"; nil when unreadable — never fabricated

    public init(id: String, title: String, color: String? = nil) {
        self.id = id
        self.title = title
        self.color = color
    }
}

/// Native projection of one event (← Rust `NativeEvent`, `models.rs:87-110`). Value type,
/// `Sendable` — EK objects never cross this boundary.
public struct NativeEvent: Sendable, Hashable {
    public var id: String // EKEvent.eventIdentifier (skip events without one, eventkit.rs:221-226)
    public var calendarId: String
    public var calendarTitle: String?
    public var title: String
    public var startTime: Date
    public var endTime: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var organizer: String?
    /// Name from `EKParticipant.name`; email parsed from a `mailto:` URL (`eventkit.rs:162-177`).
    public var attendees: [Attendee]
    /// `calendarItemExternalIdentifier` (`eventkit.rs:255`).
    public var seriesKey: String?
    public var hasRecurrence: Bool
    public var occurrenceDate: Date?
    public var isDetached: Bool

    public init(
        id: String,
        calendarId: String,
        calendarTitle: String? = nil,
        title: String,
        startTime: Date,
        endTime: Date,
        isAllDay: Bool,
        location: String? = nil,
        notes: String? = nil,
        organizer: String? = nil,
        attendees: [Attendee] = [],
        seriesKey: String? = nil,
        hasRecurrence: Bool = false,
        occurrenceDate: Date? = nil,
        isDetached: Bool = false
    ) {
        self.id = id
        self.calendarId = calendarId
        self.calendarTitle = calendarTitle
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.organizer = organizer
        self.attendees = attendees
        self.seriesKey = seriesKey
        self.hasRecurrence = hasRecurrence
        self.occurrenceDate = occurrenceDate
        self.isDetached = isDetached
    }
}

/// The seam the sync engine and the Settings VM depend on; `EventKitCalendarSource` conforms in
/// the app target, `FakeCalendarSource` conforms in tests.
public protocol CalendarSourcing: Sendable {
    func permissionStatus() async -> CalendarPermission
    func requestFullAccess() async throws -> CalendarPermission
    func listCalendars() async throws -> [NativeCalendar]
    func fetchEvents(calendarIds: [String], from start: Date, to end: Date) async throws -> [NativeEvent]
}
