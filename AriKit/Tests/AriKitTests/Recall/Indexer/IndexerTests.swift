//
//  IndexerTests.swift — plan §6 `IndexerIdempotencyTests` + `ReindexCoordinatorTests` (Recall
//  Slice 5, ← indexer.rs).
//
//  Idempotency, lexical-only degradation + upgrade, content-hash-triggered rebuild, and the
//  `ReindexCoordinator` single-flight guard — all against `AppDatabase.makeInMemory()` and
//  deterministic stub embedders (never the real `NLEmbedding` model in these tests).
//
import Foundation
import Testing
@testable import AriKit

@Suite("Indexer — Recall Slice 5")
struct IndexerTests {

    // MARK: - Fixtures

    /// A working embedder that counts how many times `embed` was actually invoked, so tests can
    /// prove a re-index was (or was not) a no-op without inspecting private state.
    private actor CountingEmbedder: RecallEmbedder {
        nonisolated let modelTag: String
        private let dimension: Int
        private(set) var callCount = 0

        init(modelTag: String = "stub-counting", dimension: Int = 4) {
            self.modelTag = modelTag
            self.dimension = dimension
        }

        func embed(_ texts: [String]) async throws -> [[Float]] {
            callCount += 1
            return texts.map { text in (0 ..< dimension).map { Float($0) + Float(text.count) } }
        }
    }

    /// Always fails — mirrors the local model being unavailable (← `embed_apple.rs` unavailable
    /// path). Used to force lexical-only indexing.
    private struct ThrowingEmbedder: RecallEmbedder {
        let modelTag = "stub-throwing"
        func embed(_: [String]) async throws -> [[Float]] {
            throw RecallEmbedderError.modelUnavailable("stub embedder unavailable")
        }
    }

    /// A deterministic working embedder with a distinct `modelTag`, for the lexical→embedded
    /// upgrade test.
    private struct WorkingEmbedder: RecallEmbedder {
        let modelTag: String
        let dimension: Int
        init(modelTag: String = "stub-working", dimension: Int = 3) {
            self.modelTag = modelTag
            self.dimension = dimension
        }

        func embed(_ texts: [String]) async throws -> [[Float]] {
            texts.map { text in (0 ..< dimension).map { Float($0) + Float(text.count) } }
        }
    }

    /// Introduces an artificial delay before returning, so `reindexAll`'s single-flight guard can
    /// be exercised against a genuine overlapping second call.
    private struct SlowEmbedder: RecallEmbedder {
        let modelTag = "stub-slow"
        let delayNanoseconds: UInt64
        func embed(_ texts: [String]) async throws -> [[Float]] {
            try await Task.sleep(nanoseconds: delayNanoseconds)
            return texts.map { _ in [0.1, 0.2] }
        }
    }

    private func makeMeeting(id: String, createdAt: Date = Date()) -> Meeting {
        Meeting(id: MeetingID(id), title: "Indexer fixture meeting", createdAt: createdAt, updatedAt: createdAt)
    }

    private func seedTranscript(
        _ db: AppDatabase,
        meetingId: MeetingID,
        transcriptId: String,
        text: String
    ) async throws {
        try await db.transcripts.upsert(Transcript(
            id: TranscriptID(transcriptId),
            meetingId: meetingId,
            transcript: text,
            timestamp: "00:00"
        ))
    }

    // MARK: - 1. Idempotency: unchanged text + same model = no-op

