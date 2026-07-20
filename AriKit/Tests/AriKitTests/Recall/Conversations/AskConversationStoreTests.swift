//
//  AskConversationStoreTests.swift — plan §6 `AskRetentionTests` (Recall Slice 6,
//  ← ari-engine/src/recall/conversations.rs + database/repositories/ask_conversation.rs).
//
//  Built on `AppDatabase.makeInMemory()`, seeding a real `Meeting` via `db.meetings.upsert(_:)`
//  first so the meeting-scoped conversation's FK is satisfiable. Retention age is injected by
//  writing an old `updatedAt` directly through the module-internal `dbWriter`
//  (`@testable import AriKit`) — never wall-clock `now()` magic.
//
import Foundation
import GRDB
import Testing
@testable import AriKit

@Suite("Ask conversation store — Recall Slice 6")
struct AskConversationStoreTests {
    private func makeMeeting(id: String = "meeting-1") -> Meeting {
        Meeting(
            id: MeetingID(id),
            title: "Ask conversation fixture meeting",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeSource(meetingId: String = "meeting-1") -> RecallSource {
        RecallSource(
            meetingId: meetingId,
            title: "Weekly sync",
            matchContext: "We decided to ship the recall port.",
            timestamp: "00:42",
            meetingDate: "2026-07-18",
            summary: "Shipped the recall port.",
            speakers: ["Ada"]
        )
    }

    // MARK: - Test 1: create -> list -> get round trip; global vs meeting-scoped

    @Test("create -> list -> get round-trips; global and meeting-scoped listings stay separate")
    func createListGetRoundTrip() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting()
        try await db.meetings.upsert(meeting)

        let global = try await db.askConversations.create(meetingId: nil, title: "Global chat")
        let scoped = try await db.askConversations.create(meetingId: meeting.id, title: "Meeting chat")

        #expect(global.meetingId == nil)
        #expect(global.title == "Global chat")
        #expect(global.createdAt == global.updatedAt)
        #expect(scoped.meetingId == meeting.id)

        let globalList = try await db.askConversations.list(meetingId: nil)
        #expect(globalList.map(\.id) == [global.id])

        let scopedList = try await db.askConversations.list(meetingId: meeting.id)
        #expect(scopedList.map(\.id) == [scoped.id])

        let fetchedGlobal = try #require(await db.askConversations.get(global.id))
        #expect(fetchedGlobal.conversation.id == global.id)
        #expect(fetchedGlobal.messages.isEmpty)

        let fetchedScoped = try #require(await db.askConversations.get(scoped.id))
        #expect(fetchedScoped.conversation.meetingId == meeting.id)
        #expect(fetchedScoped.messages.isEmpty)
    }

    @Test("get returns nil for an unknown conversation id")
    func getUnknownConversationReturnsNil() async throws {
        let db = try AppDatabase.makeInMemory()
        let missing = try await db.askConversations.get(AskConversationID("does-not-exist"))
        #expect(missing == nil)
    }

    @Test("list(meetingId:) most-recently-updated first, per scope")
    func listOrdersMostRecentlyUpdatedFirst() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting()
        try await db.meetings.upsert(meeting)

        let older = try await db.askConversations.create(meetingId: nil, title: "Older")
        let newer = try await db.askConversations.create(meetingId: nil, title: "Newer")
        // Bump `newer`'s updatedAt past `older`'s via an appended message.
        try await db.askConversations.appendMessage(
            conversationId: newer.id, role: "user", content: "hello", sources: []
        )

        let list = try await db.askConversations.list(meetingId: nil)
        #expect(list.map(\.id) == [newer.id, older.id])
    }

    // MARK: - Test 2: appendMessage persists + bumps updatedAt + orders by createdAt

    @Test("appendMessage persists role/content, bumps updatedAt, and orders by createdAt")
    func appendMessagePersistsAndBumpsUpdatedAt() async throws {
        let db = try AppDatabase.makeInMemory()
        let conversation = try await db.askConversations.create(meetingId: nil, title: nil)

        let userMessage = try await db.askConversations.appendMessage(
            conversationId: conversation.id,
            role: "user",
            content: "What did we decide about the recall port?",
            sources: []
        )
        #expect(userMessage.role == "user")
        #expect(userMessage.content == "What did we decide about the recall port?")
        #expect(userMessage.sources.isEmpty)

        let assistantMessage = try await db.askConversations.appendMessage(
            conversationId: conversation.id,
            role: "assistant",
            content: "You decided to ship the Swift port.",
            sources: [makeSource()]
        )
        #expect(assistantMessage.role == "assistant")

        let detail = try #require(await db.askConversations.get(conversation.id))
        #expect(detail.messages.map(\.id) == [userMessage.id, assistantMessage.id])
        // updatedAt was bumped by the SECOND append, to that append's own timestamp.
        #expect(detail.conversation.updatedAt == assistantMessage.createdAt)
    }

