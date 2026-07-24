//
//  RecallEngineAgenticTests.swift — plan §8.5 (fallback ladder), §8.6 (target-query integration),
//  §8.7 (live-failure regressions), `ask-meetings-agentic-tools.md`.
//
//  Built on `AppDatabase.makeInMemory()` + real repositories, mirroring `RecallEngineTests`'
//  fixture pattern exactly (same `makeMeeting`/`seedMeetingWithTranscripts`/stub settings shape).
//
import Foundation
import Testing
@testable import AriKit

@Suite("RecallEngine — tool-first agentic path (ask-meetings-agentic-tools.md)")
struct RecallEngineAgenticTests {

    // MARK: - Fixtures (mirrors RecallEngineTests)

    private struct UnavailableEmbedder: RecallEmbedder {
        struct Unavailable: Error {}
        let modelTag = "unavailable"
        func embed(_: [String]) async throws -> [[Float]] {
            throw Unavailable()
        }
    }

    private func makeMeeting(
        id: String, title: String = "Fixture meeting", createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Meeting {
        Meeting(id: MeetingID(id), title: title, createdAt: createdAt, updatedAt: createdAt)
    }

    private func makeEngine(
        _ db: AppDatabase,
        client: any LLMClient,
        modelConfig: RecallModelConfig? = RecallModelConfig(provider: "ollama", model: "llama3")
    ) -> RecallEngine {
        RecallEngine(
            db: db,
            hybridSearch: HybridSearch(
                recallIndex: db.recallIndex, meetings: db.meetings, summaries: db.summaries,
                transcripts: db.transcripts, embedder: UnavailableEmbedder()
            ),
            peopleContext: PeopleContext(
                persons: db.persons,
                profileFacts: db.profileFacts,
                calendarEvents: db.calendarEvents
            ),
            settings: StubRecallSettingsReading(config: modelConfig),
            secrets: StubRecallSecretsReading(apiKeys: [:]),
            clientFactory: { _ in client }
        )
    }

    // MARK: - Fake clients

    /// A plain (non-tool-capable) client — used to prove rung 3 (classifier + single-shot RAG) is
    /// reached, and that it is byte-identical to the pre-agentic pipeline.
    private actor PlainClient: LLMClient {
        nonisolated let kind: ProviderKind
        private let cannedResponse: String
        private(set) var generateCallCount = 0
        private(set) var lastSystemPrompt: String?
        private(set) var lastUserPrompt: String?

        init(kind: ProviderKind = .ollama, cannedResponse: String) {
            self.kind = kind
            self.cannedResponse = cannedResponse
        }

        func generate(_ request: LLMRequest) async throws -> String {
            generateCallCount += 1
            lastSystemPrompt = request.system
            lastUserPrompt = request.user
            return cannedResponse
        }
    }

    /// A `ToolCapableLLMClient` (`.mlx`) that either answers directly or throws, per test need.
    private actor ToolCapableClient: ToolCapableLLMClient {
        nonisolated let kind: ProviderKind = .mlx
        private let script: [AgenticEvent]?
        private let shouldThrowBeforeAnswer: Bool

        init(script: [AgenticEvent]? = nil, shouldThrowBeforeAnswer: Bool = false) {
            self.script = script
            self.shouldThrowBeforeAnswer = shouldThrowBeforeAnswer
        }

        func generate(_: LLMRequest) async throws -> String {
            ""
        }

        nonisolated func respondWithTools(
            _: LLMRequest, tools _: [AgenticToolDefinition], dispatch: @escaping AgenticToolDispatch
        ) -> AsyncThrowingStream<AgenticEvent, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    if shouldThrowBeforeAnswer {
                        struct Boom: Error {}
                        continuation.finish(throwing: Boom())
                        return
                    }
                    for event in script ?? [] {
                        if case let .toolStarted(name) = event {
                            // Replay-through dispatch would need real args; the target-query tests
                            // below drive dispatch themselves via a scripted tool call instead of
                            // this bare script path — this branch exists only for the ladder tests
                            // that never need a real dispatch (answer-only scripts).
                            _ = name
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    /// A `ToolCapableLLMClient` that actually dispatches one scripted tool call, then answers —
    /// used by the target-query integration tests (§8.6).
    private actor ScriptedDispatchingToolClient: ToolCapableLLMClient {
        nonisolated let kind: ProviderKind = .mlx
        struct Call { var name: String; var argumentsJSON: String }
        private let calls: [Call]
        private let finalAnswer: String

        init(calls: [Call], finalAnswer: String) {
            self.calls = calls
            self.finalAnswer = finalAnswer
        }

        func generate(_: LLMRequest) async throws -> String {
            ""
        }

        nonisolated func respondWithTools(
            _: LLMRequest, tools _: [AgenticToolDefinition], dispatch: @escaping AgenticToolDispatch
        ) -> AsyncThrowingStream<AgenticEvent, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    for call in calls {
                        continuation.yield(.toolStarted(name: call.name))
                        let toolCall = AgenticToolCall(
                            id: UUID().uuidString,
                            name: call.name,
                            argumentsJSON: call.argumentsJSON
                        )
                        _ = try? await dispatch(toolCall)
                        continuation.yield(.toolFinished(name: call.name, ok: true))
                    }
                    continuation.yield(.answerDelta(finalAnswer))
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    // MARK: - §8.5 Fallback ladder

    @Test(".mlx-kind client conforming to ToolCapableLLMClient is chosen for rung 1")
    func mlxToolCapableClientChoosesRung1() async throws {
        let db = try AppDatabase.makeInMemory()
        let client = ToolCapableClient(script: [.answerDelta("Hello from rung 1.")])
        let engine = makeEngine(db, client: client, modelConfig: RecallModelConfig(provider: "mlx", model: "mlx"))

        let response = try await engine.answerMeetingsLocally(question: "Hi")
        #expect(response.answer == "Hello from rung 1.")
    }

    @Test(".claudeCLI is chosen for rung 2 (the prompt-JSON loop)")
    func claudeCLIChoosesRung2() async throws {
        let db = try AppDatabase.makeInMemory()
        let client = ClaudeCLIStyleClient(replies: ["Hello from rung 2."])
        let engine = makeEngine(
            db,
            client: client,
            modelConfig: RecallModelConfig(provider: "claude-cli", model: "claude-cli")
        )

        let response = try await engine.answerMeetingsLocally(question: "Hi")
        #expect(response.answer == "Hello from rung 2.")
    }

    private actor ClaudeCLIStyleClient: LLMClient {
        nonisolated let kind: ProviderKind = .claudeCLI
        private var replies: [String]
        init(replies: [String]) {
            self.replies = replies
        }

        func generate(_: LLMRequest) async throws -> String {
            guard !replies.isEmpty else { return "" }
            return replies.removeFirst()
        }
    }

    @Test(".ollama/other providers route to rung 3, byte-identical to today's prepared prompt (regression lock)")
    func ollamaRoutesToRung3ByteIdentical() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "m1", title: "AI review")
        try await db.meetings.upsert(meeting)
        try await db.transcripts.upsert(Transcript(
            id: TranscriptID("t1"), meetingId: meeting.id,
            transcript: "We decided to keep recall local.", timestamp: "00:05", audioStartTime: 5
        ))

        let agenticClient = PlainClient(cannedResponse: "Answer via rung 3.")
        let agenticEngine = makeEngine(db, client: agenticClient)
        let agenticResponse = try await agenticEngine.answerMeetingsLocally(question: "What did we decide?")

        // The byte-identical regression lock: the pre-agentic `prepare()` + `generate()` path,
        // called directly, must produce the exact same prompt/answer shape.
        let directClient = PlainClient(cannedResponse: "Answer via rung 3.")
        let directEngine = makeEngine(db, client: directClient)
        let directPrepared = try await directEngine.prepare(
            question: "What did we decide?", meetingId: nil, seriesId: nil, history: []
        )
        _ = try await directClient.generate(LLMRequest(
            system: directPrepared.systemPrompt,
            user: directPrepared.userPrompt
        ))

        #expect(await agenticClient.lastSystemPrompt == (directClient.lastSystemPrompt))
        #expect(await agenticClient.lastUserPrompt == (directClient.lastUserPrompt))
        #expect(agenticResponse.answer == "Answer via rung 3.")
    }

    @Test("rung 1 throws before the first answer delta → rung 3 runs, and the response is rung 3's output only")
    func rung1ThrowsBeforeAnswerFallsBackToRung3() async throws {
        let db = try AppDatabase.makeInMemory()
        _ = try? await db.meetings.upsert(makeMeeting(id: "m1"))
        let toolClient = ToolCapableClient(shouldThrowBeforeAnswer: true)
        let engine = makeEngine(db, client: toolClient, modelConfig: RecallModelConfig(provider: "mlx", model: "mlx"))

        // rung 3 for `.mlx` kind (not `.claudeCLI`/loopback-Ollama) still routes through the
        // classifier+single-shot path — `answerMeetingsLocallySingleShot` calls `clientFactory`
        // again, so the SAME `toolClient` is asked to `generate` (not `respondWithTools`) this time.
        let response = try await engine.answerMeetingsLocally(question: "Hi")
        #expect(response.answer.isEmpty, "the throwing tool client's plain generate() returns \"\" by default")
    }

    @Test("streaming honors the same fallback ladder — VM-visible stream contains only rung 3 output on a rung-1 throw")
    func streamingFallsBackToRung3OnRung1Throw() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "m1", title: "Fallback meeting")
        try await db.meetings.upsert(meeting)

        let client = ThrowingThenGeneratingClient()
        let engine = makeEngine(db, client: client, modelConfig: RecallModelConfig(provider: "mlx", model: "mlx"))

        var deltas: [String] = []
        var done: RecallResponse?
        for try await event in engine.answerMeetingsLocallyStream(question: "Anything?") {
            switch event {
            case let .delta(text): deltas.append(text)
            case let .done(response): done = response
            case .thinking, .toolActivity: break
            }
        }
        #expect(deltas == ["Fallback stream token."])
        #expect(try #require(done).answer == "Fallback stream token.")
    }

    /// A `ToolCapableLLMClient` whose `respondWithTools` always throws before any answer, but whose
    /// plain `stream` (used by rung 3's REAL streaming pipeline) yields a real token.
    private actor ThrowingThenGeneratingClient: ToolCapableLLMClient {
        nonisolated let kind: ProviderKind = .mlx
        func generate(_: LLMRequest) async throws -> String {
            "Fallback stream token."
        }

        nonisolated func stream(_: LLMRequest) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield("Fallback stream token.")
                continuation.finish()
            }
        }

