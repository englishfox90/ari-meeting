//
//  DiarizationServiceReconstructionTests.swift —
//  docs/plans/speaker-retag-and-calendar-candidates.md §2 #2, §5, step 2.
//
import Foundation
import Testing
@testable import AriKit

@Suite("DiarizationService.loadPersisted — reconstruction from store (#2)")
struct DiarizationServiceReconstructionTests {
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)
    private let embeddingModel = "fluidaudio-community-1"

    private func makeMeeting(_ id: MeetingID) -> Meeting {
        Meeting(id: id, title: "Meeting \(id.rawValue)", createdAt: instant, updatedAt: instant)
    }

    private func makePerson(_ id: PersonID, name: String = "Nia") -> Person {
        Person(id: id, displayName: name, isOwner: false, createdAt: instant, updatedAt: instant)
    }

    private func makeSpeaker(
        _ id: SpeakerID,
        personId: PersonID? = nil,
        enrollmentState: EnrollmentState = .provisional,
        totalSpeechSecs: Double = 0
    ) -> Speaker {
        Speaker(
            id: id, personId: personId, centroid: Data([0, 1, 2, 3]),
            embeddingModel: embeddingModel, dim: 2, samples: 1,
            enrollmentState: enrollmentState, totalSpeechSecs: totalSpeechSecs,
            createdAt: instant, updatedAt: instant
        )
    }

    private func makeSegment(
        _ id: SpeakerSegmentID, meetingId: MeetingID, speakerId: SpeakerID, start: Double, end: Double
    ) -> SpeakerSegment {
        SpeakerSegment(
            id: id, meetingId: meetingId, speakerId: speakerId, clusterKey: "S",
            startTime: start, endTime: end, source: .system, createdAt: instant
        )
    }

    private func makeTranscript(
        _ id: TranscriptID, meetingId: MeetingID, speakerId: SpeakerID?, start: Double?, end: Double?
    ) -> Transcript {
        Transcript(
            id: id, meetingId: meetingId, transcript: "Row \(id.rawValue).", timestamp: "00:00:00",
            audioStartTime: start, audioEndTime: end, speakerId: speakerId
        )
    }

    private func makeService(db: AppDatabase) -> DiarizationService {
        DiarizationService(
            database: db,
            provider: StubDiarizationProvider(
                embeddingModel: embeddingModel,
                cannedOutput: DiarizationOutput(segments: [], clusters: [], embeddingModel: embeddingModel, dim: 2)
            ),
            audioLoader: StubDiarizationAudioLoader()
        )
    }

    @Test(
        "loadPersisted rebuilds speakers from persisted rows, oldest-first (mirrors SpeakerRepository.forMeeting order)"
    )
    func loadPersistedReconstructsSpeakersFromStore() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))
        let personId: PersonID = "person-1"
        try await db.persons.upsert(makePerson(personId))

        let speakerId: SpeakerID = "speaker-1"
        try await db.speakers.upsert(makeSpeaker(speakerId, personId: personId, enrollmentState: .confirmed))
        try await db.speakerSegments.upsert(makeSegment(
            "seg-1",
            meetingId: meetingId,
            speakerId: speakerId,
            start: 0,
            end: 10
        ))
        let transcriptId: TranscriptID = "transcript-1"
        try await db.transcripts.upsert(makeTranscript(
            transcriptId,
            meetingId: meetingId,
            speakerId: speakerId,
            start: 0,
            end: 10
        ))

        let service = makeService(db: db)
        let result = try await service.loadPersisted(meetingId: meetingId)

        let result2 = try #require(result)
        #expect(result2.speakers.map(\.speakerId) == [speakerId])
        #expect(result2.speakers[0].isAssigned == true)
        #expect(result2.stampedRows == 1)
        #expect(result2.unresolvedRows == 0)
    }

    @Test("reconstructed speechSecs is this meeting's segment-duration sum, not Speaker.totalSpeechSecs")
    func reconstructedSpeechSecsArePerMeetingSums() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingA: MeetingID = "meeting-a"
        let meetingB: MeetingID = "meeting-b"
        try await db.meetings.upsert(makeMeeting(meetingA))
        try await db.meetings.upsert(makeMeeting(meetingB))

        // Cross-meeting accumulated fold weight is deliberately much larger than either
        // meeting's real segment sum — the reconstruction must NOT read this field.
        let speakerId: SpeakerID = "speaker-1"
        try await db.speakers.upsert(makeSpeaker(speakerId, totalSpeechSecs: 999.0))
        try await db.speakerSegments.upsert(makeSegment(
            "seg-a",
            meetingId: meetingA,
            speakerId: speakerId,
            start: 0,
            end: 10
        ))
        try await db.speakerSegments.upsert(makeSegment(
            "seg-b1",
            meetingId: meetingB,
            speakerId: speakerId,
            start: 0,
            end: 5
        ))
        try await db.speakerSegments.upsert(makeSegment(
            "seg-b2",
            meetingId: meetingB,
            speakerId: speakerId,
            start: 5,
            end: 12
        ))

        let service = makeService(db: db)
        let resultA = try #require(try await service.loadPersisted(meetingId: meetingA))
        let resultB = try #require(try await service.loadPersisted(meetingId: meetingB))

        #expect(resultA.speakers[0].speechSecs == 10.0)
        #expect(resultB.speakers[0].speechSecs == 12.0)
    }

    @Test("isAssigned reflects enrollment: confirmed/owner true, provisional false")
    func reconstructedIsAssignedReflectsEnrollment() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))
        let personId: PersonID = "person-1"
        try await db.persons.upsert(makePerson(personId))

        let confirmedId: SpeakerID = "speaker-confirmed"
        try await db.speakers.upsert(makeSpeaker(confirmedId, personId: personId, enrollmentState: .confirmed))
        try await db.speakerSegments.upsert(makeSegment(
            "seg-1",
            meetingId: meetingId,
            speakerId: confirmedId,
            start: 0,
            end: 10
        ))

        let provisionalId: SpeakerID = "speaker-provisional"
        try await db.speakers.upsert(makeSpeaker(provisionalId, personId: nil, enrollmentState: .provisional))
        try await db.speakerSegments.upsert(makeSegment(
            "seg-2",
            meetingId: meetingId,
            speakerId: provisionalId,
            start: 10,
            end: 20
        ))

        let service = makeService(db: db)
        let result = try #require(try await service.loadPersisted(meetingId: meetingId))

        let byId = Dictionary(uniqueKeysWithValues: result.speakers.map { ($0.speakerId, $0.isAssigned) })
        #expect(byId[confirmedId] == true)
        #expect(byId[provisionalId] == false)
    }

    @Test("stampedRows/unresolvedRows equal real counts of timed transcripts with/without speakerId")
    func reconstructedStampCountsAreHonest() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))
        let speakerId: SpeakerID = "speaker-1"
        try await db.speakers.upsert(makeSpeaker(speakerId))
        try await db.speakerSegments.upsert(makeSegment(
            "seg-1",
            meetingId: meetingId,
            speakerId: speakerId,
            start: 0,
            end: 10
        ))

        try await db.transcripts.upsert(makeTranscript(
            "t-stamped",
            meetingId: meetingId,
            speakerId: speakerId,
            start: 0,
            end: 5
        ))
        try await db.transcripts.upsert(makeTranscript(
            "t-unresolved",
            meetingId: meetingId,
            speakerId: nil,
            start: 5,
            end: 10
        ))
        // No audio timing at all — this is neither stamped nor a "timed unresolved" row.
        try await db.transcripts.upsert(makeTranscript(
            "t-untimed",
            meetingId: meetingId,
            speakerId: nil,
            start: nil,
            end: nil
        ))

        let service = makeService(db: db)
        let result = try #require(try await service.loadPersisted(meetingId: meetingId))

        #expect(result.stampedRows == 1)
        #expect(result.unresolvedRows == 1)
    }

    @Test("loadPersisted returns nil when the meeting has never been diarized (no speakerSegment rows)")
    func loadPersistedReturnsNilWhenNeverDiarized() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))

        let service = makeService(db: db)
        let result = try await service.loadPersisted(meetingId: meetingId)

        #expect(result == nil)
    }

    @Test("loadPersisted returns nil when segments exist but every speaker is tombstoned (R2)")
    func loadPersistedReturnsNilWhenSpeakersTombstoned() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))
        let speakerId: SpeakerID = "speaker-1"
        try await db.speakers.upsert(makeSpeaker(speakerId))
        try await db.speakerSegments.upsert(makeSegment(
            "seg-1",
            meetingId: meetingId,
            speakerId: speakerId,
            start: 0,
            end: 10
        ))
        // The segment survives, but the only speaker it references is soft-deleted, so
        // `forMeeting` returns []. loadPersisted must fall back to nil (offer a fresh run),
        // never a "reconstructed" state with an empty speaker list (plan §7 R2 / No-Fake-State).
        try await db.speakers.softDelete(speakerId, at: instant)

        let service = makeService(db: db)
        let result = try await service.loadPersisted(meetingId: meetingId)

        #expect(result == nil)
    }

    @Test("loadPersisted performs no writes (I1/I5)")
    func loadPersistedPerformsNoWrites() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))
        let personId: PersonID = "person-1"
        try await db.persons.upsert(makePerson(personId))
        let speakerId: SpeakerID = "speaker-1"
        try await db.speakers.upsert(makeSpeaker(speakerId, personId: personId, enrollmentState: .confirmed))
        try await db.speakerSegments.upsert(makeSegment(
            "seg-1",
            meetingId: meetingId,
            speakerId: speakerId,
            start: 0,
            end: 10
        ))
        try await db.transcripts.upsert(makeTranscript(
            "t-1",
            meetingId: meetingId,
            speakerId: speakerId,
            start: 0,
            end: 10
        ))

        let speakerCountBefore = try await db.speakers.all(includingDeleted: true).count
        let segmentCountBefore = try await db.speakerSegments.all().count
        let transcriptCountBefore = try await db.transcripts.all(includingDeleted: true).count
        let participantCountBefore = try await db.persons.participants(inMeeting: meetingId).count

        let service = makeService(db: db)
        _ = try await service.loadPersisted(meetingId: meetingId)

        #expect(try await db.speakers.all(includingDeleted: true).count == speakerCountBefore)
        #expect(try await db.speakerSegments.all().count == segmentCountBefore)
        #expect(try await db.transcripts.all(includingDeleted: true).count == transcriptCountBefore)
        #expect(try await db.persons.participants(inMeeting: meetingId).count == participantCountBefore)
    }
}
