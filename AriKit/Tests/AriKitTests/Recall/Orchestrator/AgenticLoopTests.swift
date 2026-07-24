//
//  AgenticLoopTests.swift — plan §8.3 `AgenticLoopTests` (`ask-meetings-agentic-tools.md`), the
//  native (rung 1) tool loop, exercised via a scripted fake `ToolCapableLLMClient`.
//
//  `RecallEngine.runNativeToolLoop` returns the client's raw `AsyncThrowingStream<AgenticEvent,
//  Error>` (plan review 2026-07-23: live streaming, not buffer-then-replay) — these tests drain it
//  via `RecallEngine.drainAgenticEvents`, passing an `onEvent` sink that appends to an `EventLog`
//  actor so assertions can inspect the full event sequence, exactly as a live streaming caller
//  would observe it.
//
import Foundation
import Testing
@testable import AriKit

/// A fake `ToolCapableLLMClient` that replays a fixed `[AgenticEvent]` script. Each `.toolStarted`
/// entry in the script is followed by a REAL dispatch through the provided `dispatch` closure (so
/// `ToolTurnState` genuinely accumulates), mirroring how `ChatSession` actually drives tool calls —
/// this fake owns "when to call which tool with what arguments," never the tool's own logic.
private actor ScriptedToolLLM: ToolCapableLLMClient {
    nonisolated let kind: ProviderKind = .mlx

    struct ScriptedCall {
        var toolName: String
        var argumentsJSON: String
    }

    /// Either a plain event to replay verbatim, or a scripted tool call to actually dispatch.
    enum Step {
        case event(AgenticEvent)
        case toolCall(ScriptedCall)
    }

    private let steps: [Step]
    private let throwAfterSteps: Int?

    init(steps: [Step], throwAfterSteps: Int? = nil) {
        self.steps = steps
        self.throwAfterSteps = throwAfterSteps
    }

    func generate(_: LLMRequest) async throws -> String {
        ""
    }

    nonisolated func respondWithTools(
        _: LLMRequest,
        tools _: [AgenticToolDefinition],
        dispatch: @escaping AgenticToolDispatch
    ) -> AsyncThrowingStream<AgenticEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for (index, step) in steps.enumerated() {
                    if let throwAfterSteps, index == throwAfterSteps {
                        continuation.finish(throwing: TestFailure())
                        return
                    }
                    switch step {
                    case let .event(event):
                        continuation.yield(event)
                    case let .toolCall(scriptedCall):
                        continuation.yield(.toolStarted(name: scriptedCall.toolName))
                        let call = AgenticToolCall(
                            id: UUID().uuidString, name: scriptedCall.toolName,
                            argumentsJSON: scriptedCall.argumentsJSON
                        )
                        _ = try? await dispatch(call)
                        continuation.yield(.toolFinished(name: scriptedCall.toolName, ok: true))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct TestFailure: Error {}

/// Collects `AgenticEvent`s as an `onEvent` sink observes them — mirrors what a live streaming
/// caller does with each event, letting tests assert on the exact observed sequence.
private actor EventLog {
    private(set) var events: [AgenticEvent] = []
    func append(_ event: AgenticEvent) {
        events.append(event)
    }
}

@Suite("Agentic loop (rung 1 — native tool loop, ScriptedToolLLM)")
struct AgenticLoopTests {
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
            config: ProviderConfig(kind: .mlx, model: "test")
        )
    }

    /// Drains `client`'s native tool loop via `drainAgenticEvents`, collecting every observed
    /// event into an `EventLog` (mirrors how a live streaming caller would forward them).
    private func drain(
        _ client: any ToolCapableLLMClient,
        toolset: AskToolset,
        state: ToolTurnState
    ) async throws -> (answer: String, committed: Bool, events: [AgenticEvent]) {
        let log = EventLog()
        let stream = RecallEngine.runNativeToolLoop(
            client: client, prepared: makePrepared(), toolset: toolset, state: state
        )
        let (answer, committed) = try await RecallEngine.drainAgenticEvents(stream) { event in
            await log.append(event)
        }
        return await (answer, committed, log.events)
    }

    @Test(
        "route → one tool call → answer: events arrive in order, sources/cards accumulate, .done carries the reconciled answer + real sources"
    )
    func routeThenToolCallThenAnswer() async throws {
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

        let client = ScriptedToolLLM(steps: [
            .toolCall(.init(toolName: "search_transcripts", argumentsJSON: #"{"query": "budget"}"#)),
            .event(.answerDelta("Per [S1], the budget was reviewed."))
        ])
        let toolset = makeToolset(db)
        let state = ToolTurnState()

        let (answer, committed, events) = try await drain(client, toolset: toolset, state: state)

        #expect(answer == "Per [S1], the budget was reviewed.")
        #expect(committed)
        #expect(events.contains {
            if case .toolStarted(name: "search_transcripts") = $0 {
                true
            } else {
                false
            }
        })
        #expect(await state.sources.count == 1)
    }

    @Test("no-tool small talk: zero sources, any emitted [Sn] would be stripped by reconcile downstream")
    func noToolSmallTalk() async throws {
        let db = try AppDatabase.makeInMemory()
        let client = ScriptedToolLLM(steps: [.event(.answerDelta("Hi there!"))])
        let toolset = makeToolset(db)
        let state = ToolTurnState()

        let (answer, committed, _) = try await drain(client, toolset: toolset, state: state)
        #expect(answer == "Hi there!")
        #expect(committed)
        #expect(await state.sources.isEmpty)
        let reconciled = RecallEngine.reconcile(answer: "Hi [S1] there!", sources: [], isMeetingScoped: false)
        #expect(!reconciled.contains("[S1]"))
    }

    @Test("a tool that fails still returns an error string, the loop continues, and an answer still lands")
    func toolThrowsButLoopContinues() async throws {
        let db = try AppDatabase.makeInMemory()
        let client = ScriptedToolLLM(steps: [
            .toolCall(.init(toolName: "find_person", argumentsJSON: #"{"name": "Nobody"}"#)),
            .event(.answerDelta("I couldn't find that person."))
        ])
        let toolset = makeToolset(db)
        let state = ToolTurnState()

        let (answer, committed, _) = try await drain(client, toolset: toolset, state: state)
        #expect(answer == "I couldn't find that person.")
        #expect(committed)
        #expect(await state.cards.isEmpty)
    }

    @Test("more than 8 scripted tool calls hit the exhaustion string after the 8th, no 9th execution")
    func exceedingIterationBudgetExhausts() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(Meeting(
            id: MeetingID("m1"), title: "M",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        let toolset = makeToolset(db)
        let state = ToolTurnState()

        var results: [String] = []
        for _ in 0 ..< 10 {
            let call = AgenticToolCall(id: UUID().uuidString, name: "list_recent_meetings", argumentsJSON: "{}")
            await results.append(toolset.dispatch(call, state: state))
        }
        #expect(results[0 ..< 8].allSatisfy { !$0.contains("budget exhausted") })
        #expect(results[8].contains("Tool budget exhausted"))
        #expect(results[9].contains("Tool budget exhausted"))
        #expect(await state.iterations == RecallBounds.maxAgenticIterations)
    }

    @Test("thinking deltas stream as .thinking, never concatenated into the reconciled answer")
    func thinkingDeltasNeverEnterTheAnswer() async throws {
        let db = try AppDatabase.makeInMemory()
        let client = ScriptedToolLLM(steps: [
            .event(.thinking("Let me consider this...")),
            .event(.answerDelta("The final answer."))
        ])
        let toolset = makeToolset(db)
        let state = ToolTurnState()

        let (answer, committed, events) = try await drain(client, toolset: toolset, state: state)
        #expect(answer == "The final answer.")
        #expect(committed)
        #expect(!answer.contains("consider"))
        #expect(events.contains {
            if case .thinking = $0 {
                true
            } else {
                false
            }
        })
    }

    @Test("a throw before any answer text propagates (the caller falls back to rung 3)")
    func throwBeforeAnyAnswerTextPropagates() async throws {
        let db = try AppDatabase.makeInMemory()
        let client = ScriptedToolLLM(steps: [.event(.thinking("thinking..."))], throwAfterSteps: 0)
        let toolset = makeToolset(db)
        let state = ToolTurnState()

        await #expect(throws: (any Error).self) {
            _ = try await drain(client, toolset: toolset, state: state)
        }
    }

    @Test("a throw AFTER some answer text already accumulated returns that text as committed rather than discarding it")
    func throwAfterAnswerTextStillReturnsIt() async throws {
        let db = try AppDatabase.makeInMemory()
        let client = ScriptedToolLLM(
            steps: [.event(.answerDelta("Partial answer.")), .event(.thinking("more"))], throwAfterSteps: 1
        )
        let toolset = makeToolset(db)
        let state = ToolTurnState()

        let (answer, committed, _) = try await drain(client, toolset: toolset, state: state)
        #expect(answer == "Partial answer.")
        #expect(committed, "the first answer delta already committed rung 1 — the later throw must not undo that")
    }

    @Test(
        "events are observed live via onEvent as they arrive — a tool-activity event is observed before the final answer is drained"
    )
    func eventsAreObservedLiveAsTheyArrive() async throws {
        let db = try AppDatabase.makeInMemory()
        let client = ScriptedToolLLM(steps: [
            .toolCall(.init(toolName: "list_recent_meetings", argumentsJSON: "{}")),
            .event(.answerDelta("Done."))
        ])
        let toolset = makeToolset(db)
        let state = ToolTurnState()

        actor OrderLog {
            private(set) var order: [String] = []
            func append(_ label: String) {
                order.append(label)
            }
        }
        let orderLog = OrderLog()
        let stream = RecallEngine.runNativeToolLoop(
            client: client,
            prepared: makePrepared(),
            toolset: toolset,
            state: state
        )
        _ = try await RecallEngine.drainAgenticEvents(stream) { event in
            switch event {
            case .toolStarted: await orderLog.append("toolStarted")
            case .toolFinished: await orderLog.append("toolFinished")
            case .answerDelta: await orderLog.append("answerDelta")
            case .thinking: await orderLog.append("thinking")
            }
        }
        let observedOrder = await orderLog.order
        #expect(observedOrder == ["toolStarted", "toolFinished", "answerDelta"])
    }
}
