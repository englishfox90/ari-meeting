//
//  RecallChunkRecord.swift — GRDB record for the `recallChunk` table
//  (docs/plans/arikit-recall-slice2.md §4.1/§4.7).
//
//  Store-internal only — `RecallIndexRepository` translates to/from the public `RecallChunk`
//  value type. No tombstone columns: recall-index rows are DERIVED/LOCAL-ONLY and hard-deleted
//  (plan §4.8) — not part of the Store's soft-delete convention.
//
import Foundation
import GRDB

struct RecallChunkRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "recallChunk"

    var id: String
    var meetingId: String
    var chunkIndex: Int
    var chunkText: String
    var startTime: Double?
    var endTime: Double?
    var timestampLabel: String?
    var embedding: Data?
    var embeddingModel: String?
    var dim: Int?
    var tokenEstimate: Int?
    var createdAt: String
    /// Raw `RecallChunkSourceKind` string ("transcript"/"summary") — stored as plain `String`
    /// (not the enum directly), matching this codebase's convention for GRDB-persisted enums
    /// (see `ProfileFactRecord`'s `factKind`/`origin`/`status`). An unrecognized raw value
    /// defaults to `.transcript`, matching the column's own `DEFAULT 'transcript'`.
    var sourceKind: String
}

extension RecallChunkRecord {
    init(meetingId: MeetingID, chunk: RecallChunkInput, createdAt: String) {
        id = chunk.id.rawValue
        self.meetingId = meetingId.rawValue
        chunkIndex = chunk.chunkIndex
        chunkText = chunk.chunkText
        startTime = chunk.startTime
        endTime = chunk.endTime
        timestampLabel = chunk.timestampLabel
        embedding = chunk.embedding
        embeddingModel = chunk.embeddingModel
        dim = chunk.dim
        tokenEstimate = chunk.tokenEstimate
        self.createdAt = createdAt
        sourceKind = chunk.sourceKind.rawValue
    }

    func asModel() -> RecallChunk {
        RecallChunk(
            id: RecallChunkID(id),
            meetingId: MeetingID(meetingId),
            chunkIndex: chunkIndex,
            chunkText: chunkText,
            startTime: startTime,
            endTime: endTime,
            timestampLabel: timestampLabel,
            embedding: embedding,
            embeddingModel: embeddingModel,
            dim: dim,
            tokenEstimate: tokenEstimate,
            createdAt: createdAt,
            sourceKind: RecallChunkSourceKind(rawValue: sourceKind) ?? .transcript
        )
    }
}
