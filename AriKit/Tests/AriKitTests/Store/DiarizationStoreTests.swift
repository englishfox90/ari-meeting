//
//  DiarizationStoreTests.swift — D5 store surface: the diarization-specific `SpeakerRepository`/
//  `SpeakerSegmentRepository`/`TranscriptRepository` additions (docs/plans/arikit-diarization.md
//  §3, §5 D5).
//
import Foundation
import Testing
@testable import AriKit

@Suite("Diarization store surface (D5)")
struct DiarizationStoreTests {
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeMeeting(_ id: MeetingID) -> Meeting {
        Meeting(id: id, title: "Meeting \(id.rawValue)", createdAt: instant, updatedAt: instant)
    }

    private func makePerson(_ id: PersonID) -> Person {
        Person(id: id, displayName: "Person \(id.rawValue)", isOwner: false, createdAt: instant, updatedAt: instant)
    }

    private func makeSpeaker(
        _ id: SpeakerID,
        personId: PersonID? = nil,
        embeddingModel: String = "fluidaudio-community-1",
        enrollmentState: EnrollmentState = .provisional,
        totalSpeechSecs: Double = 30.0
    ) -> Speaker {
        Speaker(
            id: id, personId: personId, centroid: Data([0x01, 0x02, 0x03, 0x04]),
            embeddingModel: embeddingModel, dim: 4, samples: 1, enrollmentState: enrollmentState,
            totalSpeechSecs: totalSpeechSecs, createdAt: instant, updatedAt: instant
        )
    }

    private func makeSegment(
        _ id: SpeakerSegmentID, meetingId: MeetingID, speakerId: SpeakerID?,
        clusterKey: String = "S1", start: Double = 0, end: Double = 5
    ) -> SpeakerSegment {
        SpeakerSegment(
            id: id, meetingId: meetingId, speakerId: speakerId, clusterKey: clusterKey,
            startTime: start, endTime: end, source: .system, createdAt: instant
        )
    }

    private func makeTranscript(
        _ id: TranscriptID, meetingId: MeetingID, speakerId: SpeakerID?
    ) -> Transcript {
        Transcript(
            id: id, meetingId: meetingId, transcript: "Row \(id.rawValue).", timestamp: "00:00:00",
            speakerId: speakerId
        )
    }

    // MARK: - SpeakerRepository.forMeeting

    @Test("forMeeting returns only speakers referenced by that meeting's segments")
    func speakerForMeetingReturnsOnlyReferencedSpeakers() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting1: MeetingID = "meeting-1"
        let meeting2: MeetingID = "meeting-2"
        try await db.meetings.upsert(makeMeeting(meeting1))
        try await db.meetings.upsert(makeMeeting(meeting2))

        let speakerA: SpeakerID = "speaker-a"
        let speakerB: SpeakerID = "speaker-b"
        let speakerC: SpeakerID = "speaker-c" // never referenced by any segment
        try await db.speakers.upsert(makeSpeaker(speakerA))
        try await db.speakers.upsert(makeSpeaker(speakerB))
        try await db.speakers.upsert(makeSpeaker(speakerC))

        try await db.speakerSegments.upsert(makeSegment("seg-1", meetingId: meeting1, speakerId: speakerA))
        try await db.speakerSegments.upsert(makeSegment("seg-2", meetingId: meeting2, speakerId: speakerB))

