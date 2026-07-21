//
//  TranscriptRepositoryBatchTests.swift — `TranscriptRepository.upsert([Transcript])`,
//  docs/plans/ari-recording-page.md §2.3/§6: atomicity, ordering, idempotency.
//
import Foundation
import Testing
@testable import AriKit

@Suite("TranscriptRepository batch upsert")
struct TranscriptRepositoryBatchTests {
    private func makeMeeting(id: MeetingID) -> Meeting {
        Meeting(
            id: id, title: "Batch upsert meeting",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test("a mid-batch failure rolls back the WHOLE batch (atomicity)")
    func midBatchFailureRollsBackEverything() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-atomic"
        try await db.meetings.upsert(makeMeeting(id: meetingId))

        let valid = Transcript(
            id: "transcript-valid", meetingId: meetingId, transcript: "Valid segment.",
            timestamp: "00:00:00", audioStartTime: 0
        )
        // References a meeting that does NOT exist — violates the `transcript.meetingId`
        // foreign key (ON DELETE CASCADE, NOT NULL, `SchemaMigrator.swift`), which is enforced
        // because `AppDatabase` turns `PRAGMA foreign_keys = ON`.
        let invalid = Transcript(
            id: "transcript-invalid", meetingId: "meeting-does-not-exist", transcript: "Orphan.",
            timestamp: "00:00:01", audioStartTime: 1
        )

        await #expect(throws: (any Error).self) {
            try await db.transcripts.upsert([valid, invalid])
        }

        // The whole batch rolled back — NEITHER row is present, including the one that would
        // have succeeded on its own.
        let persisted = try await db.transcripts.forMeeting(meetingId)
        #expect(persisted.isEmpty)
        #expect(try await db.transcripts.find(valid.id) == nil)
    }

    @Test("preserves array order")
    func preservesOrder() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-order"
        try await db.meetings.upsert(makeMeeting(id: meetingId))

        let segments = (0 ..< 5).map { index in
            Transcript(
                id: TranscriptID("transcript-\(index)"), meetingId: meetingId,
                transcript: "Segment \(index).", timestamp: "00:00:0\(index)",
                audioStartTime: Double(index)
            )
        }

        try await db.transcripts.upsert(segments)

        let persisted = try await db.transcripts.forMeeting(meetingId)
        #expect(persisted.map(\.id) == segments.map(\.id))
        #expect(persisted.map(\.transcript) == segments.map(\.transcript))
    }

    @Test("re-upserting the same batch is idempotent")
    func idempotentReUpsert() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-idempotent"
        try await db.meetings.upsert(makeMeeting(id: meetingId))

        var segments = (0 ..< 3).map { index in
            Transcript(
                id: TranscriptID("transcript-\(index)"), meetingId: meetingId,
                transcript: "Original \(index).", timestamp: "00:00:0\(index)",
                audioStartTime: Double(index)
            )
        }
        try await db.transcripts.upsert(segments)

        // Re-upsert the SAME ids with changed text — a batch re-upsert is insert-or-UPDATE per
        // row, not a duplicate insert.
        segments = segments.map {
            var updated = $0
            updated.transcript = "Updated \($0.id.rawValue)."
            return updated
        }
        try await db.transcripts.upsert(segments)

        let persisted = try await db.transcripts.forMeeting(meetingId)
        #expect(persisted.count == 3)
        #expect(persisted.map(\.transcript) == segments.map(\.transcript))
    }
}
