//
//  MeetingDetailViewModelTests.swift — resolve meeting/transcript/summary/notes; honest nil
//  summary/notes; transcript order; speaker-name resolution
//  (docs/plans/arikit-native-read-ui.md §7 Lane 1).
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("MeetingDetailViewModel")
@MainActor
struct MeetingDetailViewModelTests {

    @Test("resolves meeting, transcript (ordered), summary, and notes")
    func resolvesFullDetail() async throws {
        let database = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        let meeting = Meeting(
            id: meetingId,
            title: "Weekly sync",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await database.meetings.upsert(meeting)

        let first = Transcript(
            id: "transcript-1", meetingId: meetingId, transcript: "First line.",
            timestamp: "00:00:01", audioStartTime: 1.0
        )
        let second = Transcript(
            id: "transcript-2", meetingId: meetingId, transcript: "Second line.",
            timestamp: "00:00:05", audioStartTime: 5.0
        )
        // Insert out of order — the repository orders by audioStartTime, not insertion order.
        try await database.transcripts.upsert(second)
        try await database.transcripts.upsert(first)

        let summary = Summary(
            id: "summary-1", meetingId: meetingId, bodyMarkdown: "# Recap",
            createdAt: meeting.createdAt, updatedAt: meeting.createdAt
        )
        try await database.summaries.upsert(summary)

        let notes = MeetingNote(
            meetingId: meetingId, notesMarkdown: "Follow up on budget.",
            createdAt: meeting.createdAt, updatedAt: meeting.createdAt
        )
        try await database.meetingNotes.upsert(notes)

        let viewModel = MeetingDetailViewModel(database: database)
        await viewModel.load(meetingId)

        #expect(viewModel.meeting.value?.id == meetingId)
        #expect(viewModel.transcript.map(\.id) == [first.id, second.id])
        #expect(viewModel.summary?.bodyMarkdown == "# Recap")
        #expect(viewModel.notes?.notesMarkdown == "Follow up on budget.")
    }

    @Test("honest nil summary and notes when neither exists")
    func honestNilSummaryAndNotes() async throws {
        let database = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-2"
        let meeting = Meeting(
            id: meetingId, title: "No summary yet",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await database.meetings.upsert(meeting)

        let viewModel = MeetingDetailViewModel(database: database)
        await viewModel.load(meetingId)

        #expect(viewModel.meeting.value?.id == meetingId)
        #expect(viewModel.summary == nil)
        #expect(viewModel.notes == nil)
        #expect(viewModel.transcript.isEmpty)
    }

    @Test("honest failed when the meeting does not exist")
    func honestFailedOnMissingMeeting() async throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = MeetingDetailViewModel(database: database)
        await viewModel.load("does-not-exist")

        guard case .failed = viewModel.meeting else {
            Issue.record("expected .failed, got \(viewModel.meeting)")
            return
        }
    }

    @Test("resolves speaker display names via linked person, falling back to label")
    func resolvesSpeakerNames() async throws {
        let database = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-3"
        let meeting = Meeting(
            id: meetingId, title: "1:1",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await database.meetings.upsert(meeting)

        let person = Person(
            id: "person-1", displayName: "Ada Lovelace", isOwner: false,
            createdAt: meeting.createdAt, updatedAt: meeting.createdAt
        )
        try await database.persons.upsert(person)
        try await database.persons.addParticipant(meetingId: meetingId, personId: person.id)

        let identifiedSpeaker = Speaker(
            id: "speaker-1", personId: person.id, centroid: Data([0x01]),
            embeddingModel: "test", dim: 1, samples: 1, enrollmentState: .confirmed,
            totalSpeechSecs: 10, createdAt: meeting.createdAt, updatedAt: meeting.createdAt
        )
        let labelOnlySpeaker = Speaker(
            id: "speaker-2", personId: nil, label: "Guest", centroid: Data([0x02]),
            embeddingModel: "test", dim: 1, samples: 1, enrollmentState: .provisional,
            totalSpeechSecs: 5, createdAt: meeting.createdAt, updatedAt: meeting.createdAt
        )
        try await database.speakers.upsert(identifiedSpeaker)
        try await database.speakers.upsert(labelOnlySpeaker)

        let line1 = Transcript(
            id: "transcript-1", meetingId: meetingId, transcript: "Hi.",
            timestamp: "00:00:01", audioStartTime: 1.0, speakerId: identifiedSpeaker.id
        )
        let line2 = Transcript(
            id: "transcript-2", meetingId: meetingId, transcript: "Hello.",
            timestamp: "00:00:04", audioStartTime: 4.0, speakerId: labelOnlySpeaker.id
        )
        try await database.transcripts.upsert(line1)
        try await database.transcripts.upsert(line2)

        try await database.speakerSegments.insert([
            SpeakerSegment(
                id: "segment-1", meetingId: meetingId, speakerId: identifiedSpeaker.id,
                clusterKey: "S1", startTime: 0, endTime: 2, source: .system, createdAt: meeting.createdAt
            ),
            SpeakerSegment(
                id: "segment-2", meetingId: meetingId, speakerId: labelOnlySpeaker.id,
                clusterKey: "S2", startTime: 3, endTime: 5, source: .system, createdAt: meeting.createdAt
            )
        ])

        let viewModel = MeetingDetailViewModel(database: database)
        await viewModel.load(meetingId)

        #expect(viewModel.displayName(for: identifiedSpeaker.id) == "Ada Lovelace")
        #expect(viewModel.displayName(for: labelOnlySpeaker.id) == "Guest")
        #expect(viewModel.displayName(for: nil) == nil)
    }

    @Test("rename persists and updates the loaded meeting in place")
    func renameUpdatesLoadedMeeting() async throws {
        let database = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-rename"
        let meeting = Meeting(
            id: meetingId, title: "Old title",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await database.meetings.upsert(meeting)

        let viewModel = MeetingDetailViewModel(database: database)
        await viewModel.load(meetingId)
        try await viewModel.rename(meetingId, to: "New title")

        // Local state patched (no re-load) …
        #expect(viewModel.meeting.value?.title == "New title")
        // … and persisted.
        #expect(try await database.meetings.find(meetingId)?.title == "New title")
    }

    @Test("blank rename is a no-op")
    func blankRenameIsNoOp() async throws {
        let database = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-rename-blank"
        let meeting = Meeting(
            id: meetingId, title: "Keep me",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await database.meetings.upsert(meeting)

        let viewModel = MeetingDetailViewModel(database: database)
        await viewModel.load(meetingId)
        try await viewModel.rename(meetingId, to: "   ")

        #expect(viewModel.meeting.value?.title == "Keep me")
    }

    @Test("delete tombstones the meeting")
    func deleteTombstones() async throws {
        let database = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-delete"
        let meeting = Meeting(
            id: meetingId, title: "Bye",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await database.meetings.upsert(meeting)

        let viewModel = MeetingDetailViewModel(database: database)
        await viewModel.load(meetingId)
        try await viewModel.delete(meetingId)

        // `find` still returns the tombstoned row (it doesn't filter isDeleted); the listing is
        // what drops it.
        #expect(try await database.meetings.all().isEmpty)
    }
}