    @Test("Re-indexing unchanged text with the same embedder model is a no-op")
    func idempotentReindexIsANoOp() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "idempotent-meeting")
        try await db.meetings.upsert(meeting)
        try await seedTranscript(
            db,
            meetingId: meeting.id,
            transcriptId: "idempotent-transcript",
            text: String(repeating: "We reviewed the quarterly roadmap in detail. ", count: 30)
        )

        let embedder = CountingEmbedder()
        let indexer = Indexer(
            recallIndex: db.recallIndex,
            transcripts: db.transcripts,
            meetings: db.meetings,
            summaries: db.summaries,
            embedder: embedder,
            coordinator: ReindexCoordinator()
        )

        await indexer.indexMeeting(meeting.id)
        let firstCallCount = await embedder.callCount
        #expect(firstCallCount == 1)

        let firstState = try #require(await db.recallIndex.indexState(meetingId: meeting.id))
        let firstChunkIds = try await db.recallIndex.allEmbeddings().map(\.chunkId).sorted { $0.rawValue < $1.rawValue }

        // Re-run with the SAME unchanged transcript text and the SAME embedder instance/model.
        await indexer.indexMeeting(meeting.id)

        let secondCallCount = await embedder.callCount
        #expect(secondCallCount == 1, "embed() must not be invoked again on a no-op re-index")

        let secondState = try #require(await db.recallIndex.indexState(meetingId: meeting.id))
        #expect(secondState.indexedAt == firstState.indexedAt)
        #expect(secondState.contentHash == firstState.contentHash)
        #expect(secondState.chunkCount == firstState.chunkCount)

        let secondChunkIds = try await db.recallIndex.allEmbeddings().map(\.chunkId)
            .sorted { $0.rawValue < $1.rawValue }
        #expect(secondChunkIds == firstChunkIds, "rebuild must not mint new chunk ids on a no-op")
    }

    // MARK: - 2. Lexical-then-embedded upgrade

    @Test("Lexical-only index upgrades to fully embedded once a working embedder is available")
    func lexicalOnlyUpgradesToEmbedded() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "upgrade-meeting")
        try await db.meetings.upsert(meeting)
        try await seedTranscript(
            db,
            meetingId: meeting.id,
            transcriptId: "upgrade-transcript",
            text: String(repeating: "Action items and owners were discussed at length. ", count: 30)
        )

        let lexicalIndexer = Indexer(
            recallIndex: db.recallIndex,
            transcripts: db.transcripts,
            meetings: db.meetings,
            summaries: db.summaries,
            embedder: ThrowingEmbedder(),
            coordinator: ReindexCoordinator()
        )
        await lexicalIndexer.indexMeeting(meeting.id)

        let lexicalState = try #require(await db.recallIndex.indexState(meetingId: meeting.id))
        #expect(lexicalState.chunkCount > 0)
        #expect(lexicalState.embeddedCount == 0)
        #expect(lexicalState.embeddingModel == nil)

        let workingEmbedder = WorkingEmbedder()
        let workingIndexer = Indexer(
            recallIndex: db.recallIndex,
            transcripts: db.transcripts,
            meetings: db.meetings,
            summaries: db.summaries,
            embedder: workingEmbedder,
            coordinator: ReindexCoordinator()
        )
        await workingIndexer.indexMeeting(meeting.id)

        let embeddedState = try #require(await db.recallIndex.indexState(meetingId: meeting.id))
        #expect(embeddedState.chunkCount == lexicalState.chunkCount)
        #expect(embeddedState.embeddedCount == embeddedState.chunkCount)
        #expect(embeddedState.embeddingModel == workingEmbedder.modelTag)

        let embeddings = try await db.recallIndex.allEmbeddings()
        #expect(embeddings.count == embeddedState.chunkCount)
    }

    // MARK: - 3. Content-hash change forces a rebuild

    @Test("Editing the transcript text changes the content hash and forces a rebuild")
    func contentHashChangeForcesRebuild() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "rebuild-meeting")
        try await db.meetings.upsert(meeting)
        try await seedTranscript(
            db,
            meetingId: meeting.id,
            transcriptId: "rebuild-transcript",
            text: String(repeating: "The original quarterly discussion covered budget. ", count: 30)
        )

        let embedder = CountingEmbedder()
        let indexer = Indexer(
            recallIndex: db.recallIndex,
            transcripts: db.transcripts,
            meetings: db.meetings,
            summaries: db.summaries,
            embedder: embedder,
            coordinator: ReindexCoordinator()
        )
        await indexer.indexMeeting(meeting.id)
        let firstState = try #require(await db.recallIndex.indexState(meetingId: meeting.id))
        let firstChunkIds = try await db.recallIndex.allEmbeddings().map(\.chunkId).sorted { $0.rawValue < $1.rawValue }
        #expect(await embedder.callCount == 1)

        // Edit the transcript text — same TranscriptID, different content.
        try await seedTranscript(
            db,
            meetingId: meeting.id,
            transcriptId: "rebuild-transcript",
            text: String(repeating: "A completely revised discussion covered hiring instead. ", count: 30)
        )

        await indexer.indexMeeting(meeting.id)
        #expect(await embedder.callCount == 2, "a content-hash change must trigger a real rebuild")

        let secondState = try #require(await db.recallIndex.indexState(meetingId: meeting.id))
        #expect(secondState.contentHash != firstState.contentHash)

        let secondChunkIds = try await db.recallIndex.allEmbeddings().map(\.chunkId)
            .sorted { $0.rawValue < $1.rawValue }
        #expect(secondChunkIds != firstChunkIds, "rebuild must mint fresh chunk ids, not reuse the stale ones")
    }

    // MARK: - 4. ReindexCoordinator single-flight guard

    @Test("A second reindexAll while a backfill already holds the coordinator's flag returns 0")
    func secondReindexAllReturnsZeroWhileFlagIsHeld() async throws {
        let db = try AppDatabase.makeInMemory()
        let coordinator = ReindexCoordinator()
        // Simulate an in-progress backfill by taking the guard directly.
        #expect(await coordinator.tryBegin())

        let indexer = Indexer(
            recallIndex: db.recallIndex,
            transcripts: db.transcripts,
            meetings: db.meetings,
            summaries: db.summaries,
            embedder: CountingEmbedder(),
            coordinator: coordinator
        )

        let indexed = try await indexer.reindexAll(force: false)
        #expect(indexed == 0, "reindexAll must not run while the coordinator's flag is already held")

        await coordinator.end()
    }

    @Test("Two genuinely concurrent reindexAll calls: exactly one runs, the other returns 0")
    func concurrentReindexAllIsSingleFlight() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "concurrent-meeting")
        try await db.meetings.upsert(meeting)
        try await seedTranscript(
            db,
            meetingId: meeting.id,
            transcriptId: "concurrent-transcript",
            text: "We discussed the roadmap and next steps for the quarter in detail today."
        )

        let coordinator = ReindexCoordinator()
        let indexer = Indexer(
            recallIndex: db.recallIndex,
            transcripts: db.transcripts,
            meetings: db.meetings,
            summaries: db.summaries,
            embedder: SlowEmbedder(delayNanoseconds: 200_000_000),
            coordinator: coordinator
        )

        async let first = indexer.reindexAll(force: false)
        // Give the first call a head start so it wins `tryBegin()` before the second races it.
        try await Task.sleep(nanoseconds: 20_000_000)
        async let second = indexer.reindexAll(force: false)

        let (firstResult, secondResult) = try await (first, second)
        #expect(firstResult == 1)
        #expect(secondResult == 0)
    }

    // MARK: - 5. Ancillary behavior mirrored from indexer.rs

    @Test("A meeting with only whitespace transcript text clears any stale index and indexes nothing")
    func blankTranscriptClearsStaleIndex() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "blank-meeting")
        try await db.meetings.upsert(meeting)
        try await seedTranscript(
            db,
            meetingId: meeting.id,
            transcriptId: "blank-transcript",
            text: "Meaningful content that will later be blanked out."
        )

        let indexer = Indexer(
            recallIndex: db.recallIndex,
            transcripts: db.transcripts,
            meetings: db.meetings,
            summaries: db.summaries,
            embedder: CountingEmbedder(),
            coordinator: ReindexCoordinator()
        )
        await indexer.indexMeeting(meeting.id)
        #expect(try await db.recallIndex.indexState(meetingId: meeting.id) != nil)

        try await seedTranscript(db, meetingId: meeting.id, transcriptId: "blank-transcript", text: "   ")
        await indexer.indexMeeting(meeting.id)

        #expect(try await db.recallIndex.indexState(meetingId: meeting.id) == nil)
        #expect(try await db.recallIndex.countChunks() == 0)
    }

    @Test("indexMeeting never throws even when the repository call fails on a missing meeting")
    func indexMeetingNeverThrowsForAnUnknownMeeting() async throws {
        let db = try AppDatabase.makeInMemory()
        let indexer = Indexer(
            recallIndex: db.recallIndex,
            transcripts: db.transcripts,
            meetings: db.meetings,
            summaries: db.summaries,
            embedder: CountingEmbedder(),
            coordinator: ReindexCoordinator()
        )
        // No meeting/transcript rows exist at all — `forMeeting` simply returns empty, which is
        // the "no transcript text" no-op path, not an error. This proves the call completes
        // without throwing regardless.
        await indexer.indexMeeting(MeetingID("does-not-exist"))
        #expect(try await db.recallIndex.indexState(meetingId: MeetingID("does-not-exist")) == nil)
    }

    @Test("reindexAll(force: true) rebuilds even an unchanged, already-embedded meeting")
    func forceReindexRebuildsUnchangedMeeting() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "force-meeting")
        try await db.meetings.upsert(meeting)
        try await seedTranscript(
            db,
            meetingId: meeting.id,
            transcriptId: "force-transcript",
            text: "Unchanged content that stays exactly the same across both runs."
        )

        let embedder = CountingEmbedder()
        let indexer = Indexer(
            recallIndex: db.recallIndex,
            transcripts: db.transcripts,
            meetings: db.meetings,
            summaries: db.summaries,
            embedder: embedder,
            coordinator: ReindexCoordinator()
        )

        let firstIndexed = try await indexer.reindexAll(force: false)
        #expect(firstIndexed == 1)
        #expect(await embedder.callCount == 1)

        // Without force, the second full backfill must be a no-op (idempotent).
        let secondIndexed = try await indexer.reindexAll(force: false)
        #expect(secondIndexed == 1, "reindexAll still visits every meeting; it is index_meeting that no-ops")
        #expect(await embedder.callCount == 1)

        // With force, the same unchanged meeting is rebuilt (embedder invoked again).
        let thirdIndexed = try await indexer.reindexAll(force: true)
        #expect(thirdIndexed == 1)
        #expect(await embedder.callCount == 2)
    }
}
