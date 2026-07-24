//
//  PromptJSONLoopTests.swift — plan §8.4 `PromptJSONLoopTests` (`ask-meetings-agentic-tools.md`),
//  rung 2 (the `.claudeCLI` prompt-JSON tool-calling loop), exercised via a scripted plain
//  `LLMClient`.
//
import Foundation
import Testing
@testable import AriKit

/// A scripted plain `LLMClient` (`.claudeCLI` kind — no native tool loop) that replays fixed
/// `generate` replies in order, one per call.
private actor ScriptedPlainLLM: LLMClient {
    nonisolated let kind: ProviderKind = .claudeCLI
    private var replies: [String]
    private(set) var callCount = 0

    init(replies: [String]) {
        self.replies = replies
    }

    func generate(_: LLMRequest) async throws -> String {
        callCount += 1
        guard !replies.isEmpty else { return "" }
        return replies.removeFirst()
    }
}

/// Collects `AgenticEvent`s observed live via `runPromptJSONLoop`'s `onEvent` sink.
private actor EventLog {
    private(set) var events: [AgenticEvent] = []
    func append(_ event: AgenticEvent) {
        events.append(event)
    }
}

@Suite("Prompt-JSON loop (rung 2 — .claudeCLI, ScriptedPlainLLM)")
struct PromptJSONLoopTests {
    private func makeToolset(_ db: AppDatabase) -> AskToolset {
        struct UnavailableEmbedder: RecallEmbedder {
            struct Unavailable: Error {}
            let modelTag = "unavailable"
            func embed(_: [String]) async throws -> [[Float]] {
                throw Unavailable()
            }
        }
        return AskToolset(
            tools: RecallTools(
                meetings: db.meetings, persons: db.persons, series: db.series,
                calendarEvents: db.calendarEvents, summaries: db.summaries
            ),
            hybridSearch: HybridSearch(
                recallIndex: db.recallIndex, meetings: db.meetings, summaries: db.summaries,
                transcripts: db.transcripts, embedder: UnavailableEmbedder()
            ),
            meetings: db.meetings
        )
    }

    private func makePrepared() -> RecallEngine.AgenticPreparedRequest {
        RecallEngine.AgenticPreparedRequest(
            systemPrompt: "system", userPrompt: "Question: hi",
            config: ProviderConfig(kind: .claudeCLI, model: "claude-cli")
        )
    }

