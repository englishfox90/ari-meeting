//
//  RoundTripFidelityTests.swift — upsert each foundation-slice domain value through its
//  repository, read it back, assert fidelity (plan §7 test 2, foundation slice).
//
//  Reuses `ModelSamples` (the Models test suite's canonical fixtures) so these tests exercise
//  the same values already proven Codable-round-trip-clean at the Models layer.
//
import Foundation
import Testing
@testable import AriKit

@Suite("Round-trip fidelity — meeting/transcript/speaker/speakerSegment")
struct RoundTripFidelityTests {
    @Test("Meeting round-trips through MeetingRepository")
    func meetingRoundTrip() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = ModelSamples.meeting

        try await db.meetings.upsert(meeting)
        let fetched = try await db.meetings.find(meeting.id)

        #expect(fetched == meeting)
    }

    @Test("Meeting upsert is idempotent (insert then update)")
    func meetingUpsertUpdates() async throws {
        let db = try AppDatabase.makeInMemory()
        var meeting = ModelSamples.meeting
        try await db.meetings.upsert(meeting)

        meeting.title = "Renamed"
        try await db.meetings.upsert(meeting)

        let fetched = try await db.meetings.find(meeting.id)
        #expect(fetched?.title == "Renamed")

        let all = try await db.meetings.all()
        #expect(all.count == 1)
    }

    @Test("Meeting soft-delete tombstones rather than deletes")
    func meetingSoftDelete() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = ModelSamples.meeting
        try await db.meetings.upsert(meeting)

        let deletedAt = Date(timeIntervalSince1970: 1_700_010_000)
        try await db.meetings.softDelete(meeting.id, at: deletedAt)

        let visibleByDefault = try await db.meetings.all()
        #expect(visibleByDefault.isEmpty)

        let includingDeleted = try await db.meetings.all(includingDeleted: true)
        #expect(includingDeleted.count == 1)

        // The row itself must still exist and be readable — a tombstone, never a hard delete.
        let stillFindable = try await db.meetings.find(meeting.id)
        #expect(stillFindable != nil)
    }

    @Test("Transcript round-trips, dropping the pre-chunking-era text fields (plan §4.2)")
    func transcriptRoundTrip() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        try await db.speakers.upsert(ModelSamples.speaker) // transcript.speakerId FK target
        let transcript = ModelSamples.transcript

        try await db.transcripts.upsert(transcript)
        let fetched = try await db.transcripts.find(transcript.id)

        var expected = transcript
        expected.summary = nil
        expected.actionItems = nil
        expected.keyPoints = nil
        #expect(fetched == expected)
    }

    @Test("Transcript.forMeeting scopes by meetingId and excludes tombstoned rows")
    func transcriptForMeeting() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        try await db.speakers.upsert(ModelSamples.speaker) // transcript.speakerId FK target
        let transcript = ModelSamples.transcript
        try await db.transcripts.upsert(transcript)

        let forMeeting = try await db.transcripts.forMeeting(ModelSamples.meeting.id)
        #expect(forMeeting.count == 1)

        try await db.transcripts.softDelete(transcript.id, at: Date())
        let afterDelete = try await db.transcripts.forMeeting(ModelSamples.meeting.id)
        #expect(afterDelete.isEmpty)
    }

    @Test("Speaker round-trips including Data centroid, enum, and Date precision")
    func speakerRoundTrip() async throws {
        let db = try AppDatabase.makeInMemory()
        let speaker = ModelSamples.speaker

        try await db.speakers.upsert(speaker)
        let fetched = try await db.speakers.find(speaker.id)

        #expect(fetched == speaker)
    }

    @Test("Speaker enrollmentState tolerates an unknown raw value")
    func speakerUnknownEnrollmentState() async throws {
        let db = try AppDatabase.makeInMemory()
        var speaker = ModelSamples.speaker
        speaker.id = "speaker-unknown"
        speaker.enrollmentState = .unknown("future_state")

        try await db.speakers.upsert(speaker)
        let fetched = try await db.speakers.find(speaker.id)

        #expect(fetched?.enrollmentState == .unknown("future_state"))
    }

    @Test("SpeakerSegment round-trips including optional embedding blob")
    func speakerSegmentRoundTrip() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        try await db.speakers.upsert(ModelSamples.speaker)
        let segment = ModelSamples.speakerSegment

        try await db.speakerSegments.upsert(segment)
        let fetched = try await db.speakerSegments.find(segment.id)

        #expect(fetched == segment)
    }

    @Test("SpeakerSegment.delete performs a genuine hard delete (no tombstone column yet)")
    func speakerSegmentHardDelete() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        try await db.speakers.upsert(ModelSamples.speaker)
        let segment = ModelSamples.speakerSegment
        try await db.speakerSegments.upsert(segment)

        let deleted = try await db.speakerSegments.delete(segment.id)
        #expect(deleted)

        let fetched = try await db.speakerSegments.find(segment.id)
        #expect(fetched == nil)
    }

    @Test("Deleting a meeting cascades to its transcripts and speakerSegments (FK ON DELETE CASCADE)")
    func meetingCascadeDelete() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        try await db.speakers.upsert(ModelSamples.speaker)
        try await db.transcripts.upsert(ModelSamples.transcript)
        try await db.speakerSegments.upsert(ModelSamples.speakerSegment)

        // A real DELETE on the parent row (not the repository's soft-delete) is the only way to
        // observe the FK cascade — this proves the migrator actually wired `ON DELETE CASCADE`.
        // `dbWriter` is module-internal (not part of the public repository surface); reached
        // here only via `@testable import` to exercise the raw FK behavior directly.
        try await db.dbWriter.write { rawDb in
            try rawDb.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [ModelSamples.meeting.id.rawValue])
        }

        let transcripts = try await db.transcripts.all(includingDeleted: true)
        let segments = try await db.speakerSegments.all()
        #expect(transcripts.isEmpty)
        #expect(segments.isEmpty)
    }

    @Test("Deleting a speaker nulls out speakerId on transcripts/speakerSegments (FK ON DELETE SET NULL)")
    func speakerDeleteSetsNull() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        try await db.speakers.upsert(ModelSamples.speaker)
        try await db.transcripts.upsert(ModelSamples.transcript)
        try await db.speakerSegments.upsert(ModelSamples.speakerSegment)

        try await db.dbWriter.write { rawDb in
            try rawDb.execute(sql: "DELETE FROM speaker WHERE id = ?", arguments: [ModelSamples.speaker.id.rawValue])
        }

        let transcript = try await db.transcripts.find(ModelSamples.transcript.id)
        let segment = try await db.speakerSegments.find(ModelSamples.speakerSegment.id)
        #expect(transcript?.speakerId == nil)
        #expect(segment?.speakerId == nil)
    }
}
