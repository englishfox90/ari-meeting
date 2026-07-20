//
//  AskMessageRecord.swift — GRDB record for the `askMessage` table (plan §2.3, Recall Slice 2
//  schema `docs/plans/arikit-recall-slice2.md` §4.5, `SchemaMigrator.swift`).
//
//  Store-internal only — `AskConversationStore` translates to/from the public `AskMessage` value
//  type. `sourcesJson` is a JSON array of APP-SUPPLIED `RecallSource` (never trusted from a
//  model, conversations.rs:58); `nil` on this column means "no sources" (a user turn, or an
//  assistant turn the caller supplied `[]` for) and decodes to an honest `[]`, never fabricated.
//
import Foundation
import GRDB

struct AskMessageRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "askMessage"

    var id: String
    var conversationId: String
    var role: String
    var content: String
    var sourcesJson: String?
    var createdAt: String
}

extension AskMessageRecord {
    init(_ message: AskMessage) throws {
        id = message.id.rawValue
        conversationId = message.conversationId.rawValue
        role = message.role
        content = message.content
        if message.sources.isEmpty {
            sourcesJson = nil
        } else {
            let data = try JSONEncoder().encode(message.sources)
            sourcesJson = String(decoding: data, as: UTF8.self)
        }
        createdAt = message.createdAt
    }

    /// Decodes `sourcesJson` back to `[RecallSource]`, defaulting to `[]` for `nil` or malformed
    /// JSON — never crash a read over app-authored history (No-Fake-State; mirrors Rust's own
    /// silent-drop-on-decode-failure via `.ok()`, conversations.rs:58-61).
    func asModel() -> AskMessage {
        let sources: [RecallSource] = sourcesJson.flatMap { json in
            try? JSONDecoder().decode([RecallSource].self, from: Data(json.utf8))
        } ?? []
        return AskMessage(
            id: AskMessageID(id),
            conversationId: AskConversationID(conversationId),
            role: role,
            content: content,
            sources: sources,
            createdAt: createdAt
        )
    }
}
