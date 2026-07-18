//
//  CalendarEventRepository.swift — the ONLY way feature code touches the `calendarEvent` and
//  `calendarSyncSetting` tables (plan §2.2, §10 step 6).
//
//  `attendeesJson` is encoded/decoded entirely inside `CalendarEventRecord` — callers here only
//  ever see `AriKit.Models.CalendarEvent` with a real `[Attendee]` array (value in, value out).
//
//  `calendarSyncSetting` has no dedicated repository file (plan §2.1 lists none) and no public
//  domain type (the wire `CalendarInfo` DTO was deliberately deferred, arikit-models.md §7.7) —
//  its config/selection rows are managed here via plain parameters.
//
import Foundation
import GRDB

public struct CalendarEventRepository: Sendable {
    let dbWriter: any DatabaseWriter

    public func all(includingDeleted: Bool = false) async throws -> [CalendarEvent] {
        try await dbWriter.read { db in
            var request = CalendarEventRecord.order(Column("startTime"))
            if !includingDeleted {
                request = request.filter(Column("isDeleted") == false)
            }
            return try request.fetchAll(db).map { $0.asModel() }
        }
    }

    public func find(_ id: CalendarEventID) async throws -> CalendarEvent? {
        try await dbWriter.read { db in
            try CalendarEventRecord.fetchOne(db, key: id.rawValue)?.asModel()
        }
    }

    /// All non-tombstoned events linked to a meeting.
    public func forMeeting(_ meetingId: MeetingID) async throws -> [CalendarEvent] {
        try await dbWriter.read { db in
            try CalendarEventRecord
                .filter(Column("meetingId") == meetingId.rawValue)
                .filter(Column("isDeleted") == false)
                .order(Column("startTime"))
                .fetchAll(db)
                .map { $0.asModel() }
        }
    }

    /// Insert-or-update, keyed on the stable `CalendarEventID` primary key (the EventKit
    /// `eventIdentifier`).
    public func upsert(_ event: CalendarEvent) async throws {
        try await dbWriter.write { db in
            try CalendarEventRecord(event).save(db)
        }
    }

    /// Tombstone — sets `isDeleted`/`deletedAt`, never issues a hard `DELETE`.
    public func softDelete(_ id: CalendarEventID, at date: Date) async throws {
        try await dbWriter.write { db in
            guard var record = try CalendarEventRecord.fetchOne(db, key: id.rawValue) else {
                return
            }
            record.isDeleted = true
            record.deletedAt = date
            try record.update(db)
        }
    }

    public func observeAll() -> AsyncStream<[CalendarEvent]> {
        let dbWriter = dbWriter
        let observation = ValueObservation.tracking { db in
            try CalendarEventRecord
                .filter(Column("isDeleted") == false)
                .order(Column("startTime"))
                .fetchAll(db)
                .map { $0.asModel() }
        }
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in observation.values(in: dbWriter) {
                        continuation.yield(value)
                    }
                } catch {
                    // See MeetingRepository.observeAll(): a failure ends the stream.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - `calendarSyncSetting` (config/selection — see file header)

    /// All configured calendars and whether they're selected for sync.
    public func syncSettings() async throws
        -> [(calendarId: String, calendarTitle: String?, color: String?, selected: Bool)] {
        try await dbWriter.read { db in
            try CalendarSyncSettingRecord
                .order(Column("calendarId"))
                .fetchAll(db)
                .map { ($0.calendarId, $0.calendarTitle, $0.color, $0.selected) }
        }
    }

    /// Insert-or-update one calendar's sync selection/config.
    public func setSyncSetting(
        calendarId: String,
        calendarTitle: String?,
        color: String?,
        selected: Bool
    ) async throws {
        try await dbWriter.write { db in
            try CalendarSyncSettingRecord(
                calendarId: calendarId,
                calendarTitle: calendarTitle,
                color: color,
                selected: selected
            ).save(db)
        }
    }
}
