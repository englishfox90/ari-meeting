//
//  AskConversationStore.swift — Ask conversation persistence + 7-day retention prune (plan §2.3/
//  §5 Slice 6, ← ari-engine/src/recall/conversations.rs +
//  database/repositories/ask_conversation.rs). Persistence only — independent of the LLM.
//
//  Retention: any conversation whose `updatedAt` is older than 7 days is hard-deleted (cascading
//  to its messages) lazily on read/write, mirroring the Rust `prune_older_than` call sites
//  (conversations.rs:87,161). ⚠️ One deliberate delta from Rust: Rust's `ask_conversation_get_impl`
//  does NOT call `prune_older_than` (only `list_impl`/`ask_message_append_impl` do) — this port
//  also prunes inside `get(_:)` so a stale (>7d) conversation reads consistently as absent from
//  every entry point, rather than staying reachable by id after it has already dropped out of
//  `list`. `get`'s "not found" case returns `nil` (the Swift-idiomatic Optional the plan
//  specifies, §2.3) rather than Rust's `"Conversation not found."` string error.
//
//  `sourcesJson` on `askMessage` stores APP-SUPPLIED `RecallSource`s as JSON — trusted app data,
//  never parsed back from a model — and round-trips faithfully (plan §7).
//
import Foundation
import GRDB

public struct AskConversationStore: Sendable {
    let dbWriter: any DatabaseWriter

    /// ← `RETENTION_DAYS` (conversations.rs:16).
    static let retentionDays = 7

    /// ← `ask_message_append_impl`'s role gate (conversations.rs:140-142). Only `user`/
    /// `assistant` are ever trusted as message authors; anything else (e.g. `system`) is refused.
    /// `invalidScope` (`docs/plans/ari-ask-ui.md` Phase 0) enforces the scope-key invariant:
    /// `meetingId` and `seriesId` may never BOTH be non-nil on the same conversation.
    public enum StoreError: Error, Sendable, Equatable {
        case unsupportedRole(String)
        case invalidScope
    }

    /// ← `retention_cutoff` (conversations.rs:18-20). `now` is injectable for deterministic
    /// tests; production callers use the default (wall-clock `Date()`).
    static func retentionCutoff(now: Date = Date()) -> String {
        RFC3339.string(from: now.addingTimeInterval(-Double(retentionDays) * 86400))
    }

    /// ← `AskConversationRepository::prune_older_than` (ask_conversation.rs:10-28). Must run
    /// inside the caller's own `dbWriter.write` transaction (no nested `write` here).
    private static func pruneOlderThan(_ cutoff: String, db: Database) throws {
        try db.execute(
            sql: """
            DELETE FROM askMessage WHERE conversationId IN \
            (SELECT id FROM askConversation WHERE updatedAt < ?)
            """,
            arguments: [cutoff]
        )
        try db.execute(
            sql: "DELETE FROM askConversation WHERE updatedAt < ?",
            arguments: [cutoff]
        )
    }

    /// ← `ask_conversation_list_impl` (conversations.rs:80-92), extended by
    /// `docs/plans/ari-ask-ui.md` Phase 0 to also key on `seriesId`. Prunes on read, then lists
    /// most-recently-updated first for the given scope: `meetingId` set → that meeting's threads;
    /// `seriesId` set → that series' threads; both `nil` → global chats (matching the Rust
    /// `meeting_id IS NULL` branch, `ask_conversation.rs:67-74`, now also requiring
    /// `seriesId IS NULL`). Passing both non-nil throws `StoreError.invalidScope`.
    public func list(meetingId: MeetingID? = nil, seriesId: SeriesID? = nil) async throws -> [AskConversation] {
        guard meetingId == nil || seriesId == nil else {
            throw StoreError.invalidScope
        }
        return try await dbWriter.write { db in
            try Self.pruneOlderThan(Self.retentionCutoff(), db: db)
            let request: QueryInterfaceRequest<AskConversationRecord> = if let meetingId {
                AskConversationRecord.filter(Column("meetingId") == meetingId.rawValue)
            } else if let seriesId {
                AskConversationRecord.filter(Column("seriesId") == seriesId.rawValue)
            } else {
                AskConversationRecord.filter(Column("meetingId") == nil && Column("seriesId") == nil)
            }
            return try request
                // `createdAt` then `id` are deterministic tiebreaks: `updatedAt` is millisecond
                // RFC3339, so sibling rows created/appended within the same millisecond would
                // otherwise order nondeterministically (a real test flake under parallel load).
                .order(Column("updatedAt").desc, Column("createdAt").desc, Column("id").desc)
                .fetchAll(db)
                .map { $0.asModel() }
        }
    }

