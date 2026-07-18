//
//  SummaryRepository.swift — the ONLY way feature code touches the `summary` table (plan §2.2,
//  §10 step 3).
//
import Foundation
import GRDB

public struct SummaryRepository: Sendable {
    let dbWriter: any DatabaseWriter

    public func all(includingDeleted: Bool = false) async throws -> [Summary] {
        try await dbWriter.read { db in
            var request = SummaryRecord.order(Column("createdAt").desc)
            if !includingDeleted {
                request = request.filter(Column("isDeleted") == false)
            }
            return try request.fetchAll(db).map { $0.asModel() }
        }
    }

    public func find(_ id: SummaryID) async throws -> Summary? {
        try await dbWriter.read { db in
            try SummaryRecord.fetchOne(db, key: id.rawValue)?.asModel()
        }
    }

    /// The summary for a meeting, if one exists — `meetingId` is UNIQUE on this table (§4.9).
    public func forMeeting(_ meetingId: MeetingID) async throws -> Summary? {
        try await dbWriter.read { db in
            try SummaryRecord
                .filter(Column("meetingId") == meetingId.rawValue)
                .filter(Column("isDeleted") == false)
                .fetchOne(db)?
                .asModel()
        }
    }

    /// Insert-or-update, keyed on the stable `SummaryID` primary key.
    public func upsert(_ summary: Summary) async throws {
        try await dbWriter.write { db in
            try SummaryRecord(summary).save(db)
        }
    }

    /// Tombstone — sets `isDeleted`/`deletedAt`, never issues a hard `DELETE`.
    public func softDelete(_ id: SummaryID, at date: Date) async throws {
        try await dbWriter.write { db in
            guard var record = try SummaryRecord.fetchOne(db, key: id.rawValue) else { return }
            record.isDeleted = true
            record.deletedAt = date
            try record.update(db)
        }
    }

    public func observeAll() -> AsyncStream<[Summary]> {
        let dbWriter = dbWriter
        let observation = ValueObservation.tracking { db in
            try SummaryRecord
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
                    // See MeetingRepository.observeAll(): a failure ends the stream.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
