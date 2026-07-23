//
//  CalendarEvent.swift — a calendar event + its attendees (F4)
//  (← Rust `CalendarEvent` / `Attendee`, calendar/models.rs:24 / :17).
//
//  `startTime`/`endTime` are real instants (`Date`, plan §7.3). `attendees` is embedded inline
//  (the frozen engine shape; the `meetingEvent` + `attendee` link-table split is a Store delta,
//  plan §4). `linkSource` is a forward-tolerant enum. `calendarId` stays a plain `String`: the
//  calendar is not a modeled domain entity here, so there is no `Identifier<Calendar>` to type it.
//
//  Store-port follow-ons (docs/plans/arikit-store.md §4.8 / arikit-models.md §7.7's deferred-DTO
//  note): `seriesKey`/`hasRecurrence`/`occurrenceDate`/`isDetached` are EventKit recurrence
//  signals that live on the capture-layer `NativeEvent` in the frozen engine, never on the wire
//  `CalendarEvent` DTO — they "surface on `CalendarEvent`... when persisted," per that note. All
//  four are `Optional` here (not defaulted to `false`/`nil`-as-known): `nil` means "not captured /
//  unknown," a real state distinct from "known non-recurring," which the Store's nullable columns
//  preserve losslessly rather than collapsing to a default.
//
import Foundation

/// Typed identifier for a `CalendarEvent` (plan §7.4).
public typealias CalendarEventID = Identifier<CalendarEvent>

/// Whether an event was linked to a meeting manually or via calendar matching (plan §7.2).
///
/// `.auto` (rawValue `"auto"`) was added in the S7 EventKit slice
/// (`docs/plans/arikit-calendar.md`, resolved decision 1): the Swift `CalendarSyncEngine`'s
/// auto-match pass writes `"auto"`, uniform with the value legacy-imported rows already carry
/// (the frozen Rust engine wrote `link_source = 'auto'` too — see `calendar.rs:332`). Before this
/// slice, an imported `"auto"` row decoded as `.unknown("auto")`; it now decodes as `.auto`.
public enum CalendarLinkSource: UnknownTolerantEnum {
    case manual
    case calendar
    case auto
    /// The user explicitly unlinked this event's meeting. A durable sentinel (`meetingId` is
    /// `nil`, but the source is recorded) that keeps auto-match from silently re-linking the
    /// event to a meeting whose time window still overlaps it. Survives re-sync because
    /// `syncUpsert` never touches `linkSource`. A subsequent manual link overrides it.
    case unlinked
    case unknown(String)

    public init?(rawValue: String) {
        switch rawValue {
        case "manual": self = .manual
        case "calendar": self = .calendar
        case "auto": self = .auto
        case "unlinked": self = .unlinked
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .manual: "manual"
        case .calendar: "calendar"
        case .auto: "auto"
        case .unlinked: "unlinked"
        case let .unknown(raw): raw
        }
    }

    public static func unknownCase(_ rawValue: String) -> Self {
        .unknown(rawValue)
    }

    public init(from decoder: any Decoder) throws {
        try self.init(tolerantFrom: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try encodeTolerant(to: encoder)
    }
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
    /// Stable recurrence key (EventKit `calendarItemExternalIdentifier`) — Store-port follow-on,
    /// see file header.
    public var seriesKey: String?
    /// Whether this event has recurrence rules (`hasRecurrenceRules`) — `nil` if not captured.
    public var hasRecurrence: Bool?
    /// RFC3339 instant of this specific occurrence, if any.
    public var occurrenceDate: Date?
    /// Whether this occurrence was detached/edited from the series — `nil` if not captured.
    public var isDetached: Bool?

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
        linkSource: CalendarLinkSource? = nil,
        seriesKey: String? = nil,
        hasRecurrence: Bool? = nil,
        occurrenceDate: Date? = nil,
        isDetached: Bool? = nil
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
        self.seriesKey = seriesKey
        self.hasRecurrence = hasRecurrence
        self.occurrenceDate = occurrenceDate
        self.isDetached = isDetached
    }
}
