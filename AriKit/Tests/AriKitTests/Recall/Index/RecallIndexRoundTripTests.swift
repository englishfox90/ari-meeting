//
//  RecallIndexRoundTripTests.swift — plan §6 `RecallIndexRoundTripTests`.
//
//  Full CRUD/idempotency/FTS5-lockstep suite for `RecallIndexRepository`, built on
//  `AppDatabase.makeInMemory()`, seeding a real `Meeting` via `db.meetings.upsert(_:)` first so
//  the Swift-added FKs are satisfiable.
//
import Foundation
import GRDB
import Testing
@testable import AriKit

@Suite("Recall index round trip — Recall Slice 2")
struct RecallIndexRoundTripTests {
    private func makeMeeting(id: String = "meeting-1") -> Meeting {
        Meeting(
            id: MeetingID(id),
            title: "Recall Slice 2 fixture meeting",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test("replace + read back: embeddings round-trip via Recall.packF32/unpackF32")
    func replaceAndReadBack() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting()
        try await db.meetings.upsert(meeting)

        let vector: [Float] = [0.1, 0.2, 0.3, 0.4]
        let embedded = RecallChunkInput(
            id: RecallChunkID("chunk-1"),
            chunkIndex: 0,
            chunkText: "The quarterly roadmap review starts now.",
            startTime: 0.0,
            endTime: 5.0,
            timestampLabel: "00:00",
            embedding: Recall.packF32(vector),
            embeddingModel: "apple-nl",
            dim: vector.count,
            tokenEstimate: 8
        )
        let lexicalOnly = RecallChunkInput(
            id: RecallChunkID("chunk-2"),
            chunkIndex: 1,
            chunkText: "No embedding yet for this lexical-only chunk.",
            startTime: 5.0,
            endTime: 10.0,
            timestampLabel: "00:05"
        )
        let third = RecallChunkInput(
            id: RecallChunkID("chunk-3"),
            chunkIndex: 2,
            chunkText: "A third chunk about action items and owners.",
            startTime: 10.0,
            endTime: 15.0,
            timestampLabel: "00:10"
        )

        try await db.recallIndex.replaceMeetingChunks(
            meetingId: meeting.id,
            chunks: [embedded, lexicalOnly, third],
            contentHash: "hash-v1",
            embeddingModel: "apple-nl",
            now: "2026-07-18T00:00:00Z"
        )

        let fetched = try await db.recallIndex.chunks(byIds: [
            embedded.id, lexicalOnly.id, third.id
        ])
        #expect(fetched.count == 3)

        let embeddedFetched = try #require(fetched.first { $0.id == embedded.id })
        let unpacked = try Recall.unpackF32(#require(embeddedFetched.embedding))
        #expect(unpacked == vector)
        #expect(embeddedFetched.dim == 4)
        #expect(embeddedFetched.embeddingModel == "apple-nl")
        #expect(embeddedFetched.tokenEstimate == 8)
        #expect(embeddedFetched.chunkText == embedded.chunkText)

        let lexicalFetched = try #require(fetched.first { $0.id == lexicalOnly.id })
        #expect(lexicalFetched.embedding == nil)
        #expect(lexicalFetched.embeddingModel == nil)
    }

    @Test("chunks(byIds:) early-returns empty for empty input")
    func chunksByIdsEmptyInput() async throws {
        let db = try AppDatabase.makeInMemory()
        let fetched = try await db.recallIndex.chunks(byIds: [])
        #expect(fetched.isEmpty)
    }

    @Test("countChunks() reflects the total across meetings")
    func countChunksAcrossMeetings() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingA = makeMeeting(id: "meeting-a")
        let meetingB = makeMeeting(id: "meeting-b")
        try await db.meetings.upsert(meetingA)
        try await db.meetings.upsert(meetingB)

        try await db.recallIndex.replaceMeetingChunks(
            meetingId: meetingA.id,
            chunks: [
                RecallChunkInput(id: RecallChunkID("a-1"), chunkIndex: 0, chunkText: "alpha one"),
                RecallChunkInput(id: RecallChunkID("a-2"), chunkIndex: 1, chunkText: "alpha two")
            ],
            contentHash: "hash-a",
            embeddingModel: nil,
            now: "2026-07-18T00:00:00Z"
        )
        try await db.recallIndex.replaceMeetingChunks(
            meetingId: meetingB.id,
            chunks: [
                RecallChunkInput(id: RecallChunkID("b-1"), chunkIndex: 0, chunkText: "beta one")
            ],
            contentHash: "hash-b",
            embeddingModel: nil,
            now: "2026-07-18T00:00:00Z"
        )

        let count = try await db.recallIndex.countChunks()
        #expect(count == 3)
    }

    @Test("indexState replace is idempotent (full replace, not accumulate)")
    func indexStateReplaceIsIdempotent() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting()
        try await db.meetings.upsert(meeting)

        let firstChunks = [
            RecallChunkInput(id: RecallChunkID("v1-1"), chunkIndex: 0, chunkText: "version one text")
        ]
        try await db.recallIndex.replaceMeetingChunks(
            meetingId: meeting.id,
            chunks: firstChunks,
            contentHash: "hash-v1",
            embeddingModel: nil,
            now: "2026-07-18T00:00:00Z"
        )

        let firstState = try await db.recallIndex.indexState(meetingId: meeting.id)
        #expect(firstState?.contentHash == "hash-v1")
        #expect(firstState?.chunkCount == 1)
        #expect(firstState?.embeddedCount == 0)

        let secondChunks = [
            RecallChunkInput(id: RecallChunkID("v2-1"), chunkIndex: 0, chunkText: "version two text"),
            RecallChunkInput(id: RecallChunkID("v2-2"), chunkIndex: 1, chunkText: "version two more")
        ]
        try await db.recallIndex.replaceMeetingChunks(
            meetingId: meeting.id,
            chunks: secondChunks,
            contentHash: "hash-v2",
            embeddingModel: nil,
            now: "2026-07-18T00:01:00Z"
        )

        let secondState = try await db.recallIndex.indexState(meetingId: meeting.id)
        #expect(secondState?.contentHash == "hash-v2")
        #expect(secondState?.chunkCount == 2)

        // The old chunk id is gone (full replace, not accumulate).
        let oldChunks = try await db.recallIndex.chunks(byIds: [firstChunks[0].id])
        #expect(oldChunks.isEmpty)

        let newChunks = try await db.recallIndex.chunks(byIds: secondChunks.map(\.id))
        #expect(newChunks.count == 2)
    }