    /// ← `ask_conversation_get_impl` (conversations.rs:94-111), plus the prune-on-read delta
    /// documented in this file's header. Returns `nil` when the conversation doesn't exist (or
    /// was just pruned).
    public func get(_ id: AskConversationID) async throws -> AskConversationDetail? {
        try await dbWriter.write { db in
            try Self.pruneOlderThan(Self.retentionCutoff(), db: db)
            guard let record = try AskConversationRecord.fetchOne(db, key: id.rawValue) else {
                return nil
            }
            let messages = try AskMessageRecord
                .filter(Column("conversationId") == id.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll(db)
                .map { $0.asModel() }
            return AskConversationDetail(conversation: record.asModel(), messages: messages)
        }
    }

    /// ← `ask_conversation_create_impl` (conversations.rs:113-131), extended by
    /// `docs/plans/ari-ask-ui.md` Phase 0 to also accept `seriesId`. Mints a fresh UUID id
    /// (matching `Uuid::new_v4()`) and stamps `createdAt == updatedAt` for a new conversation.
    /// Throws `StoreError.invalidScope` if both `meetingId` and `seriesId` are non-nil.
    public func create(
        meetingId: MeetingID? = nil,
        seriesId: SeriesID? = nil,
        title: String?
    ) async throws -> AskConversation {
        guard meetingId == nil || seriesId == nil else {
            throw StoreError.invalidScope
        }
        let now = RFC3339.string(from: Date())
        let record = AskConversationRecord(
            AskConversation(
                id: AskConversationID(UUID().uuidString),
                meetingId: meetingId,
                seriesId: seriesId,
                title: title,
                createdAt: now,
                updatedAt: now
            )
        )
        try await dbWriter.write { db in
            try record.insert(db)
        }
        return record.asModel()
    }

    /// ← `ask_message_append_impl` (conversations.rs:133-163). One transaction: insert the
    /// message, bump the conversation's `updatedAt`, then opportunistically prune (same order as
    /// Rust: insert+bump, then prune, `conversations.rs:149-161`).
    @discardableResult
    public func appendMessage(
        conversationId: AskConversationID,
        role: String,
        content: String,
        sources: [RecallSource]
    ) async throws -> AskMessage {
        guard role == "user" || role == "assistant" else {
            throw StoreError.unsupportedRole(role)
        }
        let now = RFC3339.string(from: Date())
        let message = AskMessage(
            id: AskMessageID(UUID().uuidString),
            conversationId: conversationId,
            role: role,
            content: content,
            sources: sources,
            createdAt: now
        )
        let record = try AskMessageRecord(message)

        try await dbWriter.write { db in
            try record.insert(db)
            try db.execute(
                sql: "UPDATE askConversation SET updatedAt = ? WHERE id = ?",
                arguments: [now, conversationId.rawValue]
            )
            try Self.pruneOlderThan(Self.retentionCutoff(), db: db)
        }
        return message
    }

    /// Deletes a conversation AND its messages in a single write transaction (`docs/plans/
    /// ari-ask-ui.md` Phase 0, resolved decision #2). Explicit two-statement delete (message rows
    /// first, then the parent row) rather than relying solely on the schema's
    /// `ON DELETE CASCADE` — same defense-in-depth style as `pruneOlderThan` above. A missing id
    /// is a silent no-op (idempotent delete), matching `pruneOlderThan`'s own "delete whatever
    /// matches, zero rows is fine" shape.
    public func delete(_ id: AskConversationID) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "DELETE FROM askMessage WHERE conversationId = ?",
                arguments: [id.rawValue]
            )
            try db.execute(
                sql: "DELETE FROM askConversation WHERE id = ?",
                arguments: [id.rawValue]
            )
        }
    }
}
