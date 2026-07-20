//
//  RecallEngineTests.swift — plan §6 `RecallEngineTests` (Recall Slice 8, ← `shell.rs`/`stream.rs`).
//
//  Built on `AppDatabase.makeInMemory()` + real repositories (never a raw SQLite handle), a
//  `StubRecallSettingsReading`/`StubRecallSecretsReading` pair, and a hand-rolled `RecordingLLMClient`
//  that captures the exact prompt handed to it and returns a scripted answer — the same pattern
//  `SummaryGeneratorTests` uses for `SummaryGenerator`. No real network, MLX, or Store second-owner
//  ever appears.
//
import Foundation
import Testing
@testable import AriKit

@Suite("RecallEngine (Ask Meetings orchestrator) — Recall Slice 8")
struct RecallEngineTests {

    // MARK: - Fixtures

    private func makeMeeting(
        id: String,
        title: String = "Fixture meeting",
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Meeting {
        Meeting(id: MeetingID(id), title: title, createdAt: createdAt, updatedAt: createdAt)
    }

    /// The semantic arm is never exercised in these tests (nothing is ever indexed via
    /// `recallIndex.replaceMeetingChunks`), so a throwing embedder is enough — `HybridSearch`
    /// degrades to its keyword-`LIKE` fallback, exactly like `HybridSearchTests`' own fixture.
    private struct UnavailableEmbedder: RecallEmbedder {
        struct Unavailable: Error {}
        let modelTag = "unavailable"
        func embed(_: [String]) async throws -> [[Float]] {
            throw Unavailable()
        }
    }

    private func makeEngine(
        _ db: AppDatabase,
        client: any LLMClient,
        modelConfig: RecallModelConfig? = RecallModelConfig(provider: "ollama", model: "llama3"),
        apiKeys: [String: String] = [:]
    ) -> RecallEngine {
        RecallEngine(
            db: db,
            hybridSearch: HybridSearch(
                recallIndex: db.recallIndex,
                meetings: db.meetings,
                summaries: db.summaries,
                transcripts: db.transcripts,
                embedder: UnavailableEmbedder()
            ),
            peopleContext: PeopleContext(
                persons: db.persons,
                profileFacts: db.profileFacts,
                calendarEvents: db.calendarEvents
            ),
            settings: StubRecallSettingsReading(config: modelConfig),
            secrets: StubRecallSecretsReading(apiKeys: apiKeys),
            clientFactory: { _ in client }
        )
    }

    private func seedMeetingWithTranscripts(
        _ db: AppDatabase,
        id: String = "meeting-1",
        title: String = "AI review",
        segments: [(timestamp: String, text: String, start: Double)] = [
            (timestamp: "00:05", text: "Alice opened the review.", start: 5),
            (timestamp: "00:30", text: "We decided to keep recall local.", start: 30)
        ]
    ) async throws -> Meeting {
        let meeting = makeMeeting(id: id, title: title)
        try await db.meetings.upsert(meeting)
        for (index, segment) in segments.enumerated() {
            try await db.transcripts.upsert(Transcript(
                id: TranscriptID("\(id)-t\(index)"),
                meetingId: meeting.id,
                transcript: segment.text,
                timestamp: segment.timestamp,
                audioStartTime: segment.start
            ))
        }
        return meeting
    }

    // MARK: - 1. Meeting-scoped: citations verified, in-range @ref kept

    @Test(
        "Meeting-scoped: an invented [S<n>] is dropped, a valid one kept, in-range @ref survives as a play-badge, out-of-range @ref is demoted to plain text"
    )
    func meetingScopedVerifiesCitationsAndScopesRefTimestamps() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = try await seedMeetingWithTranscripts(db)

        let client = RecordingLLMClient(
            kind: .ollama,
            cannedResponse: "Per [S1] and an invented [S9], the team decided this. See @ref(00:05) and also @ref(05:00)."
        )
        let engine = makeEngine(db, client: client)

        let response = try await engine.answerMeetingsLocally(
            question: "What did we decide?",
            meetingId: meeting.id
        )

        #expect(response.answer.contains("[S1]"))
        #expect(!response.answer.contains("[S9]"))
        // In-range (00:05 <= max source timestamp 00:30 + 2s tolerance): kept as a play-badge.
        #expect(response.answer.contains("@ref(00:05)"))
        // Out-of-range (05:00 = 300s, far past the 30s+2 ceiling): demoted to bare, readable text.
        #expect(!response.answer.contains("@ref(05:00)"))
        #expect(response.answer.contains("05:00"))

        // Sources are the REAL DB-built sources — never anything the model "cited".
        #expect(response.sources.count == 2)
        #expect(response.sources.allSatisfy { $0.meetingId == meeting.id.rawValue })
    }

