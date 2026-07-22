//
//  DiarizationServiceTests.swift — D8 orchestration (docs/plans/arikit-diarization.md §2.7, §5
//  D8, §7 invariants I1/I3/I4/I5/I10).
//
import Foundation
import Testing
@testable import AriKit

@Suite("DiarizationService orchestration (D8)")
struct DiarizationServiceTests {
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)
    private let embeddingModel = "fluidaudio-community-1"

    private func makeMeeting(_ id: MeetingID) -> Meeting {
        Meeting(id: id, title: "Meeting \(id.rawValue)", createdAt: instant, updatedAt: instant)
    }

    private func makePerson(_ id: PersonID, name: String = "Nia") -> Person {
        Person(id: id, displayName: name, isOwner: false, createdAt: instant, updatedAt: instant)
    }

    private func makeTranscript(
        _ id: TranscriptID, meetingId: MeetingID, start: Double, end: Double
    ) -> Transcript {
        Transcript(
            id: id, meetingId: meetingId, transcript: "Row \(id.rawValue).", timestamp: "00:00:00",
            audioStartTime: start, audioEndTime: end
        )
    }

    /// A unit vector at cosine `score` from `[1, 0]` — `cosineSimilarity([1,0], vector(score))
    /// == score` exactly (both are unit norm).
    private func vector(cosine score: Float) -> [Float] {
        [score, (1 - score * score).squareRoot()]
    }

    private func makeConfirmedSpeaker(
        _ id: SpeakerID, personId: PersonID, centroid: [Float], totalSpeechSecs: Double = 120.0,
        enrollmentState: EnrollmentState = .confirmed
    ) -> Speaker {
        Speaker(
            id: id, personId: personId, centroid: CentroidCodec.data(from: centroid),
            embeddingModel: embeddingModel, dim: centroid.count, samples: 3,
            enrollmentState: enrollmentState, totalSpeechSecs: totalSpeechSecs,
            createdAt: instant, updatedAt: instant
        )
    }

    /// One cluster with `count` segments of `segmentDuration` seconds each, starting at `start`.
    private func makeOutput(
        clusters: [(key: String, centroid: [Float])],
        segmentsPerCluster: Int = 2,
        segmentDuration: Double = 10.0
    ) -> DiarizationOutput {
        var segments: [DiarizedSegment] = []
        var t = 0.0
        var diarClusters: [DiarizationCluster] = []
        for cluster in clusters {
            var speech = 0.0
            for _ in 0 ..< segmentsPerCluster {
                segments.append(DiarizedSegment(clusterKey: cluster.key, startTime: t, endTime: t + segmentDuration))
                t += segmentDuration
                speech += segmentDuration
            }
            diarClusters.append(DiarizationCluster(key: cluster.key, centroid: cluster.centroid, speechSecs: speech))
        }
        return DiarizationOutput(segments: segments, clusters: diarClusters, embeddingModel: embeddingModel, dim: 2)
    }

    private func makeService(
        db: AppDatabase,
        output: DiarizationOutput,
        matchConfig: MatchConfig = .init()
    ) -> DiarizationService {
        DiarizationService(
            database: db,
            provider: StubDiarizationProvider(embeddingModel: embeddingModel, cannedOutput: output),
            audioLoader: StubDiarizationAudioLoader(),
            matchConfig: matchConfig
        )
    }

    // MARK: - I4: hint mandatory

    @Test("automatic hint throws hintRequired — the production path never runs at auto count (I4)")
    func automaticHintThrowsHintRequired() async throws {
        let db = try AppDatabase.makeInMemory()
        let service = makeService(db: db, output: makeOutput(clusters: [("S1", vector(cosine: 1.0))]))

        do {
            _ = try await service.run(meetingId: "meeting-1", audioURL: URL(fileURLWithPath: "/dev/null"), hint: .automatic)
            Issue.record("expected DiarizationError.hintRequired")
        } catch let error as DiarizationError {
            #expect(error == .hintRequired)
        }
    }

    // MARK: - I1: confirm-before-enroll

    @Test("a cluster matching no stored voiceprint becomes a provisional speaker, never assigned to a person (I1)")
    func newVoiceCreatesProvisionalNeverAssignsPerson() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))

        let output = makeOutput(clusters: [("S1", vector(cosine: 1.0))])
        let service = makeService(db: db, output: output)

        let result = try await service.run(meetingId: meetingId, audioURL: URL(fileURLWithPath: "/dev/null"), hint: .exact(1))

        #expect(result.speakers.count == 1)
        #expect(result.speakers[0].tier == .anonymous)
        let speaker = try #require(await db.speakers.find(result.speakers[0].speakerId))
        #expect(speaker.enrollmentState == .provisional)
        #expect(speaker.personId == nil)
    }

    @Test("a suggest-tier match is never applied — a fresh provisional is created, no person link written (I1)")
    func suggestTierNeverWritesPersonLink() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))
        let personId: PersonID = "person-1"
        try await db.persons.upsert(makePerson(personId))

        let storedCentroid = vector(cosine: 1.0)
        let storedId: SpeakerID = "speaker-stored"
        try await db.speakers.upsert(makeConfirmedSpeaker(storedId, personId: personId, centroid: storedCentroid))

        // Score 0.60 clears suggestThreshold (0.55) but not autoThreshold (0.70) — suggest tier.
        let output = makeOutput(clusters: [("S1", vector(cosine: 0.60))])
        let service = makeService(db: db, output: output)

        let result = try await service.run(meetingId: meetingId, audioURL: URL(fileURLWithPath: "/dev/null"), hint: .exact(1))

        #expect(result.speakers.count == 1)
        #expect(result.speakers[0].tier == .suggest)
        #expect(result.speakers[0].speakerId != storedId)
        let newSpeaker = try #require(await db.speakers.find(result.speakers[0].speakerId))
        #expect(newSpeaker.enrollmentState == .provisional)
        #expect(newSpeaker.personId == nil)

        // The pre-existing confirmed voiceprint is untouched (no fold, no participant link).
        let storedAfter = try #require(await db.speakers.find(storedId))
        #expect(storedAfter.totalSpeechSecs == 120.0)
        let participants = try await db.persons.participants(inMeeting: meetingId)
        #expect(participants.isEmpty)
    }

    @Test("a confirmed voiceprint auto-stamps the same speaker across a fresh meeting")
    func confirmedVoiceprintAutoStampsAcrossMeetings() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-2"
        try await db.meetings.upsert(makeMeeting(meetingId))
        let personId: PersonID = "person-1"
        try await db.persons.upsert(makePerson(personId))

        let storedCentroid = vector(cosine: 1.0)
        let storedId: SpeakerID = "speaker-stored"
        try await db.speakers.upsert(makeConfirmedSpeaker(storedId, personId: personId, centroid: storedCentroid))

        let transcriptId: TranscriptID = "transcript-1"
        try await db.transcripts.upsert(makeTranscript(transcriptId, meetingId: meetingId, start: 0, end: 10))

        // Exact same centroid — score 1.0, well past autoThreshold + margin.
        let output = makeOutput(clusters: [("S1", storedCentroid)])
        let service = makeService(db: db, output: output)

        let result = try await service.run(meetingId: meetingId, audioURL: URL(fileURLWithPath: "/dev/null"), hint: .exact(1))

        #expect(result.speakers.count == 1)
        #expect(result.speakers[0].tier == .autoConfirm)
        #expect(result.speakers[0].speakerId == storedId)

        let transcript = try #require(await db.transcripts.find(transcriptId))
        #expect(transcript.speakerId == storedId)

        let participants = try await db.persons.participants(inMeeting: meetingId)
        #expect(participants.map(\.id) == [personId])
    }

    // MARK: - postprocess wiring

    @Test("post-process skips the greedy merge under a .exact hint (forced-K mode)")
    func postProcessSkipsMergeUnderExactHint() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))

        // Two clusters with near-identical centroids (cosine ~0.99) would merge under auto mode
        // (mergeThreshold 0.7) but must NOT merge under .exact — forced-K already pins the count.
        let output = makeOutput(clusters: [
            ("S1", vector(cosine: 1.0)),
            ("S2", vector(cosine: 0.99))
        ])
        let service = makeService(db: db, output: output)

        let result = try await service.run(meetingId: meetingId, audioURL: URL(fileURLWithPath: "/dev/null"), hint: .exact(2))

        #expect(result.speakers.count == 2)
    }

    // MARK: - I5: repositories only (structural — no raw SQLite access from this actor)

    @Test("stamps persist via repositories only — the resulting rows are readable back through them (I5)")
    func stampsPersistViaRepositoriesOnly() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))
        let transcriptId: TranscriptID = "transcript-1"
        try await db.transcripts.upsert(makeTranscript(transcriptId, meetingId: meetingId, start: 0, end: 10))

        let output = makeOutput(clusters: [("S1", vector(cosine: 1.0))], segmentsPerCluster: 1, segmentDuration: 10.0)
        let service = makeService(db: db, output: output)

        let result = try await service.run(meetingId: meetingId, audioURL: URL(fileURLWithPath: "/dev/null"), hint: .exact(1))
        #expect(result.stampedRows == 1)

        let segments = try await db.speakerSegments.forMeeting(meetingId)
        #expect(segments.count == 1)
        #expect(segments[0].source == .system)
        let transcript = try #require(await db.transcripts.find(transcriptId))
        #expect(transcript.speakerId == result.speakers[0].speakerId)
    }

    // MARK: - I2: no-fake-state

    @Test("rows with no overlapping segment are reported as unresolved, never guessed")
    func unresolvedRowsReportedHonestly() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))
        // A transcript row far outside the diarized span.
        let transcriptId: TranscriptID = "transcript-1"
        try await db.transcripts.upsert(makeTranscript(transcriptId, meetingId: meetingId, start: 500, end: 510))

        let output = makeOutput(clusters: [("S1", vector(cosine: 1.0))], segmentsPerCluster: 1, segmentDuration: 10.0)
        let service = makeService(db: db, output: output)

        let result = try await service.run(meetingId: meetingId, audioURL: URL(fileURLWithPath: "/dev/null"), hint: .exact(1))
        #expect(result.stampedRows == 0)
        #expect(result.unresolvedRows == 1)

        let transcript = try #require(await db.transcripts.find(transcriptId))
        #expect(transcript.speakerId == nil)
    }

    // MARK: - I3: idempotent re-run

    @Test("re-running a meeting's diarization is idempotent: identical row counts/links, no orphan provisionals (I3, H1)")
    func rerunIsIdempotent() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))
        let transcriptId: TranscriptID = "transcript-1"
        try await db.transcripts.upsert(makeTranscript(transcriptId, meetingId: meetingId, start: 0, end: 10))

        let output = makeOutput(clusters: [("S1", vector(cosine: 1.0))], segmentsPerCluster: 1, segmentDuration: 10.0)
        let service = makeService(db: db, output: output)

        let first = try await service.run(meetingId: meetingId, audioURL: URL(fileURLWithPath: "/dev/null"), hint: .exact(1))
        let second = try await service.run(meetingId: meetingId, audioURL: URL(fileURLWithPath: "/dev/null"), hint: .exact(1))

        #expect(first.stampedRows == second.stampedRows)
        #expect(first.unresolvedRows == second.unresolvedRows)
        #expect(first.speakers.count == second.speakers.count)

        // No orphan provisionals accumulate: exactly one non-deleted speaker survives, and it's
        // the one the second run actually created/kept (row counts/links only — centroid drift
        // across re-runs is expected by design, not asserted here).
        let allSpeakers = try await db.speakers.all()
        #expect(allSpeakers.count == 1)
        let segments = try await db.speakerSegments.forMeeting(meetingId)
        #expect(segments.count == 1)
    }

    // MARK: - confirmSpeaker (B1)

    @Test("confirmSpeaker with an existing canonical folds the provisional in, repoints references, links the person")
    func confirmSpeakerLinksPersonFoldsAndAddsParticipant() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))
        let personId: PersonID = "person-1"
        try await db.persons.upsert(makePerson(personId))

        let canonicalId: SpeakerID = "speaker-canonical"
        try await db.speakers.upsert(
            makeConfirmedSpeaker(canonicalId, personId: personId, centroid: vector(cosine: 1.0), totalSpeechSecs: 100.0)
        )

        let provisionalId: SpeakerID = "speaker-provisional"
        try await db.speakers.upsert(
            Speaker(
                id: provisionalId, personId: nil, centroid: CentroidCodec.data(from: vector(cosine: 0.9)),
                embeddingModel: embeddingModel, dim: 2, samples: 1, enrollmentState: .provisional,
                totalSpeechSecs: 30.0, createdAt: instant, updatedAt: instant
            )
        )
        let transcriptId: TranscriptID = "transcript-1"
        try await db.transcripts.upsert(
            Transcript(
                id: transcriptId, meetingId: meetingId, transcript: "hi", timestamp: "00:00:00",
                speakerId: provisionalId
            )
        )
        try await db.speakerSegments.upsert(
            SpeakerSegment(
                id: "seg-1", meetingId: meetingId, speakerId: provisionalId, clusterKey: "S1",
                startTime: 0, endTime: 30, source: .system, createdAt: instant
            )
        )

        let service = makeService(db: db, output: makeOutput(clusters: [("S1", vector(cosine: 1.0))]))
        try await service.confirmSpeaker(provisionalId, as: personId, inMeeting: meetingId)

        let canonicalAfter = try #require(await db.speakers.find(canonicalId))
        #expect(canonicalAfter.totalSpeechSecs == 130.0) // duration-weighted fold happened
        #expect(canonicalAfter.samples == 4)

        // Tombstoned, never hard-deleted: absent from the default (non-deleted) listing, but the
        // row itself is still findable by id (mirrors DiarizationStoreTests).
        let allAfter = try await db.speakers.all()
        #expect(allAfter.first(where: { $0.id == provisionalId }) == nil)
        #expect(try await db.speakers.find(provisionalId) != nil)

        let segmentsAfter = try await db.speakerSegments.forMeeting(meetingId)
        #expect(segmentsAfter.map(\.speakerId) == [canonicalId])
        let transcriptAfter = try #require(await db.transcripts.find(transcriptId))
        #expect(transcriptAfter.speakerId == canonicalId)

        let participants = try await db.persons.participants(inMeeting: meetingId)
        #expect(participants.map(\.id) == [personId])
    }

    @Test("confirmSpeaker skips the fold below the speech floor, but still merges/repoints")
    func confirmSpeakerSkipsFoldBelowSpeechFloor() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))
        let personId: PersonID = "person-1"
        try await db.persons.upsert(makePerson(personId))

        let canonicalId: SpeakerID = "speaker-canonical"
        try await db.speakers.upsert(
            makeConfirmedSpeaker(canonicalId, personId: personId, centroid: vector(cosine: 1.0), totalSpeechSecs: 100.0)
        )

        // Below MatchConfig.minFoldSpeechSecs (5.0s) — the fold is skipped, but the merge/repoint
        // must still proceed (← Rust `merge_speaker_into`: "merge fold skipped ... match kept").
        let provisionalId: SpeakerID = "speaker-provisional"
        try await db.speakers.upsert(
            Speaker(
                id: provisionalId, personId: nil, centroid: CentroidCodec.data(from: vector(cosine: 0.9)),
                embeddingModel: embeddingModel, dim: 2, samples: 1, enrollmentState: .provisional,
                totalSpeechSecs: 2.0, createdAt: instant, updatedAt: instant
            )
        )
        try await db.speakerSegments.upsert(
            SpeakerSegment(
                id: "seg-1", meetingId: meetingId, speakerId: provisionalId, clusterKey: "S1",
                startTime: 0, endTime: 2, source: .system, createdAt: instant
            )
        )

        let service = makeService(db: db, output: makeOutput(clusters: [("S1", vector(cosine: 1.0))]))
        try await service.confirmSpeaker(provisionalId, as: personId, inMeeting: meetingId)

        let canonicalAfter = try #require(await db.speakers.find(canonicalId))
        #expect(canonicalAfter.totalSpeechSecs == 100.0) // unchanged — fold was skipped
        #expect(canonicalAfter.samples == 3) // unchanged

        let segmentsAfter = try await db.speakerSegments.forMeeting(meetingId)
        #expect(segmentsAfter.map(\.speakerId) == [canonicalId]) // repoint still happened

        let allAfter = try await db.speakers.all()
        #expect(allAfter.first(where: { $0.id == provisionalId }) == nil)
        #expect(try await db.speakers.find(provisionalId) != nil)
    }

    @Test("confirming the same person from two different meetings never creates a second match-pool candidate (B1, I10)")
    func secondConfirmOfSamePersonDoesNotCreateSecondCandidate() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingA: MeetingID = "meeting-a"
        let meetingB: MeetingID = "meeting-b"
        try await db.meetings.upsert(makeMeeting(meetingA))
        try await db.meetings.upsert(makeMeeting(meetingB))
        let personId: PersonID = "person-1"
        try await db.persons.upsert(makePerson(personId))

        let firstProvisional: SpeakerID = "speaker-first"
        try await db.speakers.upsert(
            Speaker(
                id: firstProvisional, personId: nil, centroid: CentroidCodec.data(from: vector(cosine: 1.0)),
                embeddingModel: embeddingModel, dim: 2, samples: 1, enrollmentState: .provisional,
                totalSpeechSecs: 60.0, createdAt: instant, updatedAt: instant
            )
        )
        let secondProvisional: SpeakerID = "speaker-second"
        try await db.speakers.upsert(
            Speaker(
                id: secondProvisional, personId: nil, centroid: CentroidCodec.data(from: vector(cosine: 0.95)),
                embeddingModel: embeddingModel, dim: 2, samples: 1, enrollmentState: .provisional,
                totalSpeechSecs: 60.0, createdAt: instant, updatedAt: instant
            )
        )

        let service = makeService(db: db, output: makeOutput(clusters: [("S1", vector(cosine: 1.0))]))

        // First confirm: no canonical exists yet — becomes the canonical.
        try await service.confirmSpeaker(firstProvisional, as: personId, inMeeting: meetingA)
        let afterFirst = try await db.speakers.matchCandidates(embeddingModel: embeddingModel)
        #expect(afterFirst.filter { $0.personId == personId }.count == 1)

        // Second confirm from a DIFFERENT meeting: merges into the existing canonical rather
        // than becoming a second candidate row.
        try await service.confirmSpeaker(secondProvisional, as: personId, inMeeting: meetingB)
        let afterSecond = try await db.speakers.matchCandidates(embeddingModel: embeddingModel)
        #expect(afterSecond.filter { $0.personId == personId }.count == 1)
        #expect(afterSecond.first?.id == firstProvisional)
    }

    // MARK: - H1: auto-confirm fold gate

    @Test("auto-confirm folds only when the score clears autoThreshold + margin (H1 — 0.78 case)")
    func autoConfirmFoldsWhenScoreClearsAutoPlusMargin() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))
        let personId: PersonID = "person-1"
        try await db.persons.upsert(makePerson(personId))

        let storedId: SpeakerID = "speaker-stored"
        try await db.speakers.upsert(
            makeConfirmedSpeaker(storedId, personId: personId, centroid: vector(cosine: 1.0), totalSpeechSecs: 100.0)
        )

        // 0.85 comfortably clears autoThreshold (0.70) + margin (0.08) = 0.78 — the fold gate
        // (avoiding an exact-boundary float comparison; the semantics are the H1 0.78 gate).
        let output = makeOutput(clusters: [("S1", vector(cosine: 0.85))])
        let service = makeService(db: db, output: output)

        let result = try await service.run(meetingId: meetingId, audioURL: URL(fileURLWithPath: "/dev/null"), hint: .exact(1))
        #expect(result.speakers[0].tier == .autoConfirm)
        #expect(result.speakers[0].speakerId == storedId)

        let storedAfter = try #require(await db.speakers.find(storedId))
        #expect(storedAfter.totalSpeechSecs > 100.0) // folded
    }

    @Test("a bare auto-confirm (score below the fold gate) is stamped but never folds the voiceprint (H1 — 0.72 case)")
    func bareAutoConfirmDoesNotFold() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))
        let personId: PersonID = "person-1"
        try await db.persons.upsert(makePerson(personId))

        let storedId: SpeakerID = "speaker-stored"
        try await db.speakers.upsert(
            makeConfirmedSpeaker(storedId, personId: personId, centroid: vector(cosine: 1.0), totalSpeechSecs: 100.0)
        )

        // 0.72 clears autoThreshold (0.70) alone, but not autoThreshold + margin (0.78) — the
        // match still stands (auto-confirm, matching.rs:734-742) but the fold is skipped.
        let output = makeOutput(clusters: [("S1", vector(cosine: 0.72))])
        let service = makeService(db: db, output: output)

        let result = try await service.run(meetingId: meetingId, audioURL: URL(fileURLWithPath: "/dev/null"), hint: .exact(1))
        #expect(result.speakers[0].tier == .autoConfirm)
        #expect(result.speakers[0].speakerId == storedId)

        let storedAfter = try #require(await db.speakers.find(storedId))
        #expect(storedAfter.totalSpeechSecs == 100.0) // unchanged — fold skipped
        #expect(storedAfter.samples == 3) // unchanged
    }

    @Test("an auto-confirmed cluster links the matched person as a meeting participant (H1)")
    func autoConfirmLinksParticipant() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))
        let personId: PersonID = "person-1"
        try await db.persons.upsert(makePerson(personId))

        let storedId: SpeakerID = "speaker-stored"
        try await db.speakers.upsert(
            makeConfirmedSpeaker(storedId, personId: personId, centroid: vector(cosine: 1.0), totalSpeechSecs: 100.0)
        )

        let output = makeOutput(clusters: [("S1", vector(cosine: 1.0))])
        let service = makeService(db: db, output: output)

        _ = try await service.run(meetingId: meetingId, audioURL: URL(fileURLWithPath: "/dev/null"), hint: .exact(1))

        let participants = try await db.persons.participants(inMeeting: meetingId)
        #expect(participants.map(\.id) == [personId])
    }
}
