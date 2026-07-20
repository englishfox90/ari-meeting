//
//  AskConversationRecord.swift — GRDB record for the `askConversation` table (plan §2.3,
//  Recall Slice 2 schema `docs/plans/arikit-recall-slice2.md` §4.4, `SchemaMigrator.swift`).
//
//  Store-internal only — `AskConversationStore` translates to/from the public `AskConversation`
//  value type. No tombstone columns: the `askConversation` table declares none (matches the Rust
//  migration exactly) — retention is a hard prune, not a soft delete, same derived/local-only
//  rationale the recall index tables use (plan §4).
//
import Foundation
import GRDB

struct AskConversationRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "askConversation"

    var id: String
    var meetingId: String?
    var title: String?
    var createdAt: String
    var updatedAt: String
}

extension AskConversationRecord {
    init(_ conversation: AskConversation) {
        id = conversation.id.rawValue
        meetingId = conversation.meetingId?.rawValue
        title = conversation.title
        createdAt = conversation.createdAt
        updatedAt = conversation.updatedAt
    }

    func asModel() -> AskConversation {
        AskConversation(
            id: AskConversationID(id),
            meetingId: meetingId.map { MeetingID($0) },
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
