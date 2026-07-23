//
//  RecallIndexTriggerTests.swift — docs/plans/ask-meetings-tools-and-cards.md §8, Slice A.
//
//  `RecallIndexTrigger` is the single gated place indexing fires from: index-after-summary
//  (Bug A regression guard), the "index once, on summary" decision (a bare transcript save must
//  NOT trigger indexing), and delete-purges-the-index (§3.1.1).
//
import Foundation
import Testing
@testable import AriKit

@Suite("RecallIndexTrigger — Recall (ask-meetings-tools-and-cards §3.1)")
struct RecallIndexTriggerTests {

    /// A trivial, deterministic working embedder — the exact embedding values don't matter to
    /// these tests, only that chunks get produced/counted.
    private struct StubEmbedder: RecallEmbedder {
        let modelTag = "stub-trigger"
        func embed(_ texts: [String]) async throws -> [[Float]] {
            texts.map { text in [Float(text.count), 1, 2] }
        }
    }

    private func makeMeeting(id: String, createdAt: Date = Date()) -> Meeting {
        Meeting(id: MeetingID(id), title: "Trigger fixture meeting", createdAt: createdAt, updatedAt: createdAt)
    }

    private func makeTrigger(_ db: AppDatabase) -> RecallIndexTrigger {
        let indexer = Indexer(
            recallIndex: db.recallIndex,
            transcripts: db.transcripts,
            meetings: db.meetings,
            summaries: db.summaries,
            embedder: StubEmbedder(),
            coordinator: ReindexCoordinator()
        )
        return RecallIndexTrigger(indexer: indexer, recallIndex: db.recallIndex)
    }

    /// Bounded poll for the detached `Task` spawned by `indexAfterSummary`/`purgeOnDelete` to
    /// finish — these are genuinely fire-and-forget, so the test must not assume synchronous
    /// completion.
    private func pollUntil(
        timeout: Duration = .seconds(2),
        _ condition: @Sendable () async throws -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await condition() {
                return true
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try await condition()
    }

    @Test("indexAfterSummary eventually indexes the meeting")
    func indexAfterSummaryEventuallyIndexesTheMeeting() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "trigger-index-meeting")
        try await db.meetings.upsert(meeting)
        try await db.transcripts.upsert(Transcript(
            id: TranscriptID("trigger-index-transcript"),
            meetingId: meeting.id,
            transcript: "We reviewed the roadmap and next steps for the quarter.",
            timestamp: "00:00"
        ))

        let trigger = makeTrigger(db)
        trigger.indexAfterSummary(meeting.id)

        let indexed = try await pollUntil {
            try await db.recallIndex.countChunks() > 0
        }
        #expect(indexed, "indexAfterSummary must eventually produce recallChunk rows")
    }

    @Test("Saving a transcript alone (no summary yet) does not trigger indexing")
    func transcriptSaveAloneDoesNotTriggerIndexing() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "no-summary-yet-meeting")
        try await db.meetings.upsert(meeting)
        try await db.transcripts.upsert(Transcript(
            id: TranscriptID("no-summary-yet-transcript"),
            meetingId: meeting.id,
            transcript: "This transcript exists, but no summary has been generated yet.",
            timestamp: "00:00"
        ))

        // Deliberately: no `trigger.indexAfterSummary` call — `RecallIndexTrigger` exposes no
        // transcript-save hook at all, so there is nothing to accidentally wire up. Give any
        // stray background work a moment to (not) run, then assert zero chunks.
        try await Task.sleep(for: .milliseconds(100))
        let chunkCount = try await db.recallIndex.countChunks()
        #expect(chunkCount == 0, "a transcript save with no summary must never produce recallChunk rows")
    }

    @Test("purgeOnDelete removes previously indexed chunks")
    func purgeOnDeleteRemovesIndexedChunks() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "purge-meeting")
        try await db.meetings.upsert(meeting)
        try await db.transcripts.upsert(Transcript(
            id: TranscriptID("purge-transcript"),
            meetingId: meeting.id,
            transcript: "Content that will be indexed and then purged on delete.",
            timestamp: "00:00"
        ))

        let trigger = makeTrigger(db)
        trigger.indexAfterSummary(meeting.id)
        let indexed = try await pollUntil {
            try await db.recallIndex.countChunks() > 0
        }
        #expect(indexed)

        try await db.meetings.softDelete(meeting.id, at: Date())
        trigger.purgeOnDelete(meeting.id)

        let purged = try await pollUntil {
            try await db.recallIndex.countChunks() == 0
        }
        #expect(purged, "purgeOnDelete must eventually remove the meeting's indexed chunks")
        #expect(try await db.recallIndex.indexState(meetingId: meeting.id) == nil)
    }
}
