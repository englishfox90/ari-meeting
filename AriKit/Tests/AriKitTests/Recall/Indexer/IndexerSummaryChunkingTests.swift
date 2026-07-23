//
//  IndexerSummaryChunkingTests.swift — docs/plans/ask-meetings-tools-and-cards.md §8, Slice A.
//
//  Bug B regression guard: a fact that only appears in the generated summary — never verbatim in
//  the raw transcript — must become searchable, because `Indexer` now chunks the summary body
//  too (tagged `sourceKind == .summary`) and the content hash covers BOTH texts.
//
import Foundation
import Testing
@testable import AriKit

@Suite("Indexer — summary chunking (ask-meetings-tools-and-cards §3.2)")
struct IndexerSummaryChunkingTests {

    /// Counts invocations (idempotency assertions) and returns deterministic vectors sized by
    /// text length, so distinct texts embed to distinct (but comparable) vectors.
    private actor CountingEmbedder: RecallEmbedder {
        nonisolated let modelTag = "stub-summary-chunking"
        private(set) var callCount = 0

        func embed(_ texts: [String]) async throws -> [[Float]] {
            callCount += 1
            return texts.map { text in [Float(text.count % 97), 1, 2] }
        }
    }

    private func makeMeeting(id: String, createdAt: Date = Date()) -> Meeting {
        Meeting(id: MeetingID(id), title: "Summary-chunking fixture", createdAt: createdAt, updatedAt: createdAt)
    }

    @Test("A fact present only in the summary (never the transcript) becomes searchable")
    func summaryOnlyFactBecomesSearchable() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "summary-only-fact-meeting")
        try await db.meetings.upsert(meeting)

        // The transcript never mentions the name.
        try await db.transcripts.upsert(Transcript(
            id: TranscriptID("summary-only-fact-transcript"),
            meetingId: meeting.id,
            transcript: "We discussed the roadmap, budget, and next steps for the project.",
            timestamp: "00:00"
        ))
        // The summary correctly resolved a name from context — this is the fact that must become
        // searchable.
        try await db.summaries.upsert(Summary(
            id: SummaryID("summary-only-fact-summary"),
            meetingId: meeting.id,
            bodyMarkdown: """
            ## Attendees
            The meeting was led by Zephyrine Okonkwo-Whitfield, who presented the roadmap update.
            """,
            createdAt: Date(),
            updatedAt: Date()
        ))

        let indexer = Indexer(
            recallIndex: db.recallIndex,
            transcripts: db.transcripts,
            meetings: db.meetings,
            summaries: db.summaries,
            embedder: CountingEmbedder(),
            coordinator: ReindexCoordinator()
        )
        await indexer.indexMeeting(meeting.id)

        // The chunk carrying the name must exist and be tagged as a summary chunk.
        let embeddings = try await db.recallIndex.allEmbeddings()
        let chunks = try await db.recallIndex.chunks(byIds: embeddings.map(\.chunkId))
        let summaryChunk = try #require(
            chunks.first { $0.chunkText.contains("Zephyrine Okonkwo-Whitfield") },
            "the summary's fact must be present in an indexed chunk"
        )
        #expect(summaryChunk.sourceKind == .summary)
        #expect(!chunks.contains { $0.sourceKind == .summary && $0.chunkText.contains("roadmap, budget") })

        // And it must actually surface the meeting via hybrid search (lexical arm — the name is a
        // rare enough term that FTS alone should match it).
        let hybridSearch = HybridSearch(
            recallIndex: db.recallIndex,
            meetings: db.meetings,
            summaries: db.summaries,
            transcripts: db.transcripts,
            embedder: CountingEmbedder()
        )
        let results = try await hybridSearch.globalSearch("Zephyrine Okonkwo-Whitfield")
        #expect(results.contains { $0.id == meeting.id.rawValue })
    }

    @Test("The content hash covers both transcript and summary text")
    func contentHashCoversBothTranscriptAndSummary() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "content-hash-both-meeting")
        try await db.meetings.upsert(meeting)
        try await db.transcripts.upsert(Transcript(
            id: TranscriptID("content-hash-both-transcript"),
            meetingId: meeting.id,
            transcript: "An unchanged transcript that stays exactly the same across both runs.",
            timestamp: "00:00"
        ))

        let embedder = CountingEmbedder()
        let indexer = Indexer(
            recallIndex: db.recallIndex,
            transcripts: db.transcripts,
            meetings: db.meetings,
            summaries: db.summaries,
            embedder: embedder,
            coordinator: ReindexCoordinator()
        )

        // First pass: transcript only, no summary yet.
        await indexer.indexMeeting(meeting.id)
        #expect(await embedder.callCount == 1)
        let firstState = try #require(await db.recallIndex.indexState(meetingId: meeting.id))

        // Re-run with the SAME unchanged transcript and STILL no summary — must be a no-op.
        await indexer.indexMeeting(meeting.id)
        #expect(await embedder.callCount == 1, "no new content at all must not trigger a re-index")

        // Now a summary is generated for the first time. The transcript text is unchanged, but the
        // content hash must reflect the newly-available summary text and force a rebuild.
        try await db.summaries.upsert(Summary(
            id: SummaryID("content-hash-both-summary"),
            meetingId: meeting.id,
            bodyMarkdown: "A freshly generated summary body with new content.",
            createdAt: Date(),
            updatedAt: Date()
        ))
        await indexer.indexMeeting(meeting.id)
        #expect(
            await embedder.callCount == 2,
            "an unchanged transcript with a newly-added summary must still trigger a re-index"
        )

        let secondState = try #require(await db.recallIndex.indexState(meetingId: meeting.id))
        #expect(secondState.contentHash != firstState.contentHash)
        #expect(secondState.chunkCount > firstState.chunkCount)
    }
}
