//
//  CalendarEventRecord.swift — GRDB record for the `calendarEvent` table (plan §4.8).
//
//  Store-internal only — `CalendarEventRepository` translates to/from the public
//  `AriKit.Models.CalendarEvent` value type. `attendees` is kept as an inline JSON column
//  (`attendeesJson`, plan §0.1(2)) — encoded/decoded through `Models.jsonEncoder`/
//  `Models.jsonDecoder` here so a malformed/missing blob never crashes a read (`asModel()` falls
//  back to `[]`, matching the domain type's non-optional `attendees: [Attendee]`).
//
//  ⚠️ `syncedAt` exists as a schema column (§4.8) but `CalendarEvent` (AriKit.Models) carries no
//  `syncedAt` field — the same documented gap as `Meeting.templateId`
//  (`Records/MeetingRecord.swift`). Always persisted as `NULL` here, not part of the round trip;
//  a future calendar-sync pass owns writing it directly (outside `upsert(_:)`).
//
import Foundation
import GRDB

struct CalendarEventRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "calendarEvent"

    var id: String
    var calendarId: String
    var calendarTitle: String?
    var title: String
    var startTime: Date
    var endTime: Date
    var isAllDay: Bool
    var location: String?
    var notes: String?
    var organizer: String?
    var attendeesJson: String
    var meetingId: String?
    var linkSource: String?
    var seriesKey: String?
    var hasRecurrence: Bool?
    var occurrenceDate: Date?
    var isDetached: Bool?
    var syncedAt: Date?
    var isDeleted: Bool
    var deletedAt: Date?
}

extension CalendarEventRecord {
    /// Throws only if `event.attendees` somehow fails to encode (never expected for this plain
    /// value type) — surfaced rather than silently dropping attendee data (No-Fake-State).
    init(_ event: CalendarEvent) throws {
        id = event.id.rawValue
        calendarId = event.calendarId
        calendarTitle = event.calendarTitle
        title = event.title
        startTime = event.startTime
        endTime = event.endTime
        isAllDay = event.isAllDay
        location = event.location
        notes = event.notes
        organizer = event.organizer
        let data = try Models.jsonEncoder.encode(event.attendees)
        attendeesJson = String(decoding: data, as: UTF8.self)
        meetingId = event.meetingId?.rawValue
        linkSource = event.linkSource?.rawValue
        seriesKey = event.seriesKey
        hasRecurrence = event.hasRecurrence
        occurrenceDate = event.occurrenceDate
        isDetached = event.isDetached
        syncedAt = nil
        isDeleted = false
        deletedAt = nil
    }

    func asModel() -> CalendarEvent {
        let attendees: [Attendee] =
            (try? Models.jsonDecoder.decode([Attendee].self, from: Data(attendeesJson.utf8))) ?? []
        return CalendarEvent(
            id: CalendarEventID(id),
            calendarId: calendarId,
            calendarTitle: calendarTitle,
            title: title,
            startTime: startTime,
            endTime: endTime,
            isAllDay: isAllDay,
            location: location,
            notes: notes,
            organizer: organizer,
            attendees: attendees,
            meetingId: meetingId.map { MeetingID($0) },
            linkSource: linkSource.map { raw in
                CalendarLinkSource(rawValue: raw) ?? CalendarLinkSource.unknownCase(raw)
            },
            seriesKey: seriesKey,
            hasRecurrence: hasRecurrence,
            occurrenceDate: occurrenceDate,
            isDetached: isDetached
        )
    }
}