    @Test("FTS5 lockstep: search finds current chunks, not chunks replaced away")
    func ftsLockstepAcrossReplace() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting()
        try await db.meetings.upsert(meeting)

        let uniqueChunk = RecallChunkInput(
            id: RecallChunkID("unique-1"),
            chunkIndex: 0,
            chunkText: "The zylophone concerto was flawless."
        )
        let commonChunk = RecallChunkInput(
            id: RecallChunkID("common-1"),
            chunkIndex: 1,
            chunkText: "zylophone appears here too, but only once."
        )

        try await db.recallIndex.replaceMeetingChunks(
            meetingId: meeting.id,
            chunks: [uniqueChunk, commonChunk],
            contentHash: "hash-v1",
            embeddingModel: nil,
            now: "2026-07-18T00:00:00Z"
        )

        let hits = try await db.recallIndex.ftsSearch(matchQuery: "zylophone", limit: 10)
        #expect(hits.count == 2)
        #expect(Set(hits.map(\.chunkId)) == [uniqueChunk.id, commonChunk.id])

        // Replace away — old chunk text must no longer be findable (proves the DELETE FROM
        // recallFts ran in the same transaction as the recallChunk delete).
        let replacement = RecallChunkInput(
            id: RecallChunkID("replacement-1"),
            chunkIndex: 0,
            chunkText: "Completely different content, no matching term."
        )
        try await db.recallIndex.replaceMeetingChunks(
            meetingId: meeting.id,
            chunks: [replacement],
            contentHash: "hash-v2",
            embeddingModel: nil,
            now: "2026-07-18T00:01:00Z"
        )

