//
//  RecallIndexRepository.swift — the ONLY way feature code touches `recallChunk`/
//  `recallIndexState`/`recallFts` (docs/plans/arikit-recall-slice2.md §2.3).
//
//  Direct map of `ari-engine/src/database/repositories/recall_index.rs`, one method per Rust
//  associated function, same argument order. `replaceMeetingChunks`/`deleteMeeting` each run
//  their whole body inside ONE `dbWriter.write { db in }` transaction so `recallChunk` and
//  `recallFts` (its lexical mirror) can never be observed diverged (plan §3's hard requirement).
//
//  No fabricated vectors: `nil` embeddings in, `nil` stored, `nil` back out (No-Fake-State).
//
import Foundation
import GRDB

public struct RecallIndexRepository: Sendable {
    let dbWriter: any DatabaseWriter

    /// ← `replace_meeting_chunks` (recall_index.rs:25-101). One write transaction: DELETE+
    /// re-INSERT `recallChunk`, DELETE+re-INSERT `recallFts` (kept in lockstep), UPSERT
    /// `recallIndexState`. `embeddedCount` is derived from `chunks` (chunks with non-nil
    /// embedding), matching the Rust `filter(|c| c.embedding.is_some()).count()`.
    public func replaceMeetingChunks(
        meetingId: MeetingID,
        chunks: [RecallChunkInput],
        contentHash: String,
        embeddingModel: String?,
        now: String
    ) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "DELETE FROM recallChunk WHERE meetingId = ?",
                arguments: [meetingId.rawValue]
            )
            try db.execute(
                sql: "DELETE FROM recallFts WHERE meetingId = ?",
                arguments: [meetingId.rawValue]
            )

            for batch in Self.batched(chunks, size: 200) {
                for chunk in batch {
                    try RecallChunkRecord(meetingId: meetingId, chunk: chunk, createdAt: now)
                        .insert(db)
                    try db.execute(
                        sql: """
                        INSERT INTO recallFts (chunkText, chunkId, meetingId)
                        VALUES (?, ?, ?)
                        """,
                        arguments: [chunk.chunkText, chunk.id.rawValue, meetingId.rawValue]
                    )
                }
            }

            let embeddedCount = chunks.count { $0.embedding != nil }
            try RecallIndexStateRecord(RecallIndexState(
                meetingId: meetingId,
                contentHash: contentHash,
                chunkCount: chunks.count,
                embeddingModel: embeddingModel,
                embeddedCount: embeddedCount,
                indexedAt: now
            )).save(db)
        }
    }

    /// ← `delete_meeting` (recall_index.rs:104-120). One write transaction: DELETE from all
    /// three tables for this meeting.
    public func deleteMeeting(_ meetingId: MeetingID) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "DELETE FROM recallChunk WHERE meetingId = ?",
                arguments: [meetingId.rawValue]
            )
            try db.execute(
                sql: "DELETE FROM recallFts WHERE meetingId = ?",
                arguments: [meetingId.rawValue]
            )
            try db.execute(
                sql: "DELETE FROM recallIndexState WHERE meetingId = ?",
                arguments: [meetingId.rawValue]
            )
        }
    }

    /// ← `get_index_state` (recall_index.rs:122-133).
    public func indexState(meetingId: MeetingID) async throws -> RecallIndexState? {
        try await dbWriter.read { db in
            try RecallIndexStateRecord.fetchOne(db, key: meetingId.rawValue)?.asModel()
        }
    }

    /// ← `count_chunks` (recall_index.rs:135-139).
    public func countChunks() async throws -> Int {
        try await dbWriter.read { db in
            try RecallChunkRecord.fetchCount(db)
        }
    }

    /// ← `index_summary` (recall_index.rs:142-155).
    public func indexSummary() async throws -> RecallIndexSummary {
        try await dbWriter.read { db in
            let indexedMeetings = try RecallIndexStateRecord.fetchCount(db)
            let chunkCount = try RecallChunkRecord.fetchCount(db)
            let embeddedChunkCount = try RecallChunkRecord
                .filter(Column("embedding") != nil)
                .fetchCount(db)
            return RecallIndexSummary(
                indexedMeetings: indexedMeetings,
                chunkCount: chunkCount,
                embeddedChunkCount: embeddedChunkCount
            )
        }
    }

    /// ← `get_chunks_by_ids` (recall_index.rs:189-210). Empty input → empty output, no query
    /// issued (mirrors the Rust early-return, recall_index.rs:193-195).
    public func chunks(byIds ids: [RecallChunkID]) async throws -> [RecallChunk] {
        guard !ids.isEmpty else { return [] }
        return try await dbWriter.read { db in
            try RecallChunkRecord
                .filter(ids.map(\.rawValue).contains(Column("id")))
                .fetchAll(db)
                .map { $0.asModel() }
        }
    }

    /// ← `all_embeddings` (recall_index.rs:178-187). Only rows with a non-nil `embedding`.
    public func allEmbeddings() async throws -> [RecallEmbeddingRow] {
        try await dbWriter.read { db in
            try RecallChunkRecord
                .filter(Column("embedding") != nil)
                .fetchAll(db)
                .compactMap { record -> RecallEmbeddingRow? in
                    guard let embedding = record.embedding, let dim = record.dim else { return nil }
                    return RecallEmbeddingRow(
                        chunkId: RecallChunkID(record.id),
                        meetingId: MeetingID(record.meetingId),
                        embedding: embedding,
                        dim: dim
                    )
                }
        }
    }

    /// ← `fts_search` (recall_index.rs:159-173). `matchQuery` is a caller-built FTS5 MATCH
    /// expression (Slice 4's `HybridSearch` builds it) — this repository does not construct or
    /// sanitize it; it is passed through verbatim, matching the Rust boundary exactly. Raw SQL
    /// (not the query-interface builder) for exact `bm25()`/`ORDER BY` parity with the Rust
    /// source — see the plan §4.3 decision.
    public func ftsSearch(matchQuery: String, limit: Int) async throws -> [RecallFTSHit] {
        try await dbWriter.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT chunkId, meetingId, bm25(recallFts) AS score
                FROM recallFts WHERE recallFts MATCH ?
                ORDER BY score ASC LIMIT ?
                """,
                arguments: [matchQuery, limit]
            ).map { row in
                RecallFTSHit(
                    chunkId: RecallChunkID(row["chunkId"] as String),
                    meetingId: MeetingID(row["meetingId"] as String),
                    score: row["score"]
                )
            }
        }
    }

    /// Splits `elements` into chunks of at most `size`, a structural nod to the Rust `chunks(200)`
    /// batching (recall_index.rs:46,68). Note: unlike Rust — which uses `QueryBuilder.push_values`
    /// to emit one multi-row `INSERT` per batch (bounding statement/parameter count) — the Swift
    /// path still issues one single-row `INSERT` per element, so slicing here has no write-lock or
    /// round-trip benefit today. Kept for shape-parity with the Rust loop; revisit only if a
    /// multi-row `INSERT` is ever built (§3 downgraded batching to parity, not a requirement).
    private static func batched<Element>(_ elements: [Element], size: Int) -> [[Element]] {
        guard size > 0, !elements.isEmpty else { return elements.isEmpty ? [] : [elements] }
        return stride(from: 0, to: elements.count, by: size).map {
            Array(elements[$0 ..< min($0 + size, elements.count)])
        }
    }
}