    // MARK: - 2. Global scope: ALL @ref stripped (ambiguous across meetings), never trusts model citations

    @Test("Global scope strips every @ref timestamp and still drops an out-of-range [S<n>]")
    func globalScopeStripsAllRefTimestamps() async throws {
        let db = try AppDatabase.makeInMemory()
        _ = try await seedMeetingWithTranscripts(
            db,
            id: "meeting-global",
            title: "Global review",
            segments: [(timestamp: "00:10", text: "The rollout timeline was finalized here.", start: 10)]
        )

        let client = RecordingLLMClient(
            kind: .ollama,
            cannedResponse: "As shown in [S1] (and the invented [S7]), see @ref(00:10) for detail."
        )
        let engine = makeEngine(db, client: client)

        let response = try await engine.answerMeetingsLocally(question: "What was finalized about the rollout?")

        #expect(response.answer.contains("[S1]"))
        #expect(!response.answer.contains("[S7]"))
        // Global scope: @ref is always stripped — a bare MM:SS is ambiguous across meetings.
        #expect(!response.answer.contains("@ref("))
        #expect(response.answer.contains("00:10"))
        #expect(response.sources.count == 1)
    }

    // MARK: - 3. Sources are built independently of whatever the model says

    @Test("Sources are computed from the DB BEFORE generation and are unaffected by the model's own text")
    func sourcesAreIndependentOfModelOutput() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = try await seedMeetingWithTranscripts(db)

        // The model's answer references nothing real about the meeting at all — sources must
        // still be exactly what the DB-driven shell built, not anything derived from this text.
        let client = RecordingLLMClient(kind: .ollama, cannedResponse: "I have no information to add.")
        let engine = makeEngine(db, client: client)

        let response = try await engine.answerMeetingsLocally(question: "Anything?", meetingId: meeting.id)

