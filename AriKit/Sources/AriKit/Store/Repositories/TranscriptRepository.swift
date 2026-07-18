//
//  TranscriptRepository.swift — the ONLY way feature code touches the `transcript` table
//  (plan §2.2).
//
import Foundation
import GRDB

public struct TranscriptRepository: Sendable {
    let dbWriter: any DatabaseWriter

    public func all(includingDeleted: Bool = false) async throws -> [Transcript] {
        try await dbWriter.read { db in
            var request = TranscriptRecord.order(Column("timestamp"))
            if !includingDeleted {
                request = request.filter(Column("isDeleted") == false)
            }
            return try request.fetchAll(db).map { $0.asModel() }
        }
    }

    public func find(_ id: TranscriptID) async throws -> Transcript? {
        try await dbWriter.read { db in
            try TranscriptRecord.fetchOne(db, key: id.rawValue)?.asModel()
        }
    }

    /// All (non-deleted) transcript segments for a meeting, in recording order.
    public func forMeeting(_ meetingId: MeetingID) async throws -> [Transcript] {
        try await dbWriter.read { db in
            try TranscriptRecord
                .filter(Column("meetingId") == meetingId.rawValue)
                .filter(Column("isDeleted") == false)
                .order(Column("audioStartTime"))
                .fetchAll(db)
                .map { $0.asModel() }
        }
    }

    /// Insert-or-update, keyed on the stable `TranscriptID` primary key.
    public func upsert(_ transcript: Transcript) async throws {
        try await dbWriter.write { db in
            try TranscriptRecord(transcript).save(db)
        }
    }

    /// Tombstone — sets `isDeleted`/`deletedAt`, never issues a hard `DELETE`.
    public func softDelete(_ id: TranscriptID, at date: Date) async throws {
        try await dbWriter.write { db in
            guard var record = try TranscriptRecord.fetchOne(db, key: id.rawValue) else { return }
            record.isDeleted = true
            record.deletedAt = date
            try record.update(db)
        }
    }

    public func observeAll() -> AsyncStream<[Transcript]> {
        let dbWriter = dbWriter
        let observation = ValueObservation.tracking { db in
            try TranscriptRecord
                .filter(Column("isDeleted") == false)
                .order(Column("timestamp"))
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
