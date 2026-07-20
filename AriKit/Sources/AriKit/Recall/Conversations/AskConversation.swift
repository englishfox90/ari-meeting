//
//  AskConversation.swift — public domain values for the Ask conversation store (plan §2.3,
//  ← ari-engine/src/recall/conversations.rs `AskConversationDto`/`AskMessageDto`/
//  `AskConversationDetailDto`, database/models.rs `AskConversationRow`/`AskMessageRow`).
//
//  Zero DB dependency — plain `Sendable` value types; `AskConversationStore` translates them
//  to/from the internal GRDB records in this same directory. Timestamps stay raw RFC3339
//  `String` (not `Date`), matching the Recall Slice 2 index tables' convention
//  (`Recall/Index/RecallChunk.swift`) since the `askConversation`/`askMessage` columns are
//  GRDB `.text`, not `.datetime` (`SchemaMigrator.swift`).
//
import Foundation

public typealias AskConversationID = Identifier<AskConversation>
public typealias AskMessageID = Identifier<AskMessage>

/// A conversation's header row (← Rust `AskConversationDto`, conversations.rs:24-30). `meetingId
/// == nil` is a global (cross-meeting) chat; non-nil scopes it to one meeting.
public struct AskConversation: Codable, Hashable, Sendable, Identifiable {
    public var id: AskConversationID
    public var meetingId: MeetingID?
    public var title: String?
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: AskConversationID,
        meetingId: MeetingID? = nil,
        title: String? = nil,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.meetingId = meetingId
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One turn in a conversation (← Rust `AskMessageDto`, conversations.rs:46-54). `sources` is
/// APP-SUPPLIED — built by the orchestrator from the DB, never parsed back from model output
/// (plan §7) — and is `[]`, never `nil`, when there is nothing real to show (No-Fake-State):
/// unlike Rust's `Option<Vec<LocalRecallSource>>` (whose `None` and `Some([])` are
/// distinguishable), this port collapses "no sources" to an honest empty array on both write and
/// read — a documented, deliberate delta from the Rust wire shape.
public struct AskMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: AskMessageID
    public var conversationId: AskConversationID
    public var role: String
    public var content: String
    public var sources: [RecallSource]
    public var createdAt: String

    public init(
        id: AskMessageID,
        conversationId: AskConversationID,
        role: String,
        content: String,
        sources: [RecallSource] = [],
        createdAt: String
    ) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.sources = sources
        self.createdAt = createdAt
    }
}

/// A conversation with its full message history (← Rust `AskConversationDetailDto`,
/// conversations.rs:75-78), ordered oldest-first (matches the Rust `messages` query's
/// `ORDER BY created_at ASC`, `ask_conversation.rs:96`).
public struct AskConversationDetail: Codable, Hashable, Sendable {
    public var conversation: AskConversation
    public var messages: [AskMessage]

    public init(conversation: AskConversation, messages: [AskMessage]) {
        self.conversation = conversation
        self.messages = messages
    }
}
