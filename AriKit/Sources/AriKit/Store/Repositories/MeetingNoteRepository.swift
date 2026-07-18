//
//  MeetingNoteRepository.swift — the ONLY way feature code touches the `meetingNote` table
//  (plan §2.2, §10 step 4).
//
//  Every method is keyed on `MeetingID` directly — `meetingId` is this table's primary key
//  (see `MeetingNoteRecord`'s header), so there is no separate `MeetingNoteID` to look up by.
//
import Foundation
import GRDB

public struct MeetingNoteRepository: Sendable {
    let dbWriter: any DatabaseWriter

    public func all(includingDeleted: Bool = false) async throws -> [MeetingNote] {
        try await dbWriter.read { db in
            var request = MeetingNoteRecord.order(Column("updatedAt").desc)
            if !includingDeleted {
                request = request.filter(Column("isDeleted") == false)
            }
            return try request.fetchAll(db).map { $0.asModel() }
        }
    }

    public func find(_ meetingId: MeetingID) async throws -> MeetingNote? {
        try await dbWriter.read { db in
            try MeetingNoteRecord.fetchOne(db, key: meetingId.rawValue)?.asModel()
        }
    }

    /// Insert-or-update, keyed on the stable `meetingId` primary key.
    public func upsert(_ note: MeetingNote) async throws {
        try await dbWriter.write { db in
            try MeetingNoteRecord(note).save(db)
        }
    }

    /// Tombstone — sets `isDeleted`/`deletedAt`, never issues a hard `DELETE`.
    public func softDelete(_ meetingId: MeetingID, at date: Date) async throws {
        try await dbWriter.write { db in
            guard var record = try MeetingNoteRecord.fetchOne(db, key: meetingId.rawValue) else {
                return
            }
            record.isDeleted = true
            record.deletedAt = date
            try record.update(db)
        }
    }

    public func observeAll() -> AsyncStream<[MeetingNote]> {
        let dbWriter = dbWriter
        let observation = ValueObservation.tracking { db in
            try MeetingNoteRecord
                .filter(Column("isDeleted") == false)
                .order(Column("updatedAt").desc)
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
}