        let result = try await db.speakers.forMeeting(meeting1)
        #expect(result.map(\.id) == [speakerA])
    }

    // MARK: - SpeakerRepository.matchCandidates

    @Test("matchCandidates filters by enrollment state AND embedding-model space")
    func matchCandidatesFilterByStateAndModel() async throws {
        let db = try AppDatabase.makeInMemory()
        let personId: PersonID = "person-1"
        try await db.persons.upsert(makePerson(personId))

        let confirmedRight: SpeakerID = "speaker-confirmed-right"
        let ownerRight: SpeakerID = "speaker-owner-right"
        let provisionalRight: SpeakerID = "speaker-provisional-right"
        let confirmedWrongSpace: SpeakerID = "speaker-confirmed-wrong-space"
        let confirmedDeleted: SpeakerID = "speaker-confirmed-deleted"

        try await db.speakers.upsert(
            makeSpeaker(confirmedRight, personId: personId, enrollmentState: .confirmed)
        )
        try await db.speakers.upsert(
            makeSpeaker(ownerRight, personId: personId, enrollmentState: .owner)
        )
        try await db.speakers.upsert(
            makeSpeaker(provisionalRight, enrollmentState: .provisional)
        )
        try await db.speakers.upsert(
            makeSpeaker(
                confirmedWrongSpace, personId: personId, embeddingModel: "wespeaker-v2",
                enrollmentState: .confirmed
            )
        )
        try await db.speakers.upsert(
            makeSpeaker(confirmedDeleted, personId: personId, enrollmentState: .confirmed)
        )
        try await db.speakers.softDelete(confirmedDeleted, at: instant)

        let candidates = try await db.speakers.matchCandidates(embeddingModel: "fluidaudio-community-1")
        #expect(Set(candidates.map(\.id)) == [confirmedRight, ownerRight])
    }

    // MARK: - SpeakerRepository.clearMeetingDiarization

    @Test("clearMeetingDiarization unstamps transcripts, deletes segments, tombstones orphan provisionals")
    func clearMeetingDiarizationUnstampsDeletesAndTombstonesProvisionals() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))

        let provisional: SpeakerID = "speaker-provisional"
        try await db.speakers.upsert(makeSpeaker(provisional, enrollmentState: .provisional))
        try await db.speakerSegments.upsert(
            makeSegment("seg-1", meetingId: meetingId, speakerId: provisional)
        )
        let transcriptId: TranscriptID = "transcript-1"
        try await db.transcripts.upsert(
            makeTranscript(transcriptId, meetingId: meetingId, speakerId: provisional)
        )

        let result = try await db.speakers.clearMeetingDiarization(meetingId)
        #expect(result.transcriptsCleared == 1)
        #expect(result.segmentsDeleted == 1)
        #expect(result.provisionalsRemoved == 1)

        let transcript = try await db.transcripts.find(transcriptId)
        #expect(transcript?.speakerId == nil)
        let segments = try await db.speakerSegments.forMeeting(meetingId)
        #expect(segments.isEmpty)

        // Tombstoned, never hard-deleted: absent from the default (non-deleted) listing, but the
        // row itself still exists.
        let visible = try await db.speakers.all()
        #expect(visible.first(where: { $0.id == provisional }) == nil)
        let stillFindable = try await db.speakers.find(provisional)
        #expect(stillFindable != nil)
    }

    @Test("clearMeetingDiarization never touches confirmed or owner voiceprints")
    func clearMeetingDiarizationNeverTouchesConfirmedOrOwner() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))
        let personId: PersonID = "person-1"
        try await db.persons.upsert(makePerson(personId))

        let confirmed: SpeakerID = "speaker-confirmed"
        let owner: SpeakerID = "speaker-owner"
        try await db.speakers.upsert(makeSpeaker(confirmed, personId: personId, enrollmentState: .confirmed))
        try await db.speakers.upsert(makeSpeaker(owner, personId: personId, enrollmentState: .owner))
        try await db.speakerSegments.upsert(makeSegment("seg-1", meetingId: meetingId, speakerId: confirmed))
        try await db.speakerSegments.upsert(makeSegment("seg-2", meetingId: meetingId, speakerId: owner))

        let result = try await db.speakers.clearMeetingDiarization(meetingId)
        #expect(result.segmentsDeleted == 2)
        #expect(result.provisionalsRemoved == 0)

        let confirmedAfter = try await db.speakers.find(confirmed)
        let ownerAfter = try await db.speakers.find(owner)
        #expect(confirmedAfter?.enrollmentState == .confirmed)
        #expect(ownerAfter?.enrollmentState == .owner)
    }

    @Test("clearMeetingDiarization is FATAL: a failed write throws and rolls back (parity-L6)")
    func clearMeetingDiarizationThrowsAndAbortsOnFailure() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))
        let speakerId: SpeakerID = "speaker-1"
        try await db.speakers.upsert(makeSpeaker(speakerId, enrollmentState: .provisional))
        try await db.speakerSegments.upsert(makeSegment("seg-1", meetingId: meetingId, speakerId: speakerId))
        let transcriptId: TranscriptID = "transcript-1"
        try await db.transcripts.upsert(
            makeTranscript(transcriptId, meetingId: meetingId, speakerId: speakerId)
        )

        // Force the second step of the transaction (DELETE FROM speakerSegment) to fail after
        // the first step (UPDATE transcript) has already run inside the SAME transaction.
        try await db.dbWriter.write { rawDb in
            try rawDb.execute(sql: "DROP TABLE speakerSegment")
        }

        await #expect(throws: (any Error).self) {
            try await db.speakers.clearMeetingDiarization(meetingId)
        }

        // Rolled back: the transcript's speakerId is UNCHANGED despite step 1 having executed.
        let transcript = try await db.transcripts.find(transcriptId)
        #expect(transcript?.speakerId == speakerId)
    }

    // MARK: - SpeakerSegmentRepository.insert (batch)

    @Test("batch segment insert is transactional — a mid-batch failure rolls back everything")
    func batchSegmentInsertIsTransactional() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))

        let valid = makeSegment("seg-valid", meetingId: meetingId, speakerId: nil)
        // References a meeting that does NOT exist — violates the `speakerSegment.meetingId`
        // foreign key.
        let invalid = makeSegment("seg-invalid", meetingId: "meeting-does-not-exist", speakerId: nil)

        await #expect(throws: (any Error).self) {
            try await db.speakerSegments.insert([valid, invalid])
        }

        let persisted = try await db.speakerSegments.forMeeting(meetingId)
        #expect(persisted.isEmpty)
        #expect(try await db.speakerSegments.find(valid.id) == nil)
    }

    // MARK: - TranscriptRepository.setSpeakers

    @Test("setSpeakers batch-stamps and clears, scoped to the given meeting")
    func setSpeakersStampsAndClears() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        let otherMeetingId: MeetingID = "meeting-2"
        try await db.meetings.upsert(makeMeeting(meetingId))
        try await db.meetings.upsert(makeMeeting(otherMeetingId))

        let speakerId: SpeakerID = "speaker-1"
        try await db.speakers.upsert(makeSpeaker(speakerId))

        let t1: TranscriptID = "transcript-1"
        let t2: TranscriptID = "transcript-2"
        let otherMeetingTranscript: TranscriptID = "transcript-other-meeting"
        try await db.transcripts.upsert(makeTranscript(t1, meetingId: meetingId, speakerId: nil))
        try await db.transcripts.upsert(makeTranscript(t2, meetingId: meetingId, speakerId: speakerId))
        try await db.transcripts.upsert(
            makeTranscript(otherMeetingTranscript, meetingId: otherMeetingId, speakerId: nil)
        )

        let updated = try await db.transcripts.setSpeakers(
            [(transcriptId: t1, speakerId: speakerId), (transcriptId: t2, speakerId: nil)],
            inMeeting: meetingId
        )
        #expect(updated == 2)

        let row1 = try await db.transcripts.find(t1)
        let row2 = try await db.transcripts.find(t2)
        #expect(row1?.speakerId == speakerId)
        #expect(row2?.speakerId == nil)

        // A stamp attempt scoped to the WRONG meeting never touches that other meeting's row.
        let scopedAway = try await db.transcripts.setSpeakers(
            [(transcriptId: otherMeetingTranscript, speakerId: speakerId)],
            inMeeting: meetingId
        )
        #expect(scopedAway == 0)
        let untouched = try await db.transcripts.find(otherMeetingTranscript)
        #expect(untouched?.speakerId == nil)
    }

    // MARK: - SpeakerRepository.assignToPerson

    @Test("assignToPerson sets personId and enrollmentState = .confirmed")
    func assignToPersonSetsConfirmed() async throws {
        let db = try AppDatabase.makeInMemory()
        let personId: PersonID = "person-1"
        try await db.persons.upsert(makePerson(personId))
        let speakerId: SpeakerID = "speaker-1"
        try await db.speakers.upsert(makeSpeaker(speakerId, enrollmentState: .provisional))

        let stampedAt = Date(timeIntervalSince1970: 1_700_000_500)
        try await db.speakers.assignToPerson(speakerId, personId: personId, at: stampedAt)

        let speaker = try await db.speakers.find(speakerId)
        #expect(speaker?.personId == personId)
        #expect(speaker?.enrollmentState == .confirmed)
        #expect(speaker?.updatedAt == stampedAt)
    }

    // MARK: - SpeakerRepository.repointSpeakerReferences

    @Test("repointSpeakerReferences moves segments + transcript stamps, then tombstones the provisional (B1)")
    func repointSpeakerReferencesMovesSegmentsAndStampsThenTombstonesProvisional() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))
        let personId: PersonID = "person-1"
        try await db.persons.upsert(makePerson(personId))

        let provisional: SpeakerID = "speaker-provisional"
        let canonical: SpeakerID = "speaker-canonical"
        try await db.speakers.upsert(makeSpeaker(provisional, enrollmentState: .provisional))
        try await db.speakers.upsert(
            makeSpeaker(canonical, personId: personId, enrollmentState: .confirmed)
        )

        try await db.speakerSegments.upsert(
            makeSegment("seg-1", meetingId: meetingId, speakerId: provisional, start: 0, end: 5)
        )
        try await db.speakerSegments.upsert(
            makeSegment("seg-2", meetingId: meetingId, speakerId: provisional, start: 10, end: 15)
        )
        let transcriptId: TranscriptID = "transcript-1"
        try await db.transcripts.upsert(
            makeTranscript(transcriptId, meetingId: meetingId, speakerId: provisional)
        )

        let result = try await db.speakers.repointSpeakerReferences(
            from: provisional, to: canonical, inMeeting: meetingId
        )
        #expect(result.segmentsRepointed == 2)
        #expect(result.transcriptsRepointed == 1)

        let segments = try await db.speakerSegments.forMeeting(meetingId)
        #expect(Set(segments.map(\.speakerId)) == [canonical])
        let transcript = try await db.transcripts.find(transcriptId)
        #expect(transcript?.speakerId == canonical)

        // Tombstoned, never hard-deleted: absent from the default listing, row still exists.
        let visible = try await db.speakers.all()
        #expect(visible.first(where: { $0.id == provisional }) == nil)
        let stillFindable = try await db.speakers.find(provisional)
        #expect(stillFindable != nil)

        let canonicalAfter = try await db.speakers.find(canonical)
        #expect(canonicalAfter?.enrollmentState == .confirmed)
    }
}