        let hitsAfterReplace = try await db.recallIndex.ftsSearch(matchQuery: "zylophone", limit: 10)
        #expect(hitsAfterReplace.isEmpty)
    }

    @Test("indexSummary() aggregates across ≥2 meetings")
    func indexSummaryAggregates() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingA = makeMeeting(id: "summary-a")
        let meetingB = makeMeeting(id: "summary-b")
        try await db.meetings.upsert(meetingA)
        try await db.meetings.upsert(meetingB)

        let vector: [Float] = [1.0, 2.0]
        try await db.recallIndex.replaceMeetingChunks(
            meetingId: meetingA.id,
            chunks: [
                RecallChunkInput(
                    id: RecallChunkID("sa-1"), chunkIndex: 0, chunkText: "embedded chunk",
                    embedding: Recall.packF32(vector), embeddingModel: "apple-nl", dim: 2
                ),
                RecallChunkInput(id: RecallChunkID("sa-2"), chunkIndex: 1, chunkText: "lexical chunk")
            ],
            contentHash: "hash-sa",
            embeddingModel: "apple-nl",
            now: "2026-07-18T00:00:00Z"
        )
        try await db.recallIndex.replaceMeetingChunks(
            meetingId: meetingB.id,
            chunks: [
                RecallChunkInput(id: RecallChunkID("sb-1"), chunkIndex: 0, chunkText: "another lexical")
            ],
            contentHash: "hash-sb",
            embeddingModel: nil,
            now: "2026-07-18T00:00:00Z"
        )

        let summary = try await db.recallIndex.indexSummary()
        #expect(summary.indexedMeetings == 2)
        #expect(summary.chunkCount == 3)
        #expect(summary.embeddedChunkCount == 1)
    }

    @Test("allEmbeddings() returns only embedded chunks, excluding lexical-only")
    func allEmbeddingsExcludesLexicalOnly() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting()
        try await db.meetings.upsert(meeting)

        let vector: [Float] = [0.5, -0.5, 0.25]
        try await db.recallIndex.replaceMeetingChunks(
            meetingId: meeting.id,
            chunks: [
                RecallChunkInput(
                    id: RecallChunkID("emb-1"), chunkIndex: 0, chunkText: "embedded",
                    embedding: Recall.packF32(vector), embeddingModel: "apple-nl", dim: 3
                ),
                RecallChunkInput(id: RecallChunkID("lex-1"), chunkIndex: 1, chunkText: "lexical only")
            ],
            contentHash: "hash-emb",
            embeddingModel: "apple-nl",
            now: "2026-07-18T00:00:00Z"
        )

        let embeddings = try await db.recallIndex.allEmbeddings()
        #expect(embeddings.count == 1)
        let row = try #require(embeddings.first)
        #expect(row.chunkId == RecallChunkID("emb-1"))
        #expect(row.dim == 3)
        #expect(Recall.unpackF32(row.embedding) == vector)
    }

    @Test("deleteMeeting removes rows from all three tables")
    func deleteMeetingRemovesEverything() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting()
        try await db.meetings.upsert(meeting)

        try await db.recallIndex.replaceMeetingChunks(
            meetingId: meeting.id,
            chunks: [
                RecallChunkInput(id: RecallChunkID("del-1"), chunkIndex: 0, chunkText: "goodbye chunk")
            ],
            contentHash: "hash-del",
            embeddingModel: nil,
            now: "2026-07-18T00:00:00Z"
        )

        try await db.recallIndex.deleteMeeting(meeting.id)

        let state = try await db.recallIndex.indexState(meetingId: meeting.id)
        #expect(state == nil)

        let hits = try await db.recallIndex.ftsSearch(matchQuery: "goodbye", limit: 10)
        #expect(hits.isEmpty)

        let count = try await db.recallIndex.countChunks()
        #expect(count == 0)
    }

    @Test("FK cascade: hard-deleting the parent meeting cascades recallChunk/recallIndexState")
    func meetingHardDeleteCascades() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting()
        try await db.meetings.upsert(meeting)

        try await db.recallIndex.replaceMeetingChunks(
            meetingId: meeting.id,
            chunks: [
                RecallChunkInput(id: RecallChunkID("cascade-1"), chunkIndex: 0, chunkText: "cascade me")
            ],
            contentHash: "hash-cascade",
            embeddingModel: nil,
            now: "2026-07-18T00:00:00Z"
        )

        // Hard-delete the parent `meeting` row directly (module-internal `dbWriter` access via
        // @testable import), bypassing the repository's tombstone convention entirely.
        try await db.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [meeting.id.rawValue])
        }

        let remainingChunks = try await db.recallIndex.chunks(byIds: [RecallChunkID("cascade-1")])
        #expect(remainingChunks.isEmpty)

        let state = try await db.recallIndex.indexState(meetingId: meeting.id)
        #expect(state == nil)
    }

    @Test("askConversation/askMessage schema is ready for Slice 6: FK cascade + SET NULL")
    func askConversationAndMessageSchemaSmokeTest() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting()
        try await db.meetings.upsert(meeting)

        try await db.dbWriter.write { db in
            try db.execute(
                sql: """
                INSERT INTO askConversation (id, meetingId, title, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    "conv-1", meeting.id.rawValue, "Test conversation",
                    "2026-07-18T00:00:00Z", "2026-07-18T00:00:00Z"
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO askMessage (id, conversationId, role, content, sourcesJson, createdAt)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "msg-1", "conv-1", "user", "What did we decide?", nil, "2026-07-18T00:00:00Z"
                ]
            )
        }

        // Hard-deleting the parent `askConversation` cascades to `askMessage`.
        try await db.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM askConversation WHERE id = ?", arguments: ["conv-1"])
        }
        let remainingMessages = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM askMessage WHERE conversationId = ?", arguments: ["conv-1"])
        }
        #expect(remainingMessages == 0)

        // A fresh conversation referencing the meeting, then hard-deleting the meeting sets
        // meetingId to NULL rather than cascading or failing.
        try await db.dbWriter.write { db in
            try db.execute(
                sql: """
                INSERT INTO askConversation (id, meetingId, title, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    "conv-2", meeting.id.rawValue, "Second conversation",
                    "2026-07-18T00:00:00Z", "2026-07-18T00:00:00Z"
                ]
            )
        }
        try await db.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [meeting.id.rawValue])
        }
        let survivingRow = try await db.dbWriter.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT meetingId FROM askConversation WHERE id = ?",
                arguments: ["conv-2"]
            )
        }
        let survivingConversation = try #require(survivingRow, "askConversation row must survive")
        let survivingMeetingId: String? = survivingConversation["meetingId"]
        #expect(survivingMeetingId == nil)
    }
}
