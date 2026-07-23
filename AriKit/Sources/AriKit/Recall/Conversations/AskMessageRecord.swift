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
    /// Additive (`v3_ask_message_card`) — a JSON-encoded `RecallCardPayload`, or `nil` for "no
    /// card" (a user turn, or an assistant turn Slice B's entity resolution didn't attach one to).
    /// Mirrors `sourcesJson`'s exact encode/decode/nil-on-absence pattern.
    var cardJson: String?
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
        if let card = message.card {
            let data = try JSONEncoder().encode(card)
            cardJson = String(decoding: data, as: UTF8.self)
        } else {
            cardJson = nil
        }
        createdAt = message.createdAt
    }

    /// Decodes `sourcesJson`/`cardJson` back to their model types, defaulting to `[]`/`nil` for
    /// `nil` or malformed JSON — never crash a read over app-authored history (No-Fake-State;
    /// mirrors Rust's own silent-drop-on-decode-failure via `.ok()`, conversations.rs:58-61). A
    /// malformed `cardJson` decodes as `nil` (no card), NEVER a fabricated empty-object placeholder.
    func asModel() -> AskMessage {
        let sources: [RecallSource] = sourcesJson.flatMap { json in
            try? JSONDecoder().decode([RecallSource].self, from: Data(json.utf8))
        } ?? []
        let card: RecallCardPayload? = cardJson.flatMap { json in
            try? JSONDecoder().decode(RecallCardPayload.self, from: Data(json.utf8))
        }
        return AskMessage(
            id: AskMessageID(id),
            conversationId: AskConversationID(conversationId),
            role: role,
            content: content,
            sources: sources,
            card: card,
            createdAt: createdAt
        )
    }
}
