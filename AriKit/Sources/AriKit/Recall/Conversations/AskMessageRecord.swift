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
    /// Mirrors `sourcesJson`'s exact encode/decode/nil-on-absence pattern. Kept as a legacy
    /// back-compat column — `cardsJson` (below) is the primary field going forward.
    var cardJson: String?
    /// Additive (`v4_ask_message_cards`, plan §5.4 `ask-meetings-agentic-tools.md`) — a
    /// JSON-encoded `[RecallCardPayload]`, or `nil` for "no cards". The read path (`asModel()`)
    /// PREFERS this column, falling back to `cardJson` for rows persisted before this column
    /// existed.
    var cardsJson: String?
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
        if message.cards.isEmpty {
            cardsJson = nil
        } else {
            let data = try JSONEncoder().encode(message.cards)
            cardsJson = String(decoding: data, as: UTF8.self)
        }
        createdAt = message.createdAt
    }

    /// Decodes `sourcesJson`/`cardJson`/`cardsJson` back to their model types, defaulting to
    /// `[]`/`nil` for `nil` or malformed JSON — never crash a read over app-authored history
    /// (No-Fake-State; mirrors Rust's own silent-drop-on-decode-failure via `.ok()`,
    /// conversations.rs:58-61). The read path PREFERS `cardsJson`; a row persisted before that
    /// column existed falls back to `cardJson` (a single legacy card). A malformed value decodes
    /// as empty/`nil`, NEVER a fabricated placeholder.
    func asModel() -> AskMessage {
        let sources: [RecallSource] = sourcesJson.flatMap { json in
            try? JSONDecoder().decode([RecallSource].self, from: Data(json.utf8))
        } ?? []
        let decodedCards: [RecallCardPayload]? = cardsJson.flatMap { json in
            try? JSONDecoder().decode([RecallCardPayload].self, from: Data(json.utf8))
        }
        let legacyCard: RecallCardPayload? = cardJson.flatMap { json in
            try? JSONDecoder().decode(RecallCardPayload.self, from: Data(json.utf8))
        }
        let cards = decodedCards ?? (legacyCard.map { [$0] } ?? [])
        return AskMessage(
            id: AskMessageID(id),
            conversationId: AskConversationID(conversationId),
            role: role,
            content: content,
            sources: sources,
            card: legacyCard ?? cards.first,
            cards: cards,
            createdAt: createdAt
        )
    }
}