    @Test("appendMessage rejects an unsupported role")
    func appendMessageRejectsUnsupportedRole() async throws {
        let db = try AppDatabase.makeInMemory()
        let conversation = try await db.askConversations.create(meetingId: nil, title: nil)

        await #expect(throws: AskConversationStore.StoreError.unsupportedRole("system")) {
            try await db.askConversations.appendMessage(
                conversationId: conversation.id, role: "system", content: "ignored", sources: []
            )
        }
    }

    // MARK: - Test 3: 7-day retention prune on read

    @Test("a conversation older than 7 days is pruned on the next read; a fresh one survives")
    func retentionPrunesStaleConversationsOnRead() async throws {
        let db = try AppDatabase.makeInMemory()

        let stale = try await db.askConversations.create(meetingId: nil, title: "Stale")
        try await db.askConversations.appendMessage(
            conversationId: stale.id, role: "user", content: "old question", sources: []
        )
        let fresh = try await db.askConversations.create(meetingId: nil, title: "Fresh")

        // Directly age the stale conversation's `updatedAt` to 8 days ago — no wall-clock magic.
        let staleUpdatedAt = RFC3339.string(
            from: Date().addingTimeInterval(-8 * 86400)
        )
        try await db.dbWriter.write { rawDb in
            try rawDb.execute(
                sql: "UPDATE askConversation SET updatedAt = ? WHERE id = ?",
                arguments: [staleUpdatedAt, stale.id.rawValue]
            )
        }

        // Sanity: both rows still present before any prune-triggering read.
        let messageCountBefore = try await db.dbWriter.read { rawDb in
            try Int.fetchOne(
                rawDb,
                sql: "SELECT COUNT(*) FROM askMessage WHERE conversationId = ?",
                arguments: [stale.id.rawValue]
            )
        }
        #expect(messageCountBefore == 1)

        let listed = try await db.askConversations.list(meetingId: nil)
        #expect(listed.map(\.id) == [fresh.id])

        // The stale conversation is gone even by direct id lookup, and its message cascaded away.
        let staleDetail = try await db.askConversations.get(stale.id)
        #expect(staleDetail == nil)
        let messageCountAfter = try await db.dbWriter.read { rawDb in
            try Int.fetchOne(
                rawDb,
                sql: "SELECT COUNT(*) FROM askMessage WHERE conversationId = ?",
                arguments: [stale.id.rawValue]
            )
        }
        #expect(messageCountAfter == 0)

        // The fresh conversation survives untouched.
        let freshDetail = try #require(await db.askConversations.get(fresh.id))
        #expect(freshDetail.conversation.id == fresh.id)
    }

    @Test("retention prune triggered via get(_:) also removes a stale conversation from list")
    func retentionPruneViaGetAlsoAffectsList() async throws {
        let db = try AppDatabase.makeInMemory()
        let stale = try await db.askConversations.create(meetingId: nil, title: "Stale via get")
        let staleUpdatedAt = RFC3339.string(from: Date().addingTimeInterval(-10 * 86400))
        try await db.dbWriter.write { rawDb in
            try rawDb.execute(
                sql: "UPDATE askConversation SET updatedAt = ? WHERE id = ?",
                arguments: [staleUpdatedAt, stale.id.rawValue]
            )
        }

        // Trigger the prune via `get`, not `list`.
        let result = try await db.askConversations.get(stale.id)
        #expect(result == nil)

        let remaining = try await db.dbWriter.read { rawDb in
            try Int.fetchOne(
                rawDb,
                sql: "SELECT COUNT(*) FROM askConversation WHERE id = ?",
                arguments: [stale.id.rawValue]
            )
        }
        #expect(remaining == 0)
    }

    // MARK: - Test 4: sources round-trip as app-authored JSON

    @Test("sources round-trip through sourcesJson with full equality")
    func sourcesRoundTripFaithfully() async throws {
        let db = try AppDatabase.makeInMemory()
        let conversation = try await db.askConversations.create(meetingId: nil, title: nil)
        let sources = [makeSource(meetingId: "meeting-a"), makeSource(meetingId: "meeting-b")]

        let appended = try await db.askConversations.appendMessage(
            conversationId: conversation.id,
            role: "assistant",
            content: "Here is what I found.",
            sources: sources
        )
        #expect(appended.sources == sources)

        let detail = try #require(await db.askConversations.get(conversation.id))
        let readBack = try #require(detail.messages.first { $0.id == appended.id })
        #expect(readBack.sources == sources)
    }

    @Test("empty sources encode/decode as an honest empty array, never nil-crashing a read")
    func emptySourcesRoundTripAsEmptyArray() async throws {
        let db = try AppDatabase.makeInMemory()
        let conversation = try await db.askConversations.create(meetingId: nil, title: nil)

        let userMessage = try await db.askConversations.appendMessage(
            conversationId: conversation.id, role: "user", content: "no sources here", sources: []
        )
        #expect(userMessage.sources.isEmpty)

        let detail = try #require(await db.askConversations.get(conversation.id))
        let readBack = try #require(detail.messages.first { $0.id == userMessage.id })
        #expect(readBack.sources.isEmpty)
    }
}
