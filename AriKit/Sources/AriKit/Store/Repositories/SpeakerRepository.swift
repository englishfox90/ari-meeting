//
//  SpeakerRepository.swift — the ONLY way feature code touches the `speaker` table (plan §2.2).
//
import Foundation
import GRDB

public struct SpeakerRepository: Sendable {
    let dbWriter: any DatabaseWriter

    public func all(includingDeleted: Bool = false) async throws -> [Speaker] {
        try await dbWriter.read { db in
            var request = SpeakerRecord.order(Column("createdAt").desc)
            if !includingDeleted {
                request = request.filter(Column("isDeleted") == false)
            }
            return try request.fetchAll(db).map { $0.asModel() }
        }
    }

    public func find(_ id: SpeakerID) async throws -> Speaker? {
        try await dbWriter.read { db in
            try SpeakerRecord.fetchOne(db, key: id.rawValue)?.asModel()
        }
    }

    /// Insert-or-update, keyed on the stable `SpeakerID` primary key.
    public func upsert(_ speaker: Speaker) async throws {
        try await dbWriter.write { db in
            try SpeakerRecord(speaker).save(db)
        }
    }

    /// Tombstone — sets `isDeleted`/`deletedAt`, never issues a hard `DELETE`.
    public func softDelete(_ id: SpeakerID, at date: Date) async throws {
        try await dbWriter.write { db in
            guard var record = try SpeakerRecord.fetchOne(db, key: id.rawValue) else { return }
            record.isDeleted = true
            record.deletedAt = date
            try record.update(db)
        }
    }

    public func observeAll() -> AsyncStream<[Speaker]> {
        let dbWriter = dbWriter
        let observation = ValueObservation.tracking { db in
            try SpeakerRecord
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
