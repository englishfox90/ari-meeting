//
//  RecallIndexStateRecord.swift — GRDB record for the `recallIndexState` table
//  (docs/plans/arikit-recall-slice2.md §4.2/§4.7).
//
//  Store-internal only — `RecallIndexRepository` translates to/from the public
//  `RecallIndexState` value type. No tombstone columns — see `RecallChunkRecord`'s header.
//
import Foundation
import GRDB

struct RecallIndexStateRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "recallIndexState"

    var meetingId: String
    var contentHash: String
    var chunkCount: Int
    var embeddingModel: String?
    var embeddedCount: Int
    var indexedAt: String
}

extension RecallIndexStateRecord {
    init(_ state: RecallIndexState) {
        meetingId = state.meetingId.rawValue
        contentHash = state.contentHash
        chunkCount = state.chunkCount
        embeddingModel = state.embeddingModel
        embeddedCount = state.embeddedCount
        indexedAt = state.indexedAt
    }

    func asModel() -> RecallIndexState {
        RecallIndexState(
            meetingId: MeetingID(meetingId),
            contentHash: contentHash,
            chunkCount: chunkCount,
            embeddingModel: embeddingModel,
            embeddedCount: embeddedCount,
            indexedAt: indexedAt
        )
    }
}
