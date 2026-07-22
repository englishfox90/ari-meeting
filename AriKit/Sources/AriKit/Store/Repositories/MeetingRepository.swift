//
//  MeetingRepository.swift — the ONLY way feature code touches the `meeting` table (plan §2.2).
//
//  Value in, value out: every method takes/returns `AriKit.Models.Meeting`, never a
//  `MeetingRecord`, a `Row`, or a raw `Database` handle.
//
import Foundation
import GRDB

public struct MeetingRepository: Sendable {
    let dbWriter: any DatabaseWriter

    public func all(includingDeleted: Bool = false) async throws -> [Meeting] {
        try await dbWriter.read { db in
            var request = MeetingRecord.order(Column("createdAt").desc)
            if !includingDeleted {
                request = request.filter(Column("isDeleted") == false)
            }
            return try request.fetchAll(db).map { $0.asModel() }
        }
    }

    public func find(_ id: MeetingID) async throws -> Meeting? {
        try await dbWriter.read { db in
            try MeetingRecord.fetchOne(db, key: id.rawValue)?.asModel()
        }
    }

    /// Insert-or-update, keyed on the stable `MeetingID` primary key.
    public func upsert(_ meeting: Meeting) async throws {
        try await dbWriter.write { db in
            try MeetingRecord(meeting).save(db)
        }
    }

    /// Tombstone — sets `isDeleted`/`deletedAt`, never issues a hard `DELETE`.
    public func softDelete(_ id: MeetingID, at date: Date) async throws {
        try await dbWriter.write { db in
            guard var record = try MeetingRecord.fetchOne(db, key: id.rawValue) else { return }
            record.isDeleted = true
            record.deletedAt = date
            try record.update(db)
        }
    }

    /// The non-tombstoned meeting whose `createdAt` falls in `[start, end]`, closest to `anchor`
    /// — the calendar auto-match query (parity: `calendar.rs:399-423`). `nil` if none found.
    public func closestMeetingID(
        createdBetween start: Date,
        and end: Date,
        to anchor: Date
    ) async throws -> MeetingID? {
        try await dbWriter.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id FROM meeting
                WHERE createdAt >= ? AND createdAt <= ? AND isDeleted = 0
                ORDER BY ABS(julianday(createdAt) - julianday(?)) ASC
                LIMIT 1
                """,
                arguments: [start, end, anchor]
            )
            return row.map { MeetingID($0["id"] as String) }
        }
    }

    /// Live updates for SwiftUI lists, backed by `ValueObservation` (excludes tombstoned rows,
    /// matching `all(includingDeleted: false)`).
    public func observeAll() -> AsyncStream<[Meeting]> {
        let dbWriter = dbWriter
        let observation = ValueObservation.tracking { db in
            try MeetingRecord
                .filter(Column("isDeleted") == false)
                .order(Column("createdAt").desc)
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
                    // ValueObservation failures end the stream rather than crash the observer;
                    // callers see stream completion, not a silently-frozen last value.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
