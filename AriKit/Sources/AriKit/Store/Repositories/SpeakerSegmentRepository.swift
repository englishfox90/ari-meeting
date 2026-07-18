//
//  SpeakerSegmentRepository.swift — the ONLY way feature code touches the `speakerSegment`
//  table (plan §2.2).
//
//  ⚠️ No `softDelete`/`includingDeleted` here: §4.4 does not give `speakerSegment` tombstone
//  columns in this slice (they land for every table in step 7). `delete(_:)` performs a genuine
//  row delete — the only repository in this slice that does, and only because there is no
//  tombstone column yet to prefer instead.
//
import Foundation
import GRDB

public struct SpeakerSegmentRepository: Sendable {
    let dbWriter: any DatabaseWriter

    public func all() async throws -> [SpeakerSegment] {
        try await dbWriter.read { db in
            try SpeakerSegmentRecord
                .order(Column("startTime"))
                .fetchAll(db)
                .map { $0.asModel() }
        }
    }

    public func find(_ id: SpeakerSegmentID) async throws -> SpeakerSegment? {
        try await dbWriter.read { db in
            try SpeakerSegmentRecord.fetchOne(db, key: id.rawValue)?.asModel()
        }
    }

    /// All segments for a meeting, in chronological order.
    public func forMeeting(_ meetingId: MeetingID) async throws -> [SpeakerSegment] {
        try await dbWriter.read { db in
            try SpeakerSegmentRecord
                .filter(Column("meetingId") == meetingId.rawValue)
                .order(Column("startTime"))
                .fetchAll(db)
                .map { $0.asModel() }
        }
    }

    /// Insert-or-update, keyed on the stable `SpeakerSegmentID` primary key.
    public func upsert(_ segment: SpeakerSegment) async throws {
        try await dbWriter.write { db in
            try SpeakerSegmentRecord(segment).save(db)
        }
    }

    /// A genuine hard delete — no tombstone column exists on this table yet (see file header).
    @discardableResult
    public func delete(_ id: SpeakerSegmentID) async throws -> Bool {
        try await dbWriter.write { db in
            try SpeakerSegmentRecord.deleteOne(db, key: id.rawValue)
        }
    }

    public func observeAll() -> AsyncStream<[SpeakerSegment]> {
        let dbWriter = dbWriter
        let observation = ValueObservation.tracking { db in
            try SpeakerSegmentRecord
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
}