        #expect(response.sources.count == 2)
        #expect(response.sources.map(\.matchContext).contains("Alice opened the review."))
        #expect(response.sources.map(\.matchContext).contains("We decided to keep recall local."))
    }

    // MARK: - 4. Loopback gate — the load-bearing invariant, end to end

    @Test("A configured Ollama endpoint that is not on this device rejects the whole ask with .loopbackViolation")
    func loopbackGateRejectsNonLoopbackOllamaEndToEnd() async throws {
        let db = try AppDatabase.makeInMemory()
        _ = try await seedMeetingWithTranscripts(db)

        let client = RecordingLLMClient(kind: .ollama, cannedResponse: "should never be reached")
        let engine = makeEngine(
            db,
            client: client,
            modelConfig: RecallModelConfig(
                provider: "ollama",
                model: "llama3",
                ollamaEndpoint: "https://ollama.example.com"
            )
        )

        await #expect(throws: RecallEngineError.loopbackViolation) {
            _ = try await engine.answerMeetingsLocally(question: "What did we decide?")
        }
        let calls = await client.generateCallCount
        #expect(calls == 0, "the model must never be called once the loopback gate rejects the config")
    }

    @Test("A loopback (default/localhost) Ollama endpoint is allowed through")
    func loopbackOllamaEndpointIsAllowed() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = try await seedMeetingWithTranscripts(db)
        let client = RecordingLLMClient(kind: .ollama, cannedResponse: "Fine.")
        let engine = makeEngine(
            db,
            client: client,
            modelConfig: RecallModelConfig(
                provider: "ollama",
                model: "llama3",
                ollamaEndpoint: "http://localhost:11434"
            )
        )

        let response = try await engine.answerMeetingsLocally(question: "What did we decide?", meetingId: meeting.id)
        #expect(response.answer == "Fine.")
    }

    // MARK: - 5. Question validation (← `shell.rs:279-288`)

    @Test("Empty question throws .emptyQuestion")
    func emptyQuestionThrows() async throws {
        let db = try AppDatabase.makeInMemory()
        let engine = makeEngine(db, client: RecordingLLMClient(cannedResponse: "n/a"))
        await #expect(throws: RecallEngineError.emptyQuestion) {
            _ = try await engine.answerMeetingsLocally(question: "   ")
        }
    }

    @Test("A question over 1,000 characters throws .questionTooLong")
    func questionTooLongThrows() async throws {
        let db = try AppDatabase.makeInMemory()
        let engine = makeEngine(db, client: RecordingLLMClient(cannedResponse: "n/a"))
        let longQuestion = String(repeating: "a", count: 1001)
        await #expect(throws: RecallEngineError.questionTooLong) {
            _ = try await engine.answerMeetingsLocally(question: longQuestion)
        }
    }

    @Test("An out-of-scope question (internet/email/etc.) throws .unsupportedQuestion")
    func unsupportedQuestionThrows() async throws {
        let db = try AppDatabase.makeInMemory()
        let engine = makeEngine(db, client: RecordingLLMClient(cannedResponse: "n/a"))
        await #expect(throws: RecallEngineError.unsupportedQuestion) {
            _ = try await engine.answerMeetingsLocally(question: "Search the internet for this")
        }
    }

    // MARK: - 6. Model configuration gates (← `shell.rs:293-309`)

    @Test("No configured model throws .modelNotConfigured")
    func noModelConfiguredThrows() async throws {
        let db = try AppDatabase.makeInMemory()
        let engine = makeEngine(db, client: RecordingLLMClient(cannedResponse: "n/a"), modelConfig: nil)
        do {
            _ = try await engine.answerMeetingsLocally(question: "What did we decide?")
            Issue.record("expected .modelNotConfigured")
        } catch let RecallEngineError.modelNotConfigured(message) {
            #expect(message == "Configure Built-in AI or Ollama before asking meetings.")
        }
    }

    @Test("An unparseable provider throws .modelNotConfigured with the settings-page message")
    func unparseableProviderThrows() async throws {
        let db = try AppDatabase.makeInMemory()
        let engine = makeEngine(
            db,
            client: RecordingLLMClient(cannedResponse: "n/a"),
            modelConfig: RecallModelConfig(provider: "not-a-real-provider", model: "x")
        )
        do {
            _ = try await engine.answerMeetingsLocally(question: "What did we decide?")
            Issue.record("expected .modelNotConfigured")
        } catch let RecallEngineError.modelNotConfigured(message) {
            #expect(message == "Configure a summary model in Settings before asking meetings.")
        }
    }

    @Test("An empty model name throws .modelNotConfigured with the 'choose a summary model' message")
    func emptyModelNameThrows() async throws {
        let db = try AppDatabase.makeInMemory()
        let engine = makeEngine(
            db,
            client: RecordingLLMClient(cannedResponse: "n/a"),
            modelConfig: RecallModelConfig(provider: "ollama", model: "   ")
        )
        do {
            _ = try await engine.answerMeetingsLocally(question: "What did we decide?")
            Issue.record("expected .modelNotConfigured")
        } catch let RecallEngineError.modelNotConfigured(message) {
            #expect(message == "Choose a summary model in Settings before asking meetings.")
        }
    }

    // MARK: - 7. No-match messages, scoped by meeting / series / global (← `shell.rs:389-395`)

    @Test("A meeting with no transcript or summary throws the meeting-scoped no-match message")
    func meetingScopedNoMatchThrows() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "empty-meeting")
        try await db.meetings.upsert(meeting)
        let engine = makeEngine(db, client: RecordingLLMClient(cannedResponse: "n/a"))

        do {
            _ = try await engine.answerMeetingsLocally(question: "Anything?", meetingId: meeting.id)
            Issue.record("expected .noSavedMatch")
        } catch let RecallEngineError.noSavedMatch(message) {
            #expect(message.contains("This meeting has no saved transcript"))
        }
    }

    @Test("A series with no member meetings throws the series-scoped no-match message")
    func seriesScopedNoMatchThrows() async throws {
        let db = try AppDatabase.makeInMemory()
        let series = Series(
            id: SeriesID("series-empty"),
            title: "Weekly sync",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await db.series.upsert(series)
        let engine = makeEngine(db, client: RecordingLLMClient(cannedResponse: "n/a"))

        do {
            _ = try await engine.answerMeetingsLocally(question: "Anything?", seriesId: series.id)
            Issue.record("expected .noSavedMatch")
        } catch let RecallEngineError.noSavedMatch(message) {
            #expect(message == "No saved local transcript in this series matched that question.")
        }
    }

    @Test("Global scope with nothing saved anywhere throws the global no-match message")
    func globalNoMatchThrows() async throws {
        let db = try AppDatabase.makeInMemory()
        let engine = makeEngine(db, client: RecordingLLMClient(cannedResponse: "n/a"))

        do {
            _ = try await engine.answerMeetingsLocally(question: "Anything at all?")
            Issue.record("expected .noSavedMatch")
        } catch let RecallEngineError.noSavedMatch(message) {
            #expect(message == "No saved local transcript matched that question.")
        }
    }

    // MARK: - 8. Series ledger injection (precedence: meeting > series > global, ← `shell.rs:350-364`)

    @Test("A series ledger is prepended to the prompt for a series-scoped ask")
    func seriesLedgerIsInjectedForSeriesScopedAsk() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = try await seedMeetingWithTranscripts(
            db,
            id: "series-member-1",
            title: "Sprint sync",
            segments: [(timestamp: "00:00", text: "Reviewed last week's open items.", start: 0)]
        )
        let series = Series(
            id: SeriesID("series-1"),
            title: "Sprint sync series",
            ledgerMarkdown: "- Open item: ship the recall orchestrator.",
            ledgerVersion: 1,
            createdAt: meeting.createdAt,
            updatedAt: meeting.createdAt
        )
        try await db.series.upsert(series)
        try await db.series.addMember(seriesId: series.id, meetingId: meeting.id)
        // The scoped search path NEVER falls back to the keyword-`LIKE` search (unlike the
        // unscoped path) — it must find a real indexed chunk, so seed one (← `HybridSearchTests`'
        // own scoped fixtures use the same seeding).
        try await db.recallIndex.replaceMeetingChunks(
            meetingId: meeting.id,
            chunks: [
                RecallChunkInput(
                    id: RecallChunkID("series-chunk-1"),
                    chunkIndex: 0,
                    chunkText: "Reviewed last week's open items."
                )
            ],
            contentHash: "hash-series-1",
            embeddingModel: nil,
            now: "2026-07-20T00:00:00Z"
        )

        let client = RecordingLLMClient(kind: .ollama, cannedResponse: "Noted.")
        let engine = makeEngine(db, client: client)

        _ = try await engine.answerMeetingsLocally(question: "open items", seriesId: series.id)

        let prompt = await client.lastUserPrompt
        #expect(prompt?.contains("### Series ledger (running context for this series)") == true)
        #expect(prompt?.contains("ship the recall orchestrator") == true)
    }

    // MARK: - 9. Streaming (← `stream.rs`)

    @Test(
        "Streaming yields deltas, then a terminal .done carrying the citation-reconciled answer and the separately-built sources"
    )
    func streamingYieldsDeltasThenReconciledDone() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = try await seedMeetingWithTranscripts(db)

        let client = RecordingLLMClient(
            kind: .ollama,
            cannedResponse: "unused-in-streaming",
            cannedDeltas: ["Per [S1], ", "and the invented [S9], ", "we decided this."]
        )
        let engine = makeEngine(db, client: client)

        var deltas: [String] = []
        var done: RecallResponse?
        for try await event in engine.answerMeetingsLocallyStream(
            question: "What did we decide?",
            meetingId: meeting.id
        ) {
            switch event {
            case let .delta(text):
                deltas.append(text)
            case let .done(response):
                #expect(done == nil, "exactly one terminal .done event")
                done = response
            }
        }

        #expect(deltas == ["Per [S1], ", "and the invented [S9], ", "we decided this."])
        let response = try #require(done)
        // The terminal `.done` answer is the FULL accumulated text (all three deltas joined),
        // reconciled ONCE — never a delta re-verified in isolation.
        #expect(response.answer.contains("[S1]"))
        #expect(!response.answer.contains("[S9]"))
        #expect(response.answer.hasPrefix("Per [S1], and the invented"))
        #expect(response.answer.hasSuffix("we decided this."))
        #expect(response.sources.count == 2)
    }

    @Test("Streaming honors the loopback gate too — no deltas, an error, before any generation")
    func streamingHonorsLoopbackGate() async throws {
        let db = try AppDatabase.makeInMemory()
        _ = try await seedMeetingWithTranscripts(db)

        let client = RecordingLLMClient(kind: .ollama, cannedResponse: "should never run")
        let engine = makeEngine(
            db,
            client: client,
            modelConfig: RecallModelConfig(
                provider: "ollama",
                model: "llama3",
                ollamaEndpoint: "https://ollama.example.com"
            )
        )

        var sawError = false
        do {
            for try await _ in engine.answerMeetingsLocallyStream(question: "What did we decide?") {
                Issue.record("no event should be yielded before the loopback gate throws")
            }
        } catch is RecallEngineError {
            sawError = true
        }
        #expect(sawError)
        let calls = await client.generateCallCount
        #expect(calls == 0)
    }
}