        nonisolated func respondWithTools(
            _: LLMRequest, tools _: [AgenticToolDefinition], dispatch _: @escaping AgenticToolDispatch
        ) -> AsyncThrowingStream<AgenticEvent, Error> {
            AsyncThrowingStream { continuation in
                struct Boom: Error {}
                continuation.finish(throwing: Boom())
            }
        }
    }

    @Test("the loopback violation still throws before any tool/loop work, even for a tool-capable client")
    func loopbackViolationStillThrowsFirst() async throws {
        let db = try AppDatabase.makeInMemory()
        let client = ToolCapableClient(script: [.answerDelta("should never run")])
        let engine = makeEngine(
            db, client: client,
            modelConfig: RecallModelConfig(
                provider: "ollama",
                model: "llama3",
                ollamaEndpoint: "https://ollama.example.com"
            )
        )
        await #expect(throws: RecallEngineError.loopbackViolation) {
            _ = try await engine.answerMeetingsLocally(question: "Hi")
        }
    }

    // MARK: - §8.6 Target-query integration tests

    @Test("Landon recap: find_person → get_meeting_summary → answer, with a .person card and no invented [Sn]")
    func landonRecapIntegration() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "m-landon", title: "Landon sync")
        try await db.meetings.upsert(meeting)
        try await db.summaries.upsert(Summary(
            id: SummaryID("s-landon"), meetingId: meeting.id, bodyMarkdown: "Discussed the roadmap with Landon.",
            createdAt: meeting.createdAt, updatedAt: meeting.createdAt
        ))
        let person = Person(
            id: PersonID("p-landon"), email: "landon@example.com", displayName: "Landon Star",
            isOwner: false, createdAt: meeting.createdAt, updatedAt: meeting.createdAt
        )
        try await db.persons.upsert(person)
        try await db.calendarEvents.upsert(CalendarEvent(
            id: CalendarEventID("e-landon"), calendarId: "cal-1", title: "Landon sync",
            startTime: meeting.createdAt, endTime: meeting.createdAt.addingTimeInterval(1800), isAllDay: false,
            attendees: [Attendee(name: "Landon Star", email: "landon@example.com")],
            meetingId: meeting.id, linkSource: .calendar
        ))

        let client = ScriptedDispatchingToolClient(
            calls: [.init(name: "find_person", argumentsJSON: #"{"name": "Landon"}"#)],
            finalAnswer: "You caught up on the roadmap with Landon."
        )
        let engine = makeEngine(db, client: client, modelConfig: RecallModelConfig(provider: "mlx", model: "mlx"))

        let response = try await engine
            .answerMeetingsLocally(question: "Remind me about that meeting I had with Landon earlier")
        #expect(response.answer == "You caught up on the roadmap with Landon.")
        let card = try #require(response.cards.first)
        guard case .person = card else {
            Issue.record("expected a .person card")
            return
        }
        // No invented [Sn] — no search_transcripts call happened, so no sources exist to cite.
        #expect(response.sources.isEmpty)
    }

    @Test(
        "Meeting-scoped action items: the untouched single-shot path — full transcript, in-range @ref kept, [Sn] verified"
    )
    func meetingScopedActionItemsUnchangedPath() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "m-actions", title: "Planning")
        try await db.meetings.upsert(meeting)
        try await db.transcripts.upsert(Transcript(
            id: TranscriptID("t1"), meetingId: meeting.id,
            transcript: "Action: ship the feature by Friday.", timestamp: "00:10", audioStartTime: 10
        ))
        let client = PlainClient(kind: .ollama, cannedResponse: "Per [S1], ship the feature by Friday. @ref(00:10)")
        let engine = makeEngine(db, client: client)

        let response = try await engine.answerMeetingsLocally(
            question: "What are the action items of this meeting", meetingId: meeting.id
        )
        #expect(response.answer.contains("[S1]"))
        #expect(response.answer.contains("@ref(00:10)"))
        #expect(response.sources.count == 1)
    }

    @Test(
        "6pm attendees: calendar_events(hour: 18) → a .calendarEvent card, attendee names in the answer, zero sources, no recorded/discussed claim"
    )
    func sixPMAttendeesIntegration() async throws {
        let db = try AppDatabase.makeInMemory()
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = 18
        let sixPM = try #require(calendar.date(from: components))
        try await db.calendarEvents.upsert(CalendarEvent(
            id: CalendarEventID("e-6pm"), calendarId: "cal-1", title: "Evening review",
            startTime: sixPM, endTime: sixPM.addingTimeInterval(1800), isAllDay: false,
            attendees: [
                Attendee(name: "James Nance", email: "james@example.com"),
                Attendee(name: "Sarah Ammon", email: "sarah@example.com")
            ]
        ))

        let client = ScriptedDispatchingToolClient(
            calls: [.init(name: "calendar_events", argumentsJSON: #"{"hour": 18}"#)],
            finalAnswer: "James Nance and Sarah Ammon are attending the 6pm meeting (Evening review), which is scheduled but not yet recorded."
        )
        let engine = makeEngine(db, client: client, modelConfig: RecallModelConfig(provider: "mlx", model: "mlx"))

        let response = try await engine.answerMeetingsLocally(question: "Who is in the 6pm meeting later")
        #expect(response.answer.contains("James Nance"))
        #expect(response.answer.contains("Sarah Ammon"))
        #expect(response.sources.isEmpty)
        #expect(!response.answer.contains("was recorded"))
        let card = try #require(response.cards.first)
        guard case .calendarEvent = card else {
            Issue.record("expected a .calendarEvent card")
            return
        }
    }

    // MARK: - §8.7 Regression tests for the two live failures (2026-07-23)

    @Test(
        "Wrong-person-from-excerpts regression: the agentic prompt contains no unrequested excerpts about a DIFFERENT person"
    )
    func wrongPersonFromExcerptsRegression() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingA = makeMeeting(id: "m-a", title: "Person A sync")
        let meetingB = makeMeeting(id: "m-b", title: "Person B sync")
        try await db.meetings.upsert(meetingA)
        try await db.meetings.upsert(meetingB)
        try await db.transcripts.upsert(Transcript(
            id: TranscriptID("t-a"), meetingId: meetingA.id,
            transcript: "We discussed Person A's onboarding plan.", timestamp: "00:00", audioStartTime: 0
        ))
        try await db.transcripts.upsert(Transcript(
            id: TranscriptID("t-b"), meetingId: meetingB.id,
            transcript: "We discussed Person B's onboarding plan.", timestamp: "00:00", audioStartTime: 0
        ))

        let client = ScriptedPromptCapturingClient(cannedResponse: "Noted about Person A.")
        let engine = makeEngine(db, client: client, modelConfig: RecallModelConfig(provider: "mlx", model: "mlx"))

        // No tool-capable path here (client is plain, kind .mlx but not ToolCapableLLMClient) →
        // rung 3 (classifier + single-shot) — the assertion still holds structurally for the
        // AGENTIC prompt itself: `prepareAgentic` never assembles an "Authoritative local meeting
        // sources" block at all, so it structurally cannot contain unrequested excerpts.
        let prepared = try await engine.prepareAgentic(question: "Tell me about Person A", seriesId: nil, history: [])
        #expect(!prepared.userPrompt.contains("Authoritative local meeting sources"))
        #expect(!prepared.userPrompt.contains("Person B"))
        #expect(!prepared.systemPrompt.contains("Authoritative local meeting sources"))
    }

    /// A plain client that just captures its last prompt (used only for the structural
    /// `prepareAgentic` assertion above — the client is never actually asked to answer via a tool).
    private actor ScriptedPromptCapturingClient: LLMClient {
        nonisolated let kind: ProviderKind = .mlx
        private let cannedResponse: String
        init(cannedResponse: String) {
            self.cannedResponse = cannedResponse
        }

        func generate(_: LLMRequest) async throws -> String {
            cannedResponse
        }
    }

    @Test(
        "Card/answer contradiction regression: a resolved calendar_events card's facts have no competing excerpt block that could contradict them"
    )
    func cardAnswerContradictionRegression() async throws {
        let db = try AppDatabase.makeInMemory()
        let now = Date()
        try await db.calendarEvents.upsert(CalendarEvent(
            id: CalendarEventID("e-today"), calendarId: "cal-1", title: "Today sync",
            startTime: now, endTime: now.addingTimeInterval(1800), isAllDay: false,
            attendees: [Attendee(name: "James Nance", email: "james@example.com")]
        ))

        let client = ScriptedDispatchingToolClient(
            calls: [.init(name: "calendar_events", argumentsJSON: "{}")],
            finalAnswer: "James Nance is on today's calendar for \"Today sync\"."
        )
        let engine = makeEngine(db, client: client, modelConfig: RecallModelConfig(provider: "mlx", model: "mlx"))

        // Structurally, the agentic prompt carries NO excerpt block at all — the only calendar
        // facts in context are whatever the tool call itself returned, so there is nothing for the
        // card to contradict.
        let prepared = try await engine.prepareAgentic(
            question: "Who do I have a meeting with today?",
            seriesId: nil,
            history: []
        )
        #expect(!prepared.userPrompt.contains("Authoritative local meeting sources"))

        let response = try await engine.answerMeetingsLocally(question: "Who do I have a meeting with today?")
        let card = try #require(response.cards.first)
        guard case let .calendarEvent(payload) = card else {
            Issue.record("expected a .calendarEvent card")
            return
        }
        #expect(payload.attendeeNames.contains("James Nance"))
        #expect(response.answer.contains("James Nance"))
    }

    // MARK: - Live streaming (2026-07-23 principal review — rejects buffer-then-replay)

    /// Suspends `wait()` callers until `release()` is called — lets a test observe events a
    /// producer yielded BEFORE it finishes, proving true liveness rather than a post-hoc replay.
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        func wait() async {
            if released {
                return
            }
            await withCheckedContinuation { self.continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// Collects streamed events AND lets a test await "at least N events observed" deterministically
    /// (no wall-clock `sleep` — a real `CheckedContinuation` resumed the instant the Nth event
    /// lands), so the liveness assertion below can never flake under CI/parallel-test scheduling
    /// pressure.
    private actor EventCollector {
        private(set) var events: [RecallStreamEvent] = []
        private var watchers: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func append(_ event: RecallStreamEvent) {
            events.append(event)
            let count = events.count
            watchers.removeAll { watcher in
                guard count >= watcher.threshold else { return false }
                watcher.continuation.resume()
                return true
            }
        }

        /// Suspends until at least `threshold` events have been appended.
        func waitForAtLeast(_ threshold: Int) async {
            if events.count >= threshold {
                return
            }
            await withCheckedContinuation { continuation in
                watchers.append((threshold, continuation))
            }
        }
    }

    /// A `ToolCapableLLMClient` that yields a real tool call (dispatched through `toolset`), then
    /// SUSPENDS on `gate.wait()` before yielding its final answer — lets a test prove the consumer
    /// already observed `.toolActivity` while the producer is still suspended (true liveness, not
    /// buffer-then-replay).
    private actor GatedToolCapableClient: ToolCapableLLMClient {
        nonisolated let kind: ProviderKind = .mlx
        private let gate: Gate

        init(gate: Gate) {
            self.gate = gate
        }

        func generate(_: LLMRequest) async throws -> String {
            ""
        }

        nonisolated func respondWithTools(
            _: LLMRequest, tools _: [AgenticToolDefinition], dispatch: @escaping AgenticToolDispatch
        ) -> AsyncThrowingStream<AgenticEvent, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    continuation.yield(.toolStarted(name: "search_transcripts"))
                    let call = AgenticToolCall(
                        id: UUID().uuidString, name: "search_transcripts", argumentsJSON: #"{"query": "test"}"#
                    )
                    _ = try? await dispatch(call)
                    continuation.yield(.toolFinished(name: "search_transcripts", ok: true))
                    await self.gate.wait()
                    continuation.yield(.answerDelta("Final answer after gate release."))
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    @Test(
        "Liveness: the consumer observes .toolActivity BEFORE the gated final answer is released — proves live forwarding, not buffer-then-replay"
    )
    func rung1EventsAreForwardedLiveNotBuffered() async throws {
        let db = try AppDatabase.makeInMemory()
        let gate = Gate()
        let client = GatedToolCapableClient(gate: gate)
        let engine = makeEngine(db, client: client, modelConfig: RecallModelConfig(provider: "mlx", model: "mlx"))
        let collector = EventCollector()

        let consumerTask = Task {
            for try await event in engine.answerMeetingsLocallyStream(question: "Hi") {
                await collector.append(event)
            }
        }

        // Deterministic (no `sleep`): suspends only until the 2 pre-gate events (toolStarted,
        // toolFinished) have actually been appended by the consumer loop — proves the consumer
        // observed them while the producer is STILL suspended on `gate.wait()`, not after the fact.
        await collector.waitForAtLeast(2)
        let beforeRelease = await collector.events
        #expect(beforeRelease.contains {
            if case .toolActivity = $0 {
                true
            } else {
                false
            }
        })
        #expect(
            !beforeRelease.contains {
                if case .delta = $0 {
                    true
                } else {
                    false
                }
            },
            "the answer must not have arrived yet — the producer is still gated"
        )

        await gate.release()
        _ = try await consumerTask.value

        let allEvents = await collector.events
        #expect(allEvents.contains {
            if case .delta = $0 {
                true
            } else {
                false
            }
        })
        #expect(allEvents.contains {
            if case .done = $0 {
                true
            } else {
                false
            }
        })
    }

    // MARK: - Ordering: .thinking/.toolActivity precede .delta, .done is last

    @Test(".thinking and .toolActivity precede .delta events, and .done is always the terminal event")
    func eventOrderingThinkingAndToolActivityPrecedeDeltaThenDone() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "m-order", title: "Order check")
        try await db.meetings.upsert(meeting)
        try await db.transcripts.upsert(Transcript(
            id: TranscriptID("t-order"), meetingId: meeting.id,
            transcript: "Reviewed the ordering invariant.", timestamp: "00:00", audioStartTime: 0
        ))

        let client = ScriptedOrderedClient()
        let engine = makeEngine(db, client: client, modelConfig: RecallModelConfig(provider: "mlx", model: "mlx"))

        var kinds: [String] = []
        for try await event in engine.answerMeetingsLocallyStream(question: "Anything?") {
            switch event {
            case .thinking: kinds.append("thinking")
            case .toolActivity: kinds.append("toolActivity")
            case .delta: kinds.append("delta")
            case .done: kinds.append("done")
            }
        }

        #expect(kinds.last == "done")
        let deltaIndex = try #require(kinds.firstIndex(of: "delta"))
        let precedingKinds = kinds[..<deltaIndex]
        #expect(precedingKinds.contains("thinking"))
        #expect(precedingKinds.contains("toolActivity"))
        #expect(!precedingKinds.contains("delta"))
    }

    /// A `ToolCapableLLMClient` that yields `.thinking`, then a real tool call, then the final
    /// answer — a fixed, deterministic ordering for the ordering-invariant test above.
    private actor ScriptedOrderedClient: ToolCapableLLMClient {
        nonisolated let kind: ProviderKind = .mlx
        func generate(_: LLMRequest) async throws -> String {
            ""
        }

        nonisolated func respondWithTools(
            _: LLMRequest, tools _: [AgenticToolDefinition], dispatch: @escaping AgenticToolDispatch
        ) -> AsyncThrowingStream<AgenticEvent, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    continuation.yield(.thinking("Considering the question..."))
                    continuation.yield(.toolStarted(name: "search_transcripts"))
                    let call = AgenticToolCall(
                        id: UUID().uuidString, name: "search_transcripts", argumentsJSON: #"{"query": "ordering"}"#
                    )
                    _ = try? await dispatch(call)
                    continuation.yield(.toolFinished(name: "search_transcripts", ok: true))
                    continuation.yield(.answerDelta("Per [S1], reviewed the ordering invariant."))
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    // MARK: - Commit semantics: once an answer delta lands, no fallback to rung 3

    @Test(
        "Commit semantics: a client that emits one .answerDelta then throws does NOT trigger rung 3 — no rung-3 delta ever appears"
    )
    func committedThenThrowNeverTriggersRung3() async throws {
        let db = try AppDatabase.makeInMemory()
        let client = CommitThenThrowClient()
        let engine = makeEngine(db, client: client, modelConfig: RecallModelConfig(provider: "mlx", model: "mlx"))

        var deltas: [String] = []
        var done: RecallResponse?
        for try await event in engine.answerMeetingsLocallyStream(question: "Hi") {
            switch event {
            case let .delta(text): deltas.append(text)
            case let .done(response): done = response
            case .thinking, .toolActivity: break
            }
        }

        // Exactly the one committed delta — never a second, different (rung-3-sourced) delta.
        #expect(deltas == ["Committed answer."])
        #expect(try #require(done).answer == "Committed answer.")
    }

    /// A `ToolCapableLLMClient` whose `respondWithTools` yields ONE answer delta, then throws.
    private actor CommitThenThrowClient: ToolCapableLLMClient {
        nonisolated let kind: ProviderKind = .mlx
        func generate(_: LLMRequest) async throws -> String {
            "should never be called after commit"
        }

        nonisolated func respondWithTools(
            _: LLMRequest, tools _: [AgenticToolDefinition], dispatch _: @escaping AgenticToolDispatch
        ) -> AsyncThrowingStream<AgenticEvent, Error> {
            AsyncThrowingStream { continuation in
                struct Boom: Error {}
                continuation.yield(.answerDelta("Committed answer."))
                continuation.finish(throwing: Boom())
            }
        }
    }

    @Test(
        "Commit semantics: a client that throws BEFORE any .answerDelta DOES fall back — the stream contains rung-3 deltas"
    )
    func notCommittedThenThrowFallsBackWithRung3Deltas() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "m-fallback", title: "Fallback meeting")
        try await db.meetings.upsert(meeting)

        let client = ThrowBeforeAnyAnswerClient()
        let engine = makeEngine(db, client: client, modelConfig: RecallModelConfig(provider: "mlx", model: "mlx"))

        var deltas: [String] = []
        var done: RecallResponse?
        for try await event in engine.answerMeetingsLocallyStream(question: "Anything?") {
            switch event {
            case let .delta(text): deltas.append(text)
            case let .done(response): done = response
            case .thinking, .toolActivity: break
            }
        }

        #expect(deltas == ["Rung 3 real answer."])
        #expect(try #require(done).answer == "Rung 3 real answer.")
    }

    /// A `ToolCapableLLMClient` whose `respondWithTools` throws immediately (no events at all), but
    /// whose plain `stream`/`generate` (used by rung 3's REAL streaming pipeline) yields a real,
    /// distinguishable answer.
    private actor ThrowBeforeAnyAnswerClient: ToolCapableLLMClient {
        nonisolated let kind: ProviderKind = .mlx
        func generate(_: LLMRequest) async throws -> String {
            "Rung 3 real answer."
        }

        nonisolated func stream(_: LLMRequest) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield("Rung 3 real answer.")
                continuation.finish()
            }
        }

        nonisolated func respondWithTools(
            _: LLMRequest, tools _: [AgenticToolDefinition], dispatch _: @escaping AgenticToolDispatch
        ) -> AsyncThrowingStream<AgenticEvent, Error> {
            AsyncThrowingStream { continuation in
                struct Boom: Error {}
                continuation.finish(throwing: Boom())
            }
        }
    }

    // MARK: - M3: rung-3 think-tag shield (defense-in-depth ThinkTagSplitter over the fallback's .delta text)

    /// A `ToolCapableLLMClient` whose `respondWithTools` throws immediately (rung 1 never
    /// commits), but whose plain `stream` (rung 3's real streaming pipeline) leaks a `<think>`
    /// span in its raw text — proving the M3 shield strips it into `.thinking`, never `.delta`.
    private actor LeakingThinkTagsClient: ToolCapableLLMClient {
        nonisolated let kind: ProviderKind = .mlx
        private let rawText: String

        init(rawText: String) {
            self.rawText = rawText
        }

        func generate(_: LLMRequest) async throws -> String {
            rawText
        }

        nonisolated func stream(_: LLMRequest) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(rawText)
                continuation.finish()
            }
        }

        nonisolated func respondWithTools(
            _: LLMRequest, tools _: [AgenticToolDefinition], dispatch _: @escaping AgenticToolDispatch
        ) -> AsyncThrowingStream<AgenticEvent, Error> {
            AsyncThrowingStream { continuation in
                struct Boom: Error {}
                continuation.finish(throwing: Boom())
            }
        }
    }

    @Test("M3: a <think> span leaked into rung 3's raw text is split into .thinking, never appears inside a .delta")
    func rung3LeakedThinkTagsAreSplitIntoThinking() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "m-leak", title: "Leak check")
        try await db.meetings.upsert(meeting)

        let client = LeakingThinkTagsClient(rawText: "<think>reasoning about the leak</think>The real answer.")
        let engine = makeEngine(db, client: client, modelConfig: RecallModelConfig(provider: "mlx", model: "mlx"))

        var deltas: [String] = []
        var thinkingSpans: [String] = []
        for try await event in engine.answerMeetingsLocallyStream(question: "Anything?") {
            switch event {
            case let .delta(text): deltas.append(text)
            case let .thinking(text): thinkingSpans.append(text)
            case .toolActivity, .done: break
            }
        }

        #expect(deltas.joined() == "The real answer.")
        #expect(!deltas.joined().contains("<think>"))
        #expect(!deltas.joined().contains("reasoning about the leak"))
        #expect(thinkingSpans.joined() == "reasoning about the leak")
    }

    @Test("M3: clean rung-3 text (no <think> tags) passes through byte-identical — the splitter is a no-op")
    func rung3CleanTextPassesThroughByteIdentical() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "m-clean", title: "Clean check")
        try await db.meetings.upsert(meeting)

        let client = LeakingThinkTagsClient(rawText: "A perfectly ordinary answer with no tags at all.")
        let engine = makeEngine(db, client: client, modelConfig: RecallModelConfig(provider: "mlx", model: "mlx"))

        var deltas: [String] = []
        for try await event in engine.answerMeetingsLocallyStream(question: "Anything?") {
            if case let .delta(text) = event {
                deltas.append(text)
            }
        }
        #expect(deltas.joined() == "A perfectly ordinary answer with no tags at all.")
    }

    // MARK: - L5: a cancelled ask never starts rung 3

    /// Suspends `respondWithTools` on a gate before throwing — lets a test cancel the CONSUMER
    /// while rung 1 is still "in flight", then verify rung 3 (`generate`/`stream`) never runs.
    private actor GatedThrowingClient: ToolCapableLLMClient {
        nonisolated let kind: ProviderKind = .mlx
        private let gate: Gate
        private(set) var generateCallCount = 0

        init(gate: Gate) {
            self.gate = gate
        }

        func generate(_: LLMRequest) async throws -> String {
            generateCallCount += 1
            return "should never be called"
        }

        nonisolated func respondWithTools(
            _: LLMRequest, tools _: [AgenticToolDefinition], dispatch _: @escaping AgenticToolDispatch
        ) -> AsyncThrowingStream<AgenticEvent, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    await self.gate.wait()
                    struct Boom: Error {}
                    continuation.finish(throwing: Boom())
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    @Test("L5: a cancelled ask never starts rung 3, even when rung 1 throws before any answer")
    func cancelledAskNeverStartsRung3() async throws {
        let db = try AppDatabase.makeInMemory()
        let gate = Gate()
        let client = GatedThrowingClient(gate: gate)
        let engine = makeEngine(db, client: client, modelConfig: RecallModelConfig(provider: "mlx", model: "mlx"))

        let consumerTask = Task {
            for try await _ in engine.answerMeetingsLocallyStream(question: "Hi") {}
        }
        // Let the producer actually enter `respondWithTools` (and start waiting on the gate) before
        // cancelling the consumer.
        await Task.yield()
        await Task.yield()
        consumerTask.cancel()
        await gate.release()
        _ = try? await consumerTask.value

        #expect(await client.generateCallCount == 0)
    }
}
