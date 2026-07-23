//
//  LabeledTranscriptTests.swift — regression coverage for the summary transcript builder.
//
//  The reference-badge (@ref(MM:SS)) citation feature is load-bearing on the summary transcript
//  carrying real `[MM:SS]` markers: the summary prompt promises them and `SummaryCitations`
//  verifies/back-fills against them. A prior regression fed the summarizer the persons-oriented
//  `buildLabeledTranscriptText` output (`Name: text`, NO markers), silently disabling all
//  citations. These tests pin `buildSummaryTranscriptText` to the `[MM:SS] Name: text` shape and
//  confirm its output round-trips through `SummaryCitations`.
//
import Foundation
import Testing
@testable import AriKit

@Suite("LabeledTranscript — summary transcript markers")
struct LabeledTranscriptTests {
    private func makeMeeting() -> Meeting {
        Meeting(
            id: "meeting-1",
            title: "Weekly sync",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeSpeaker(id: String, label: String) -> Speaker {
        Speaker(
            id: SpeakerID(id),
            label: label,
            centroid: Data(),
            embeddingModel: "test",
            dim: 0,
            samples: 1,
            enrollmentState: .confirmed,
            totalSpeechSecs: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeTranscript(
        id: String,
        meetingId: MeetingID,
        text: String,
        start: Double?,
        timestamp: String,
        speakerId: SpeakerID? = nil
    ) -> Transcript {
        Transcript(
            id: TranscriptID(id),
            meetingId: meetingId,
            transcript: text,
            timestamp: timestamp,
            audioStartTime: start,
            audioEndTime: start.map { $0 + 2 },
            speakerId: speakerId
        )
    }

    @Test("Labeled rows become `[MM:SS] Name: text`; timestamps are computed from audioStartTime")
    func labeledRowsCarryMarkers() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting()
        try await db.meetings.upsert(meeting)
        try await db.speakers.upsert(makeSpeaker(id: "spk-1", label: "Amy"))
        try await db.transcripts.upsert(makeTranscript(
            id: "t1", meetingId: meeting.id, text: "Let's get started.",
            start: 6, timestamp: "00:06", speakerId: SpeakerID("spk-1")
        ))
        try await db.transcripts.upsert(makeTranscript(
            id: "t2", meetingId: meeting.id, text: "I'll own the beta signoff by Friday.",
            start: 65, timestamp: "01:05", speakerId: SpeakerID("spk-1")
        ))

        let text = try await LabeledTranscript.buildSummaryTranscriptText(db: db, meetingId: meeting.id)

        #expect(text == "[00:06] Amy: Let's get started.\n[01:05] Amy: I'll own the beta signoff by Friday.")
    }

    @Test("Rows with no resolved speaker still get `[MM:SS]` markers (bare `[MM:SS] text`)")
    func unlabeledRowsStillCarryMarkers() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting()
        try await db.meetings.upsert(meeting)
        // No speaker rows at all — the meeting has zero resolved speakers.
        try await db.transcripts.upsert(makeTranscript(
            id: "t1", meetingId: meeting.id, text: "Kickoff.", start: 0, timestamp: "00:00"
        ))

        let text = try await LabeledTranscript.buildSummaryTranscriptText(db: db, meetingId: meeting.id)

        // Load-bearing: markers survive even with no speaker, or the citation feature has nothing
        // to cite.
        #expect(text == "[00:00] Kickoff.")
    }

    @Test("Marker falls back to the stored timestamp when audioStartTime is nil (never fabricated)")
    func markerFallsBackToStoredTimestamp() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting()
        try await db.meetings.upsert(meeting)
        try await db.transcripts.upsert(makeTranscript(
            id: "t1", meetingId: meeting.id, text: "No audio offset here.",
            start: nil, timestamp: "02:30"
        ))

        let text = try await LabeledTranscript.buildSummaryTranscriptText(db: db, meetingId: meeting.id)

        #expect(text == "[02:30] No audio offset here.")
    }

    @Test("A meeting with no transcript rows yields an empty string (honest — nothing to summarize)")
    func emptyMeetingYieldsEmptyString() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting()
        try await db.meetings.upsert(meeting)

        let text = try await LabeledTranscript.buildSummaryTranscriptText(db: db, meetingId: meeting.id)

        #expect(text.isEmpty)
    }

    @Test("The builder's output round-trips through SummaryCitations: a real @ref verifies")
    func outputRoundTripsThroughCitations() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting()
        try await db.meetings.upsert(meeting)
        try await db.speakers.upsert(makeSpeaker(id: "spk-1", label: "Marcus"))
        try await db.transcripts.upsert(makeTranscript(
            id: "t1", meetingId: meeting.id, text: "I'll own getting the beta build signed off by Friday.",
            start: 65, timestamp: "01:05", speakerId: SpeakerID("spk-1")
        ))

        let source = try await LabeledTranscript.buildSummaryTranscriptText(db: db, meetingId: meeting.id)
        // A model that copies the real marker verbatim keeps its citation.
        let summary = "- Marcus owns the beta signoff @ref(01:05)"
        let (applied, stats) = SummaryCitations.applyCitations(summary, sourceTranscript: source)

        #expect(applied.contains("@ref(01:05)"))
        #expect(stats.verified == 1)
        #expect(stats.dropped == 0)
    }
}