// MARK: - Test double

/// Captures the exact `LLMRequest` handed to it and returns a scripted response — mirrors
/// `SummaryGeneratorTests`' private `RecordingStubClient`, extended with a scripted `stream(_:)`
/// so streaming tests can assert delta-by-delta behavior (not just the single-shot fallback).
private actor RecordingLLMClient: LLMClient {
    nonisolated let kind: ProviderKind
    private let cannedResponse: String
    private let cannedDeltas: [String]?
    private(set) var generateCallCount = 0
    private(set) var lastSystemPrompt: String?
    private(set) var lastUserPrompt: String?

    init(kind: ProviderKind = .ollama, cannedResponse: String, cannedDeltas: [String]? = nil) {
        self.kind = kind
        self.cannedResponse = cannedResponse
        self.cannedDeltas = cannedDeltas
    }

    func generate(_ request: LLMRequest) async throws -> String {
        generateCallCount += 1
        lastSystemPrompt = request.system
        lastUserPrompt = request.user
        return cannedResponse
    }

    private func recordPrompt(_ request: LLMRequest) {
        lastSystemPrompt = request.system
        lastUserPrompt = request.user
    }

    nonisolated func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await recordPrompt(request)
                for delta in cannedDeltas ?? [cannedResponse] {
                    continuation.yield(delta)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
