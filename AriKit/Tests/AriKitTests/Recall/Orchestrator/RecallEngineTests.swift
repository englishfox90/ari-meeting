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

    // MARK: - 7. LLM-first: an empty retrieval still runs the model (retrieve-augment-always).

    // The model always answers — conversationally when nothing matched — instead of the old hard
    // `noSavedMatch` gate. Sources stay empty (DB-built), preserving never-invent-citations.

    @Test("A meeting with no transcript still runs the model with no sources (no hard gate)")
    func meetingScopedEmptyStillAnswers() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "empty-meeting")
        try await db.meetings.upsert(meeting)
        let client = RecordingLLMClient(cannedResponse: "I don't see a transcript for this meeting yet.")
        let engine = makeEngine(db, client: client)

        let response = try await engine.answerMeetingsLocally(question: "Anything?", meetingId: meeting.id)
        #expect(response.answer == "I don't see a transcript for this meeting yet.")
        #expect(response.sources.isEmpty)
        #expect(await client.generateCallCount == 1)
    }

    @Test("A series with no member meetings still runs the model with no sources")
    func seriesScopedEmptyStillAnswers() async throws {
        let db = try AppDatabase.makeInMemory()
        let series = Series(
            id: SeriesID("series-empty"),
            title: "Weekly sync",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await db.series.upsert(series)
        let client = RecordingLLMClient(cannedResponse: "Nothing saved in this series yet.")
        let engine = makeEngine(db, client: client)

        let response = try await engine.answerMeetingsLocally(question: "Anything?", seriesId: series.id)
        #expect(response.answer == "Nothing saved in this series yet.")
        #expect(response.sources.isEmpty)
        #expect(await client.generateCallCount == 1)
    }

    @Test("Global scope with nothing saved still runs the model (a greeting gets a reply)")
    func globalEmptyStillAnswers() async throws {
        let db = try AppDatabase.makeInMemory()
        let client = RecordingLLMClient(cannedResponse: "Hi! I couldn't find anything in your saved meetings.")
        let engine = makeEngine(db, client: client)

        let response = try await engine.answerMeetingsLocally(question: "Hi")
        #expect(response.answer == "Hi! I couldn't find anything in your saved meetings.")
        #expect(response.sources.isEmpty)
        #expect(await client.generateCallCount == 1)
    }

    @Test(
        "Regression (caught live 2026-07-23): the prompt always grounds \"today\" to the real current date, never left for the model to infer from a retrieved excerpt's date"
    )
    func promptAlwaysGroundsTodaysRealDate() async throws {
        let db = try AppDatabase.makeInMemory()
        let client = RecordingLLMClient(kind: .ollama, cannedResponse: "Noted.")
        let engine = makeEngine(db, client: client)

        _ = try await engine.answerMeetingsLocally(question: "Do I have a meeting today?")

        let prompt = try #require(await client.lastUserPrompt)
        #expect(prompt.hasPrefix("Today's date is "))
        let currentYear = Calendar.current.component(.year, from: Date())
        #expect(prompt.contains(String(currentYear)))
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

    // MARK: - 10. Slice B structured tools (`ask-meetings-tools-and-cards.md` §4/§8) — the single

    // most important guarantee: this addition can only ever ADD a card, never regress today's
    // behavior.

    @Test(
        "A global-scope ask matching a recognized entity shape with real, unambiguous data attaches a card and preserves the existing sources/citation guarantees"
    )
    func globalScopeResolvesUnambiguousPersonEntityAndAttachesCard() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = try await seedMeetingWithTranscripts(
            db,
            id: "meeting-sarah",
            title: "Budget review",
            segments: [(timestamp: "00:00", text: "We reviewed the Q3 budget with Sarah.", start: 0)]
        )
        let person = Person(
            id: PersonID("person-sarah"),
            email: "sarah@example.com",
            displayName: "Sarah Ammon",
            role: "PM",
            organization: "Arivo",
            isOwner: false,
            createdAt: meeting.createdAt,
            updatedAt: meeting.createdAt
        )
        try await db.persons.upsert(person)
        try await db.calendarEvents.upsert(CalendarEvent(
            id: CalendarEventID("event-sarah"),
            calendarId: "cal-1",
            title: "Budget review",
            startTime: meeting.createdAt,
            endTime: meeting.createdAt.addingTimeInterval(1800),
            isAllDay: false,
            attendees: [Attendee(name: "Sarah Ammon", email: "sarah@example.com")],
            meetingId: meeting.id,
            linkSource: .calendar
        ))

        let client = RecordingLLMClient(kind: .ollama, cannedResponse: "Per [S1], you last met Sarah for the budget.")
        let engine = makeEngine(db, client: client)

        let response = try await engine.answerMeetingsLocally(question: "meetings with Sarah")

        let card = try #require(response.card)
        guard case let .person(payload) = card else {
            Issue.record("expected a .person card")
            return
        }
        #expect(payload.personId == person.id.rawValue)
        #expect(payload.displayName == "Sarah Ammon")
        #expect(payload.meetingCount == 1)

        // Sources/citation reconciliation are UNCHANGED by this addition.
        #expect(response.answer.contains("[S1]"))
        #expect(response.sources.count == 1)
        #expect(response.sources.first?.meetingId == meeting.id.rawValue)
    }

    @Test(
        "Regression (caught live 2026-07-23): a trailing time word like \"today\" still resolves a person card"
    )
    func personLookupWithTrailingTimeWordStillResolves() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = try await seedMeetingWithTranscripts(
            db,
            id: "meeting-ryan",
            title: "Ryan 1:1",
            segments: [(timestamp: "00:00", text: "Good catchup with Ryan this morning.", start: 0)]
        )
        let person = Person(
            id: PersonID("person-ryan"),
            email: "ryan.chadwick@arivo.com",
            displayName: "Ryan Chadwick",
            isOwner: false,
            createdAt: meeting.createdAt,
            updatedAt: meeting.createdAt
        )
        try await db.persons.upsert(person)
        try await db.calendarEvents.upsert(CalendarEvent(
            id: CalendarEventID("event-ryan"),
            calendarId: "cal-1",
            title: "Ryan 1:1",
            startTime: meeting.createdAt,
            endTime: meeting.createdAt.addingTimeInterval(1800),
            isAllDay: false,
            attendees: [Attendee(name: "Ryan Chadwick", email: "ryan.chadwick@arivo.com")],
            meetingId: meeting.id,
            linkSource: .calendar
        ))

        let client = RecordingLLMClient(kind: .ollama, cannedResponse: "Yes, per [S1].")
        let engine = makeEngine(db, client: client)

        let response = try await engine.answerMeetingsLocally(question: "Do I have a meeting with Ryan today?")

        let card = try #require(response.card)
        guard case let .person(payload) = card else {
            Issue.record("expected a .person card")
            return
        }
        #expect(payload.personId == person.id.rawValue)
        #expect(payload.meetingCount == 1)
    }

    @Test(
        "Regression (caught live 2026-07-23): a resolved person's \"met today\" is stated outright in the prompt, not left for the model to infer by comparing two date strings"
    )
    func personCardContextLineStatesTodayOutright() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "meeting-landon-today", title: "Landon sync", createdAt: Date())
        try await db.meetings.upsert(meeting)
        try await db.transcripts.upsert(Transcript(
            id: TranscriptID("meeting-landon-today-t0"),
            meetingId: meeting.id,
            transcript: "Caught up with Landon.",
            timestamp: "00:00",
            audioStartTime: 0
        ))
        let person = Person(
            id: PersonID("person-landon"),
            email: "landon.starr@arivo.com",
            displayName: "Landon Starr",
            isOwner: false,
            createdAt: meeting.createdAt,
            updatedAt: meeting.createdAt
        )
        try await db.persons.upsert(person)
        try await db.calendarEvents.upsert(CalendarEvent(
            id: CalendarEventID("event-landon-today"),
            calendarId: "cal-1",
            title: "Landon sync",
            startTime: meeting.createdAt,
            endTime: meeting.createdAt.addingTimeInterval(1800),
            isAllDay: false,
            attendees: [Attendee(name: "Landon Starr", email: "landon.starr@arivo.com")],
            meetingId: meeting.id,
            linkSource: .calendar
        ))

        let client = RecordingLLMClient(kind: .ollama, cannedResponse: "Yes.")
        let engine = makeEngine(db, client: client)

        _ = try await engine.answerMeetingsLocally(question: "Do I have a meeting with Landon today?")

        let prompt = try #require(await client.lastUserPrompt)
        #expect(prompt.contains("(today)"))
    }

    @Test("A meeting-scoped ask with the same question text never attempts entity resolution (no card)")
    func meetingScopedAskNeverAttemptsEntityResolution() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = try await seedMeetingWithTranscripts(
            db,
            id: "meeting-scoped-sarah",
            title: "Budget review",
            segments: [(timestamp: "00:00", text: "We reviewed the Q3 budget with Sarah.", start: 0)]
        )
        try await db.persons.upsert(Person(
            id: PersonID("person-sarah"),
            email: "sarah@example.com",
            displayName: "Sarah Ammon",
            isOwner: false,
            createdAt: meeting.createdAt,
            updatedAt: meeting.createdAt
        ))

        let client = RecordingLLMClient(kind: .ollama, cannedResponse: "Fine.")
        let engine = makeEngine(db, client: client)

        let response = try await engine.answerMeetingsLocally(
            question: "meetings with Sarah",
            meetingId: meeting.id
        )
        #expect(response.card == nil)
    }

    @Test("An ambiguous name (two people match) resolves to card == nil, byte-identical to pre-Slice-B behavior")
    func ambiguousNameFallsThroughSafely() async throws {
        let db = try AppDatabase.makeInMemory()
        _ = try await seedMeetingWithTranscripts(
            db,
            id: "meeting-ambiguous",
            title: "Design sync",
            segments: [(timestamp: "00:00", text: "The design team discussed the roadmap.", start: 0)]
        )
        try await db.persons.upsert(Person(
            id: PersonID("sarah-1"),
            displayName: "Sarah Ammon",
            isOwner: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try await db.persons.upsert(Person(
            id: PersonID("sarah-2"),
            displayName: "Sarah Chen",
            isOwner: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        let client = RecordingLLMClient(kind: .ollama, cannedResponse: "I couldn't find anything specific.")
        let engine = makeEngine(db, client: client)

        let response = try await engine.answerMeetingsLocally(question: "meetings with Sarah")
        #expect(response.card == nil)
        #expect(response.answer == "I couldn't find anything specific.")
    }

    @Test("An unresolved name (zero matches) resolves to card == nil, byte-identical to pre-Slice-B behavior")
    func unresolvedNameFallsThroughSafely() async throws {
        let db = try AppDatabase.makeInMemory()
        _ = try await seedMeetingWithTranscripts(db)

        let client = RecordingLLMClient(kind: .ollama, cannedResponse: "I don't have anything on that.")
        let engine = makeEngine(db, client: client)

        let response = try await engine.answerMeetingsLocally(question: "meetings with Nobody")
        #expect(response.card == nil)
    }

    @Test("A question that never classifies as entity-shaped resolves to card == nil")
    func nonEntityQuestionNeverAttachesCard() async throws {
        let db = try AppDatabase.makeInMemory()
        _ = try await seedMeetingWithTranscripts(db)

        let client = RecordingLLMClient(kind: .ollama, cannedResponse: "We decided to keep it local.")
        let engine = makeEngine(db, client: client)

        let response = try await engine.answerMeetingsLocally(question: "What did we decide?")
        #expect(response.card == nil)
    }

    @Test("A resolved series entity attaches a .series card with real, bounded meeting counts")
    func globalScopeResolvesUnambiguousSeriesEntityAndAttachesCard() async throws {
        let db = try AppDatabase.makeInMemory()
        let series = Series(
            id: SeriesID("series-design"),
            title: "Design team sync",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await db.series.upsert(series)
        let meeting = try await seedMeetingWithTranscripts(
            db,
            id: "meeting-design-1",
            title: "Design sync #1",
            segments: [(timestamp: "00:00", text: "Reviewed the roadmap.", start: 0)]
        )
        try await db.series.addMember(seriesId: series.id, meetingId: meeting.id)

        let client = RecordingLLMClient(kind: .ollama, cannedResponse: "Noted.")
        let engine = makeEngine(db, client: client)

        let response = try await engine.answerMeetingsLocally(question: "meetings in the design team sync series")
        let card = try #require(response.card)
        guard case let .series(payload) = card else {
            Issue.record("expected a .series card")
            return
        }
        #expect(payload.seriesId == series.id.rawValue)
        #expect(payload.meetingCount == 1)
    }

    @Test("A global-scope ask matching a recognized meeting-lookup shape attaches a .meeting card")
    func globalScopeResolvesUnambiguousMeetingEntityAndAttachesCard() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = try await seedMeetingWithTranscripts(
            db,
            id: "meeting-budget",
            title: "Q3 budget planning",
            segments: [(timestamp: "00:00", text: "Reviewed the Q3 numbers.", start: 0)]
        )
        try await db.summaries.upsert(Summary(
            id: SummaryID("s-budget"),
            meetingId: meeting.id,
            bodyMarkdown: "Reviewed Q3 budget numbers.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        let client = RecordingLLMClient(kind: .ollama, cannedResponse: "Noted.")
        let engine = makeEngine(db, client: client)

        let response = try await engine.answerMeetingsLocally(
            question: "Did I have a meeting about Q3 budget planning?"
        )
        let card = try #require(response.card)
        guard case let .meeting(payload) = card else {
            Issue.record("expected a .meeting card")
            return
        }
        #expect(payload.meetingId == meeting.id.rawValue)
        #expect(payload.title == meeting.title)
        #expect(payload.hasSummary == true)
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

    // MARK: - 11. Calendar-aware lookup (2026-07-23 fix, ask-meetings-tools-and-cards.md follow-on)

    @Test(
        "A global-scope ask for a person with a REAL calendar event today but NO Person record yet attaches a .calendarEvent card, not a .person card, and states only the calendar fact"
    )
    func calendarEventTodayWithNoPersonRecordAttachesCalendarCard() async throws {
        let db = try AppDatabase.makeInMemory()
        let now = Date()
        try await db.calendarEvents.upsert(CalendarEvent(
            id: CalendarEventID("event-james"),
            calendarId: "cal-1",
            title: "James sync",
            startTime: now,
            endTime: now.addingTimeInterval(1800),
            isAllDay: false,
            attendees: [Attendee(name: "James Nance", email: "james@example.com")]
        ))

        let client = RecordingLLMClient(kind: .ollama, cannedResponse: "Yes.")
        let engine = makeEngine(db, client: client)

        let response = try await engine.answerMeetingsLocally(
            question: "Do I have a meeting with James Nance today?"
        )

        let card = try #require(response.card)
        guard case let .calendarEvent(payload) = card else {
            Issue.record("expected a .calendarEvent card")
            return
        }
        #expect(payload.eventId == "event-james")
        #expect(payload.isLinkedToRecordedMeeting == false)

        let prompt = try #require(await client.lastUserPrompt)
        #expect(prompt.contains("Calendar:"))
        #expect(prompt.contains("James sync"))
        // No recorded-meetings language — no Person record exists, so nothing to state about it.
        #expect(!prompt.contains("Recorded meetings:"))
    }

    @Test(
        "A global-scope ask for a person with BOTH a calendar event today AND recorded-meeting history attaches the .calendarEvent card, and the context line clearly separates both real facts"
    )
    func calendarEventTodayAndPersonHistoryBothStatedSeparately() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = try await seedMeetingWithTranscripts(
            db,
            id: "meeting-james-past",
            title: "Prior James sync",
            segments: [(timestamp: "00:00", text: "Caught up with James last time.", start: 0)]
        )
        let person = Person(
            id: PersonID("person-james"),
            email: "james@example.com",
            displayName: "James Nance",
            isOwner: false,
            createdAt: meeting.createdAt,
            updatedAt: meeting.createdAt
        )
        try await db.persons.upsert(person)
        try await db.calendarEvents.upsert(CalendarEvent(
            id: CalendarEventID("event-james-past"),
            calendarId: "cal-1",
            title: "Prior James sync",
            startTime: meeting.createdAt,
            endTime: meeting.createdAt.addingTimeInterval(1800),
            isAllDay: false,
            attendees: [Attendee(name: "James Nance", email: "james@example.com")],
            meetingId: meeting.id,
            linkSource: .calendar
        ))

        let now = Date()
        try await db.calendarEvents.upsert(CalendarEvent(
            id: CalendarEventID("event-james-today"),
            calendarId: "cal-1",
            title: "James sync today",
            startTime: now,
            endTime: now.addingTimeInterval(1800),
            isAllDay: false,
            attendees: [Attendee(name: "James Nance", email: "james@example.com")]
        ))

        let client = RecordingLLMClient(kind: .ollama, cannedResponse: "Yes.")
        let engine = makeEngine(db, client: client)

        let response = try await engine.answerMeetingsLocally(
            question: "Do I have a meeting with James Nance today?"
        )

        let card = try #require(response.card)
        guard case let .calendarEvent(payload) = card else {
            Issue.record("expected a .calendarEvent card (calendar precedence over the .person card)")
            return
        }
        #expect(payload.eventId == "event-james-today")

        let prompt = try #require(await client.lastUserPrompt)
        #expect(prompt.contains("Calendar:"))
        #expect(prompt.contains("James sync today"))
        #expect(prompt.contains("Recorded meetings:"))
        #expect(prompt.contains("1 meeting(s) involving James Nance"))
    }

    // MARK: - 12. Resolved-fact priority over RAG excerpts (2026-07-23 fix)

    @Test(
        "The system prompt instructs the model to trust a Resolved:/Calendar: fact over a conflicting retrieved excerpt"
    )
    func systemPromptStatesResolvedFactPriorityOverExcerpts() {
        let prompt = Recall.systemPrompt(isMeetingScoped: false)
        #expect(prompt.contains("\"Resolved:\""))
        #expect(prompt.contains("verified ground truth"))
        #expect(prompt.lowercased().contains("trust it over"))
    }

    @Test(
        "Regression (caught live 2026-07-23): a large attendee roster never buries or truncates the queried person's presence out of the prompt"
    )
    func calendarFactNeverLosesQueriedPersonInALargeRoster() async throws {
        let db = try AppDatabase.makeInMemory()
        let now = Date()
        // 16 attendees, matching the real live-caught fixture — the queried person (Landon Starr)
        // sits 7th, exactly where the OLD full-roster-dump implementation got truncated by
        // `RecallBounds.maxCardContextChars` (240) mid-word, right before his name.
        let attendees = [
            "charles.king@arivo.com", "amy.teuscher@arivo.com", "andrew.hall@arivo.com",
            "shaun.tilley@arivo.com", "wes.curtis@arivo.com", "pieter.vanispelen@arivo.com",
            "landon.starr@arivo.com", "jj.garff@arivo.com", "joonas.tahvanainen@arivo.com",
            "james.nance@arivo.com", "lindsey.tsuya@arivo.com", "paul.foxreeks@arivo.com",
            "matthew.thomas@arivo.com", "rachelg@arivo.com", "mike.gustafson@arivo.com",
            "another.attendee@arivo.com"
        ].map { Attendee(name: $0, email: $0) }
        try await db.calendarEvents.upsert(CalendarEvent(
            id: CalendarEventID("event-exec"),
            calendarId: "cal-1",
            title: "Arivo Executive Meeting",
            startTime: now,
            endTime: now.addingTimeInterval(1800),
            isAllDay: false,
            attendees: attendees
        ))

        let client = RecordingLLMClient(kind: .ollama, cannedResponse: "Yes.")
        let engine = makeEngine(db, client: client)

        let response = try await engine.answerMeetingsLocally(
            question: "Do I have a meeting with Landon today?"
        )

        #expect(response.card != nil)
        let prompt = try #require(await client.lastUserPrompt)
        // The full email, unbroken and un-truncated — never a mid-word cut like "landon.star".
        #expect(prompt.contains("landon.starr@arivo.com"))
        #expect(prompt.contains("16 attendee"))
    }

    @Test(
        "Reviewer-caught gap (2026-07-23): a calendar event already linked to a recorded meeting states that fact directly, even with no Person record"
    )
    func calendarEventLinkedToRecordedMeetingStatesSoInThePrompt() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = try await seedMeetingWithTranscripts(
            db,
            id: "meeting-linked",
            title: "Linked sync",
            segments: [(timestamp: "00:00", text: "Discussed the roadmap.", start: 0)]
        )
        let now = Date()
        try await db.calendarEvents.upsert(CalendarEvent(
            id: CalendarEventID("event-linked"),
            calendarId: "cal-1",
            title: "Linked sync",
            startTime: now,
            endTime: now.addingTimeInterval(1800),
            isAllDay: false,
            attendees: [Attendee(name: "Nia Ward", email: "nia@example.com")],
            meetingId: meeting.id,
            linkSource: .calendar
        ))

        let client = RecordingLLMClient(kind: .ollama, cannedResponse: "Yes.")
        let engine = makeEngine(db, client: client)

        let response = try await engine.answerMeetingsLocally(
            question: "Do I have a meeting with Nia today?"
        )

        let card = try #require(response.card)
        guard case let .calendarEvent(payload) = card else {
            Issue.record("expected a .calendarEvent card")
            return
        }
        #expect(payload.isLinkedToRecordedMeeting == true)

        let prompt = try #require(await client.lastUserPrompt)
        #expect(prompt.contains("recorded meeting"))
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