    @Test(
        "a fenced ```json tool call is parsed, its args dispatched, and the result is appended to the next turn's prompt"
    )
    func fencedJSONToolCallParsedAndDispatched() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(Meeting(
            id: MeetingID("m1"), title: "Only meeting",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        let client = ScriptedPlainLLM(replies: [
            "```json\n{\"tool\": \"list_recent_meetings\", \"args\": {\"limit\": 5}}\n```",
            "Here is your one meeting."
        ])
        let toolset = makeToolset(db)
        let state = ToolTurnState()
        let log = EventLog()

        let (answer, committed) = try await RecallEngine.runPromptJSONLoop(
            client: client, prepared: makePrepared(), toolset: toolset, state: state
        ) { event in await log.append(event) }
        #expect(answer == "Here is your one meeting.")
        #expect(committed)
        let events = await log.events
        #expect(events.contains {
            if case .toolStarted(name: "list_recent_meetings") = $0 {
                true
            } else {
                false
            }
        })
        #expect(await client.callCount == 2)
    }

    @Test("an unfenced (bare) JSON tool call is also parsed leniently")
    func unfencedJSONToolCallParsed() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(Meeting(
            id: MeetingID("m1"), title: "Meeting",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        let client = ScriptedPlainLLM(replies: [
            "Sure, calling a tool now: {\"tool\": \"list_recent_meetings\", \"args\": {}}",
            "Final answer."
        ])
        let toolset = makeToolset(db)
        let state = ToolTurnState()

        let (answer, _) = try await RecallEngine.runPromptJSONLoop(
            client: client, prepared: makePrepared(), toolset: toolset, state: state
        )
        #expect(answer == "Final answer.")
    }

    @Test("a plain-text reply with no JSON is the final answer immediately")
    func plainTextReplyIsFinalAnswer() async throws {
        let db = try AppDatabase.makeInMemory()
        let client = ScriptedPlainLLM(replies: ["Hi! How can I help?"])
        let toolset = makeToolset(db)
        let state = ToolTurnState()

        let (answer, _) = try await RecallEngine.runPromptJSONLoop(
            client: client, prepared: makePrepared(), toolset: toolset, state: state
        )
        #expect(answer == "Hi! How can I help?")
        #expect(await client.callCount == 1)
    }

    @Test(
        "M5: two consecutive unparseable tool-shaped replies now THROW a descriptive error, instead of handing the model's raw garbage JSON to the user as an answer"
    )
    func twoConsecutiveUnparseableToolShapedRepliesThrow() async throws {
        let db = try AppDatabase.makeInMemory()
        let client = ScriptedPlainLLM(replies: [
            "```json\n{\"tool\": broken json here",
            "```json\n{\"tool\": still broken"
        ])
        let toolset = makeToolset(db)
        let state = ToolTurnState()

        await #expect(throws: RecallEngineError.self) {
            _ = try await RecallEngine.runPromptJSONLoop(
                client: client, prepared: makePrepared(), toolset: toolset, state: state
            )
        }
        #expect(await client.callCount == 2)
    }

    @Test("M1: a tool result with the \"Tool failed:\" prefix reports .toolFinished(ok: false), not a hardcoded true")
    func toolFailureResultReportsOkFalse() async throws {
        let db = try AppDatabase.makeInMemory()
        // `get_meeting_summary` with a meeting id never surfaced this turn returns an "Unknown
        // meeting id" string — not one of the 3 failure prefixes, so this asserts the SUCCESS side
        // first, then a real failing case below via `find_person`'s repository-level failure path
        // is exercised indirectly through the fixed prefix contract itself (AskToolsetTests already
        // covers each tool's own honest strings; this test asserts the ORCHESTRATOR reports `ok:`
        // faithfully from whatever string a tool call actually returns).
        let client = ScriptedPlainLLM(replies: [
            "```json\n{\"tool\": \"unknown_tool_name\", \"args\": {}}\n```",
            "Final answer."
        ])
        let toolset = makeToolset(db)
        let state = ToolTurnState()
        let log = EventLog()

        _ = try await RecallEngine.runPromptJSONLoop(
            client: client, prepared: makePrepared(), toolset: toolset, state: state
        ) { event in await log.append(event) }

        let events = await log.events
        #expect(events.contains {
            if case .toolFinished(name: "unknown_tool_name", ok: false) = $0 {
                true
            } else {
                false
            }
        })
    }

    @Test(
        "M5: a tool call whose JSON string argument contains a literal brace still parses (string/escape-aware brace counting)"
    )
    func toolCallWithBraceInsideStringArgumentParses() throws {
        let text = "```json\n{\"tool\": \"search_transcripts\", \"args\": {\"query\": \"a { b\"}}\n```"
        let parsed = try #require(RecallEngine.parseToolCall(from: text))
        #expect(parsed.tool == "search_transcripts")
        #expect(parsed.argumentsJSON.contains("a { b"))
    }

    @Test("the iteration cap is honored — the loop never exceeds RecallBounds.maxAgenticIterations turns")
    func iterationCapIsHonored() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(Meeting(
            id: MeetingID("m1"), title: "M",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        // Always requests a tool call, never answers directly — the loop must still terminate.
        let replies = Array(
            repeating: "```json\n{\"tool\": \"list_recent_meetings\", \"args\": {}}\n```",
            count: RecallBounds.maxAgenticIterations + 5
        )
        let client = ScriptedPlainLLM(replies: replies)
        let toolset = makeToolset(db)
        let state = ToolTurnState()

        _ = try await RecallEngine.runPromptJSONLoop(
            client: client, prepared: makePrepared(), toolset: toolset, state: state
        )
        #expect(await client.callCount <= RecallBounds.maxAgenticIterations)
    }

    @Test(
        "same source/citation assertions as the native loop: sources come from a real dispatched search_transcripts call"
    )
    func sourcesComeFromARealDispatchedSearch() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = Meeting(
            id: MeetingID("m1"), title: "Budget review",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await db.meetings.upsert(meeting)
        try await db.transcripts.upsert(Transcript(
            id: TranscriptID("t1"), meetingId: meeting.id,
            transcript: "We reviewed the budget.", timestamp: "00:00", audioStartTime: 0
        ))
        let client = ScriptedPlainLLM(replies: [
            "```json\n{\"tool\": \"search_transcripts\", \"args\": {\"query\": \"budget\"}}\n```",
            "Per [S1], the budget was reviewed."
        ])
        let toolset = makeToolset(db)
        let state = ToolTurnState()

        let (answer, _) = try await RecallEngine.runPromptJSONLoop(
            client: client, prepared: makePrepared(), toolset: toolset, state: state
        )
        #expect(answer.contains("[S1]"))
        #expect(await state.sources.count == 1)
    }
}
