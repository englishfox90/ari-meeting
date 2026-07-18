//
//  RecallChunk.swift — public domain values for the recall index (plan §2.2,
//  ← ari-engine/src/database/repositories/recall_index.rs, database/models.rs:87-131).
//
//  Zero DB dependency — these are plain `Sendable` value types; `RecallIndexRepository`
//  translates them to/from the internal GRDB records in this same directory.
//
import Foundation

public typealias RecallChunkID = Identifier<RecallChunk>

/// A persisted, indexed transcript chunk (← Rust `RecallChunk`, database/models.rs:87-100).
/// `createdAt` is kept as raw RFC3339 `String`, NOT `Date` — see `arikit-recall-slice2.md` §4.6's
/// timestamp-format note.
public struct RecallChunk: Codable, Hashable, Sendable, Identifiable {
    public var id: RecallChunkID
    public var meetingId: MeetingID
    public var chunkIndex: Int
    public var chunkText: String
    public var startTime: Double?
    public var endTime: Double?
    public var timestampLabel: String?
    public var embedding: Data?
    public var embeddingModel: String?
    public var dim: Int?
    public var tokenEstimate: Int?
    public var createdAt: String

    public init(
        id: RecallChunkID,
        meetingId: MeetingID,
        chunkIndex: Int,
        chunkText: String,
        startTime: Double? = nil,
        endTime: Double? = nil,
        timestampLabel: String? = nil,
        embedding: Data? = nil,
        embeddingModel: String? = nil,
        dim: Int? = nil,
        tokenEstimate: Int? = nil,
        createdAt: String
    ) {
        self.id = id
        self.meetingId = meetingId
        self.chunkIndex = chunkIndex
        self.chunkText = chunkText
        self.startTime = startTime
        self.endTime = endTime
        self.timestampLabel = timestampLabel
        self.embedding = embedding
        self.embeddingModel = embeddingModel
        self.dim = dim
        self.tokenEstimate = tokenEstimate
        self.createdAt = createdAt
    }
}

/// A chunk staged for insertion (← Rust `RecallChunkInput`, recall_index.rs:6-17). The caller
/// (Slice 5's `Indexer`) mints `id` (a fresh UUID, matching `Uuid::new_v4()`, indexer.rs:109) and
/// supplies the embedding bytes already packed (`Recall.packF32`, Slice 1). `meetingId`,
/// `contentHash`, `embeddingModel` (whole-meeting), and `now` are separate `replaceMeetingChunks`
/// parameters, not part of this type — mirrors the Rust split exactly.
public struct RecallChunkInput: Sendable {
    public var id: RecallChunkID
    public var chunkIndex: Int
    public var chunkText: String
    public var startTime: Double?
    public var endTime: Double?
    public var timestampLabel: String?
    public var embedding: Data?
    public var embeddingModel: String?
    public var dim: Int?
    public var tokenEstimate: Int?

    public init(
        id: RecallChunkID,
        chunkIndex: Int,
        chunkText: String,
        startTime: Double? = nil,
        endTime: Double? = nil,
        timestampLabel: String? = nil,
        embedding: Data? = nil,
        embeddingModel: String? = nil,
        dim: Int? = nil,
        tokenEstimate: Int? = nil
    ) {
        self.id = id
        self.chunkIndex = chunkIndex
        self.chunkText = chunkText
        self.startTime = startTime
        self.endTime = endTime
        self.timestampLabel = timestampLabel
        self.embedding = embedding
        self.embeddingModel = embeddingModel
        self.dim = dim
        self.tokenEstimate = tokenEstimate
    }
}

/// Per-meeting index bookkeeping (← Rust `RecallIndexState`, database/models.rs:124-131).
/// `indexedAt` is raw RFC3339 `String`, same rationale as `RecallChunk.createdAt`.
public struct RecallIndexState: Codable, Hashable, Sendable {
    public var meetingId: MeetingID
    public var contentHash: String
    public var chunkCount: Int
    public var embeddingModel: String?
    public var embeddedCount: Int
    public var indexedAt: String

    public init(
        meetingId: MeetingID,
        contentHash: String,
        chunkCount: Int,
        embeddingModel: String? = nil,
        embeddedCount: Int,
        indexedAt: String
    ) {
        self.meetingId = meetingId
        self.contentHash = contentHash
        self.chunkCount = chunkCount
        self.embeddingModel = embeddingModel
        self.embeddedCount = embeddedCount
        self.indexedAt = indexedAt
    }
}

/// (indexedMeetings, chunkCount, embeddedChunkCount) — ← Rust `index_summary`'s tuple
/// (recall_index.rs:142-155), named for a public API instead of a bare tuple.
public struct RecallIndexSummary: Sendable, Equatable {
    public var indexedMeetings: Int
    public var chunkCount: Int
    public var embeddedChunkCount: Int

    public init(indexedMeetings: Int, chunkCount: Int, embeddedChunkCount: Int) {
        self.indexedMeetings = indexedMeetings
        self.chunkCount = chunkCount
        self.embeddedChunkCount = embeddedChunkCount
    }
}

/// One BM25 lexical hit (← Rust `fts_search`'s `(chunk_id, meeting_id, bm25)` tuple,
/// recall_index.rs:157-173). Ordered best-first — SQLite `bm25()` is ascending (more negative
/// = better match), exactly mirrored: callers must NOT re-sort.
public struct RecallFTSHit: Sendable, Equatable {
    public var chunkId: RecallChunkID
    public var meetingId: MeetingID
    public var score: Double

    public init(chunkId: RecallChunkID, meetingId: MeetingID, score: Double) {
        self.chunkId = chunkId
        self.meetingId = meetingId
        self.score = score
    }
}

/// One embedded chunk's raw vector bytes for brute-force cosine (← Rust `all_embeddings`'s
/// `(chunk_id, meeting_id, embedding_bytes, dim)` tuple, recall_index.rs:175-187). Unpacking to
/// `[Float]` is the caller's job (`Recall.unpackF32`, Slice 1) — kept out of this repository so
/// Slice 2 has zero dependency on the search layer.
public struct RecallEmbeddingRow: Sendable {
    public var chunkId: RecallChunkID
    public var meetingId: MeetingID
    public var embedding: Data
    public var dim: Int

    public init(chunkId: RecallChunkID, meetingId: MeetingID, embedding: Data, dim: Int) {
        self.chunkId = chunkId
        self.meetingId = meetingId
        self.embedding = embedding
        self.dim = dim
    }
}
