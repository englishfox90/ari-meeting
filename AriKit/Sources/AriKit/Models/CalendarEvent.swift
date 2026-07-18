//
//  CalendarEvent.swift — a calendar event + its attendees (F4)
//  (← Rust `CalendarEvent` / `Attendee`, calendar/models.rs:24 / :17).
//
//  `startTime`/`endTime` are real instants (`Date`, plan §7.3). `attendees` is embedded inline
//  (the frozen engine shape; the `meetingEvent` + `attendee` link-table split is a Store delta,
//  plan §4). `linkSource` is a forward-tolerant enum. `calendarId` stays a plain `String`: the
//  calendar is not a modeled domain entity here, so there is no `Identifier<Calendar>` to type it.
//
import Foundation

/// Typed identifier for a `CalendarEvent` (plan §7.4).
public typealias CalendarEventID = Identifier<CalendarEvent>

/// Whether an event was linked to a meeting manually or via calendar matching (plan §7.2).
public enum CalendarLinkSource: UnknownTolerantEnum {
    case manual
    case calendar
    case unknown(String)

    public init?(rawValue: String) {
        switch rawValue {
        case "manual": self = .manual
        case "calendar": self = .calendar
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .manual: "manual"
        case .calendar: "calendar"
        case let .unknown(raw): raw
        }
    }

    public static func unknownCase(_ rawValue: String) -> Self { .unknown(rawValue) }
    public init(from decoder: any Decoder) throws { try self.init(tolerantFrom: decoder) }
    public func encode(to encoder: any Encoder) throws { try encodeTolerant(to: encoder) }
}

/// A meeting attendee as surfaced by the calendar (pure value type).
public struct Attendee: Codable, Hashable, Sendable {
    public var name: String?
    public var email: String?

    public init(name: String? = nil, email: String? = nil) {
        self.name = name
        self.email = email
    }
}

public struct CalendarEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: CalendarEventID
    /// Owning calendar identifier. Plain `String` — the calendar is not a modeled entity here.
    public var calendarId: String
    public var calendarTitle: String?
    public var title: String
    public var startTime: Date
    public var endTime: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var organizer: String?
    public var attendees: [Attendee]
    public var meetingId: MeetingID?
    public var linkSource: CalendarLinkSource?

    public init(
        id: CalendarEventID,
        calendarId: String,
        calendarTitle: String? = nil,
        title: String,
        startTime: Date,
        endTime: Date,
        isAllDay: Bool,
        location: String? = nil,
        notes: String? = nil,
        organizer: String? = nil,
        attendees: [Attendee],
        meetingId: MeetingID? = nil,
        linkSource: CalendarLinkSource? = nil
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
        self.meetingId = meetingId
        self.linkSource = linkSource
    }
}
