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

    /// The most recent `syncedAt` across all rows (tombstoned included — a prune is a sync too),
    /// or `nil` when no sync has ever written. The durable "when did we last sync" signal — it
    /// survives app/view-model recreation, unlike a session-held `CalendarSyncReport`.
    public func latestSyncedAt() async throws -> Date? {
        try await dbWriter.read { db in
            try Date.fetchOne(db, sql: "SELECT MAX(syncedAt) FROM calendarEvent")
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

    // MARK: - Sync-specific writes (S7, plan §2.3 — never clobber `meetingId`/`linkSource`)

    /// One write tx. Per event: INSERT a new row (unlinked), or UPDATE every descriptive +
    /// recurrence column + `syncedAt` on an existing row, clearing `isDeleted`/`deletedAt` (a
    /// re-appearing event un-tombstones) while NEVER touching `meetingId`/`linkSource` — that
    /// invariant is what makes re-sync link-preserving for both manual and auto links
    /// (parity: `calendar.rs:144-199`).
    public func syncUpsert(_ events: [CalendarEvent], at syncDate: Date) async throws {
        try await dbWriter.write { db in
            for event in events {
                if var existing = try CalendarEventRecord.fetchOne(db, key: event.id.rawValue) {
                    existing.calendarId = event.calendarId
                    existing.calendarTitle = event.calendarTitle
                    existing.title = event.title
                    existing.startTime = event.startTime
                    existing.endTime = event.endTime
                    existing.isAllDay = event.isAllDay
                    existing.location = event.location
                    existing.notes = event.notes
                    existing.organizer = event.organizer
                    let data = try Models.jsonEncoder.encode(event.attendees)
                    existing.attendeesJson = String(decoding: data, as: UTF8.self)
                    existing.seriesKey = event.seriesKey
                    existing.hasRecurrence = event.hasRecurrence
                    existing.occurrenceDate = event.occurrenceDate
                    existing.isDetached = event.isDetached
                    existing.syncedAt = syncDate
                    existing.isDeleted = false
                    existing.deletedAt = nil
                    // meetingId / linkSource: deliberately untouched — see file header.
                    try existing.update(db)
                } else {
                    var record = try CalendarEventRecord(event)
                    record.meetingId = nil
                    record.linkSource = nil
                    record.syncedAt = syncDate
                    try record.insert(db)
                }
            }
        }
    }

    /// Tombstone (never a hard `DELETE` — Store delta from `calendar.rs:207-237`) every
    /// non-deleted event whose `startTime` falls in `range` and whose id is not in `keeping`.
    /// An empty `keeping` set prunes the whole range (parity: `calendar.rs:213-222` — the empty
    /// case is deliberate frozen behavior, recoverable here via un-tombstoning on re-sync).
    /// Returns the number of events pruned.
    @discardableResult
    public func pruneStaleEvents(
        startingIn range: ClosedRange<Date>,
        keeping ids: Set<CalendarEventID>,
        at date: Date
    ) async throws -> Int {
        try await dbWriter.write { db in
            let candidates = try CalendarEventRecord
                .filter(Column("startTime") >= range.lowerBound && Column("startTime") <= range.upperBound)
                .filter(Column("isDeleted") == false)
                .fetchAll(db)
            var prunedCount = 0
            for record in candidates {
                guard !ids.contains(CalendarEventID(record.id)) else { continue }
                var mutable = record
                mutable.isDeleted = true
                mutable.deletedAt = date
                try mutable.update(db)
                prunedCount += 1
            }
            return prunedCount
        }
    }

    /// Non-tombstoned events whose `startTime` falls in `range` (parity: `calendar.rs:239-251`).
    public func events(startingIn range: ClosedRange<Date>) async throws -> [CalendarEvent] {
        try await dbWriter.read { db in
            try CalendarEventRecord
                .filter(Column("startTime") >= range.lowerBound && Column("startTime") <= range.upperBound)
                .filter(Column("isDeleted") == false)
                .order(Column("startTime"))
                .fetchAll(db)
                .map { $0.asModel() }
        }
    }

    /// The auto-match candidate set: non-tombstoned events in `range` whose link is not manual
    /// (`linkSource IS NULL OR != 'manual'`, parity: `calendar.rs:254-271`).
    public func autoLinkableEvents(startingIn range: ClosedRange<Date>) async throws -> [CalendarEvent] {
        try await dbWriter.read { db in
            try CalendarEventRecord
                .filter(Column("startTime") >= range.lowerBound && Column("startTime") <= range.upperBound)
                .filter(Column("isDeleted") == false)
                .filter(Column("linkSource") == nil || Column("linkSource") != CalendarLinkSource.manual.rawValue)
                .order(Column("startTime"))
                .fetchAll(db)
                .map { $0.asModel() }
        }
    }

    /// Set an auto-match link. Re-guards against manual at the write site (parity:
    /// `calendar.rs:324-341`) — never overwrites an existing manual link, even if the caller's
    /// candidate set is stale.
    public func setAutoLink(eventId: CalendarEventID, meetingId: MeetingID) async throws {
        try await dbWriter.write { db in
            guard var record = try CalendarEventRecord.fetchOne(db, key: eventId.rawValue) else {
                return
            }
            guard record.linkSource == nil || record.linkSource != CalendarLinkSource.manual.rawValue else {
                return
            }
            record.meetingId = meetingId.rawValue
            record.linkSource = CalendarLinkSource.auto.rawValue
            try record.update(db)
        }
    }

    /// Set a manual link — the one path that is always allowed to override an existing link
    /// (parity: `calendar.rs:343-354`).
    public func setManualLink(eventId: CalendarEventID, meetingId: MeetingID) async throws {
        try await dbWriter.write { db in
            guard var record = try CalendarEventRecord.fetchOne(db, key: eventId.rawValue) else {
                return
            }
            record.meetingId = meetingId.rawValue
            record.linkSource = CalendarLinkSource.manual.rawValue
            try record.update(db)
        }
    }

    /// Clear a link, manual or auto alike (parity: `calendar.rs:356-362`).
    public func unlinkMeeting(eventId: CalendarEventID) async throws {
        try await dbWriter.write { db in
            guard var record = try CalendarEventRecord.fetchOne(db, key: eventId.rawValue) else {
                return
            }
            record.meetingId = nil
            record.linkSource = nil
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

    /// Selected calendar ids only (parity: `calendar.rs:133-138`) — the identifiers the sync
    /// engine is allowed to fetch/upsert this pass.
    public func selectedCalendarIds() async throws -> [String] {
        try await dbWriter.read { db in
            try CalendarSyncSettingRecord
                .filter(Column("selected") == true)
                .fetchAll(db)
                .map(\.calendarId)
        }
    }

    /// One tx: clear every row's `selected`, then set it on exactly `ids` (parity:
    /// `calendar.rs:112-131`).
    public func setSelectedCalendars(_ ids: [String]) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "UPDATE calendarSyncSetting SET selected = 0")
            for id in ids {
                try db.execute(
                    sql: "UPDATE calendarSyncSetting SET selected = 1 WHERE calendarId = ?",
                    arguments: [id]
                )
            }
        }
    }

    /// Identity refresh: insert a newly seen calendar `selected = false`, or update an existing
    /// row's title/color only — never resetting `selected` (parity: `calendar.rs:71-100`). The
    /// existing `setSyncSetting(...)` full-row save would clobber `selected`; identity refresh
    /// must go through this method instead. Returns the row as currently stored.
    @discardableResult
    public func upsertCalendarIdentity(
        calendarId: String,
        title: String?,
        color: String?
    ) async throws -> (calendarId: String, calendarTitle: String?, color: String?, selected: Bool) {
        try await dbWriter.write { db in
            if var existing = try CalendarSyncSettingRecord.fetchOne(db, key: calendarId) {
                existing.calendarTitle = title
                existing.color = color
                try existing.update(db)
                return (existing.calendarId, existing.calendarTitle, existing.color, existing.selected)
            } else {
                let record = CalendarSyncSettingRecord(
                    calendarId: calendarId,
                    calendarTitle: title,
                    color: color,
                    selected: false
                )
                try record.insert(db)
                return (record.calendarId, record.calendarTitle, record.color, record.selected)
            }
        }
    }
}
