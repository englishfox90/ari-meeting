//
//  RecallEngine.swift — the "Ask Meetings" orchestrator (plan §5 Slice 8, ← `ari-engine/src/
//  recall/shell.rs::api_answer_meetings_locally_impl`).
//
//  Ties together everything the earlier slices built: `HybridSearch` (global/scoped retrieval,
//  Slice 4) → the pure shell (`Recall.build*Sources`/`buildContext`/`systemPrompt`, Slice 1) →
//  `PeopleContext` (Slice 7) → an `LLMClient` (Engine Phase 3.4) → the pure citation verifiers
//  (`Recall.verifySourceCitations`/`filterRefTimestamps`, Slice 1). Scope precedence is
//  **meeting > series > global** (← `shell.rs:350-352`), matching the Rust source exactly.
//
//  NOT ported here: the Claude-only agentic tool-use loop (← `recall/agent.rs`,
//  `answer_agentic`), which `shell.rs:324-348` tries FIRST (global scope + Claude + a real API
//  key) and falls through from on any error. Per the task's scope, this is explicitly DEFERRED —
//  see `// TODO(follow-on)` below. Its absence means: this port always takes the single-shot path
//  the Rust source falls back to, even when a Claude key is configured. Behaviorally this is a
//  strict subset (never worse, just less agentic reach for global Claude asks) — the safety shell
//  (bounds/citations/loopback) is identical either way.
//
//  Invariants preserved (plan §7 — tested in `RecallEngineTests`):
//    - Loopback-only: an Ollama provider whose endpoint isn't on this device throws before any
//      network call is attempted (← `shell.rs:302-306`).
//    - Bounded context: sources/context/history all run through the Slice-1 bounding helpers.
//    - Never invents citations: `sources` is built from the DB BEFORE the model ever runs, and the
//      model's answer is verified against `sources.count` — never parsed back for citations.
//    - `@ref` scope: meeting-scoped keeps in-range refs; series/global strip them all.
//
import Foundation

/// Errors surfaced directly by the orchestrator (mirrors the `Err(String)` returns of
/// `api_answer_meetings_locally_impl`, `shell.rs:279-395`, as distinct, matchable cases rather
/// than ad hoc strings). `errorDescription` carries the exact frozen Rust message so callers that
/// surface it verbatim (the UI) see identical copy.
public enum RecallEngineError: Error, Sendable, Equatable {
    case emptyQuestion
    case questionTooLong
    case unsupportedQuestion
    /// ← "Configure Built-in AI or Ollama…" / "Configure a summary model…" / "Choose a summary
    /// model…" (`shell.rs:296,301,308`) — three distinct Rust messages, one case, real message.
    case modelNotConfigured(String)
    /// ← the loopback-only gate (`shell.rs:302-306`).
    case loopbackViolation
    /// ← the three "no saved transcript matched" messages, scoped by meeting/series/global
    /// (`shell.rs:389-395`).
    case noSavedMatch(String)
    /// ← "The local model could not answer from your saved meetings: {error}" (`shell.rs:452-454`
    /// / `stream.rs:224`).
    case generationFailed(String)
}

extension RecallEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyQuestion:
            "Enter a question about your saved meetings."
        case .questionTooLong:
            "Questions must be 1,000 characters or fewer."
        case .unsupportedQuestion:
            "Ask Meetings can answer only from saved local Ari Meeting transcripts, plus real calendar scheduling facts (event times and attendees) when supplied — a calendar entry means something is scheduled, never that it was recorded or discussed. It cannot access email, accounts, internet search, or files outside Ari Meeting."
        case let .modelNotConfigured(message):
            message
        case .loopbackViolation:
            "Ask Meetings only permits an Ollama server on this device. Use localhost in Settings to continue."
        case let .noSavedMatch(message):
            message
        case let .generationFailed(message):
            message
        }
    }
}

/// The Ask-Meetings orchestrator. `Sendable` value type over injected repository/search/settings
/// handles + an `LLMClient` factory — mirrors `HybridSearch`/`SummaryService`'s shape.
public struct RecallEngine: Sendable {
    // `internal` (not `private`) so the streaming extension in `RecallStream.swift` — a separate
    // file, same module — can reach them; both stay invisible outside `AriKit` either way (no
    // `public` surface leak).
    let db: AppDatabase
    let hybridSearch: HybridSearch
    let peopleContext: PeopleContext
    let settings: any RecallSettingsReading
    let secrets: any RecallSecretsReading
    let clientFactory: @Sendable (ProviderConfig) throws -> any LLMClient

    public init(
        db: AppDatabase,
        hybridSearch: HybridSearch,
        peopleContext: PeopleContext,
        settings: any RecallSettingsReading,
        secrets: any RecallSecretsReading,
        clientFactory: @escaping @Sendable (ProviderConfig) throws -> any LLMClient = {
            try ProviderFactory.make(config: $0)
        }
    ) {
        self.db = db
        self.hybridSearch = hybridSearch
        self.peopleContext = peopleContext
        self.settings = settings
        self.secrets = secrets
        self.clientFactory = clientFactory
    }

    // MARK: - Single-shot (← `api_answer_meetings_locally_impl`, `shell.rs:272-472`)

    public func answerMeetingsLocally(
        question: String,
        meetingId: MeetingID? = nil,
        seriesId: SeriesID? = nil,
        history: [RecallTurn] = []
    ) async throws -> RecallResponse {
        let prepared = try await prepare(
            question: question,
            meetingId: meetingId,
            seriesId: seriesId,
            history: history
        )

        let client = try clientFactory(prepared.config)
        let answer: String
        do {
            answer = try await client.generate(
                LLMRequest(system: prepared.systemPrompt, user: prepared.userPrompt)
            )
        } catch {
            throw RecallEngineError.generationFailed(
                "The local model could not answer from your saved meetings: \(error)"
            )
        }

        let reconciled = Self.reconcile(
            answer: answer,
            sources: prepared.sources,
            isMeetingScoped: prepared.isMeetingScoped
        )
        return RecallResponse(answer: reconciled, sources: prepared.sources, card: prepared.card)
    }

    // TODO(follow-on): port `recall/agent.rs`'s Claude-only agentic tool-use loop
    // (`answer_agentic`) — global scope + Claude + a real API key, ≤8 iterations, `MAX_SOURCES=24`,
    // `MAX_TRANSCRIPT_CHARS=8_000` (plan §7 "Bounded context"). Deferred per this slice's scope;
    // `answerMeetingsLocally`/`answerMeetingsLocallyStream` always take the single-shot/streaming
    // path Rust falls back to on any agentic error.

    // MARK: - Shared preparation (single-shot + streaming, ← the identical prefix of `shell.rs`

    // and `stream.rs`)

    struct PreparedRequest {
        var systemPrompt: String
        var userPrompt: String
        var sources: [RecallSource]
        var isMeetingScoped: Bool
        var config: ProviderConfig
        var card: RecallCardPayload?
    }

    /// `RecallTools` over this engine's own repository handles (plan §4.2) — built fresh per call
    /// rather than stored, mirroring how `hybridSearch`/`peopleContext` are injected once but this
    /// one is cheap value construction over the same `db`.
    private var recallTools: RecallTools {
        RecallTools(
            meetings: db.meetings,
            persons: db.persons,
            series: db.series,
            calendarEvents: db.calendarEvents,
            summaries: db.summaries
        )
    }

    func prepare(
        question rawQuestion: String,
        meetingId: MeetingID?,
        seriesId: SeriesID?,
        history: [RecallTurn]
    ) async throws -> PreparedRequest {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            throw RecallEngineError.emptyQuestion
        }
        guard Recall.scalars(question).count <= RecallBounds.maxQuestionChars else {
            throw RecallEngineError.questionTooLong
        }
        guard !Recall.isUnsupportedRecallQuestion(question) else {
            throw RecallEngineError.unsupportedQuestion
        }
        let historyText = try Recall.buildHistory(history)

        guard let modelConfig = try await settings.modelConfig() else {
            throw RecallEngineError.modelNotConfigured(
                "Configure Built-in AI or Ollama before asking meetings."
            )
        }
        guard let providerKind = ProviderKind.from(modelConfig.provider) else {
            throw RecallEngineError.modelNotConfigured(
                "Configure a summary model in Settings before asking meetings."
            )
        }
        // ← `shell.rs:302-306` — the loopback-only invariant (plan §7). Same gate `ProviderFactory`
        // applies for the summary path; checked here too so the error surfaces with recall's own
        // wording, and BEFORE any retrieval work runs.
        if providerKind == .ollama, !Recall.isLoopbackOllamaEndpoint(modelConfig.ollamaEndpoint) {
            throw RecallEngineError.loopbackViolation
        }
        guard !modelConfig.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RecallEngineError.modelNotConfigured(
                "Choose a summary model in Settings before asking meetings."
            )
        }
        // ← `.ok().flatten().unwrap_or_default()` (`shell.rs:312-316`): a key-lookup failure or a
        // missing key is never fatal here — keyless providers (Ollama/MLX/ClaudeCLI/Apple) don't
        // need one, and `ProviderFactory`/the conformer itself is what actually enforces "this
        // provider requires a key".
        let apiKey = await (try? secrets.apiKey(forProvider: modelConfig.provider)) ?? ""

        let isMeetingScoped = meetingId != nil
        let isSeriesScoped = !isMeetingScoped && seriesId != nil

        let seriesLedgerMarkdown: String?
        if isSeriesScoped, let seriesId {
            let ledger = try? await db.series.find(seriesId)?.ledgerMarkdown
            let flattened = ledger.flatMap(\.self)
            seriesLedgerMarkdown = flattened?.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false ? flattened : nil
        } else {
            seriesLedgerMarkdown = nil
        }

        // Slice B structured tools (plan §4.3, `ask-meetings-tools-and-cards.md`): a STRICTLY
        // ADDITIVE, global-scope-only pre-step. Hybrid RAG below is NEVER skipped or replaced —
        // this only ever attaches a `card` to the eventual response and, when resolved, folds a
        // couple of terse real facts into the prompt. A classifier miss, an ambiguous match, or a
        // zero match all degrade to exactly today's behavior (no card, byte-identical prompt).
        let resolvedEntity = meetingId == nil && seriesId == nil
            ? await Self.resolveGlobalScopeEntity(question: question, tools: recallTools)
            : nil
        let resolvedCard = resolvedEntity?.card
        let resolvedContextLine = resolvedEntity?.contextLine

        let matches: [TranscriptSearchResult]
        if let meetingId {
            matches = try await meetingTranscriptSearchResults(meetingId)
        } else if let seriesId {
            let memberIds = try await db.series.meetingIds(inSeries: seriesId)
            matches = try await hybridSearch.globalSearchScoped(
                question,
                allowedMeetingIds: Set(memberIds)
            )
        } else {
            matches = try await hybridSearch.globalSearch(question)
        }

        // LLM-first (retrieve-augment-always): an empty retrieval is NOT a dead end. The model
        // always runs, augmented with whatever the search found — so a greeting or an
        // out-of-corpus question gets an honest conversational reply and streaming is visible,
        // instead of a hard "no match" wall. Sources stay DB-built (empty when nothing matched),
        // so the never-invent-citations guard is untouched: with zero sources, reconcile() strips
        // any [Sn] the model emits.
        let hasMatches = !matches.isEmpty
        var sources = hasMatches
            ? (isMeetingScoped
                ? Recall.buildMeetingSources(matches)
                : Recall.buildGlobalSources(matches))
            : []
        await peopleContext.attachPeople(&sources)
        let peopleBlock = await peopleContext.peopleContextBlock(
            sources: sources,
            scopedMeetingId: meetingId
        )

        let context = hasMatches
            ? Recall.buildContext(sources)
            : "(No saved meeting excerpts matched this question.)"
        let systemPrompt = Recall.systemPrompt(isMeetingScoped: isMeetingScoped)
        let priorConversation = historyText.isEmpty
            ? ""
            : "Earlier conversation (context only; meeting sources remain authoritative):\n\(historyText)\n\n"
        let peopleSection = peopleBlock.isEmpty ? "" : "\(peopleBlock)\n\n"
        let seriesSection = seriesLedgerMarkdown.map {
            "### Series ledger (running context for this series)\n\($0)\n\n"
        } ?? ""
        let toolSection = resolvedContextLine.map { "\($0)\n\n" } ?? ""
        // Real, not fabricated (No-Fake-State) — this is the device's actual current date, the
        // same real signal `RecallTools`/the card payloads already compute "today" against. Without
        // this the model has no anchor for "today"/"this week" and will infer one from whatever
        // date happens to appear in a retrieved excerpt (caught live 2026-07-23: asked "today" with
        // a correct resolved-person card in hand, the model still answered from an unrelated
        // meeting's date and flatly contradicted its own card).
        let todaySection = "Today's date is \(Self.todayLine()).\n\n"
        let userPrompt = "\(todaySection)\(priorConversation)\(peopleSection)\(seriesSection)\(toolSection)"
            + "Question: \(question)\n\nAuthoritative local meeting sources:\n\(context)"

        let config = ProviderConfig(
            kind: providerKind,
            model: modelConfig.model,
            apiKey: apiKey,
            ollamaEndpoint: modelConfig.ollamaEndpoint
        )

        return PreparedRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            sources: sources,
            isMeetingScoped: isMeetingScoped,
            config: config,
            card: resolvedCard
        )
    }

    /// A real, human-readable "today" line (e.g. "Thursday, July 23, 2026") from the device's
    /// actual current date — the one honest anchor the model needs for "today"/"this week"
    /// questions, distinct from any meeting/source date in the retrieved context.
    private static func todayLine() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter.string(from: Date())
    }

    // MARK: - Meeting-scoped retrieval (← `TranscriptsRepository::

    // get_meeting_transcripts_for_recall`, `transcript.rs:112-140`)

    /// One `TranscriptSearchResult` per transcript segment (recording order), or — when the
    /// meeting has no transcript segments at all but does have a saved summary — a single
    /// synthetic row carrying just that summary, matching the Rust `LEFT JOIN`'s "summary-only"
    /// case (`transcript.rs:117-121`: `t.meeting_id IS NOT NULL OR` a non-empty `summary_processes.
    /// result`). A meeting that exists but has neither yields `[]`, same as zero SQL rows.
    private func meetingTranscriptSearchResults(_ meetingId: MeetingID) async throws -> [TranscriptSearchResult] {
        guard let meeting = try await db.meetings.find(meetingId) else {
            return []
        }
        let segments = try await db.transcripts.forMeeting(meetingId)
        let summary = try await db.summaries.forMeeting(meetingId)
        let meetingDate = RFC3339.string(from: meeting.createdAt)

        if segments.isEmpty {
            guard let body = summary?.bodyMarkdown,
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return []
            }
            return [TranscriptSearchResult(
                id: meetingId.rawValue,
                title: meeting.title,
                matchContext: "",
                timestamp: "not available",
                meetingDate: meetingDate,
                summary: body
            )]
        }

        return segments.map { segment in
            TranscriptSearchResult(
                id: meetingId.rawValue,
                title: meeting.title,
                matchContext: segment.transcript,
                timestamp: segment.timestamp,
                meetingDate: meetingDate,
                summary: summary?.bodyMarkdown
            )
        }
    }

    // MARK: - Citation reconciliation (← `shell.rs:456-469` / `stream.rs:226-237`, shared by

    // single-shot + streaming)

    /// Verify `[S<n>]` citations against the REAL source count, then verify/filter `@ref(MM:SS)`
    /// by scope — meeting-scoped keeps in-range refs (they become play-badges), series/global
    /// strip every `@ref` (a bare `MM:SS` is ambiguous across meetings). Never trusts the model's
    /// own claimed citations (plan §7).
    static func reconcile(answer: String, sources: [RecallSource], isMeetingScoped: Bool) -> String {
        let verified = Recall.verifySourceCitations(answer, sourceCount: sources.count)
        guard isMeetingScoped else {
            return Recall.filterRefTimestamps(verified, maxSeconds: nil)
        }
        let maxSeconds = sources.compactMap { Recall.parseTimestampLabel($0.timestamp) }.max()
        return Recall.filterRefTimestamps(verified, maxSeconds: maxSeconds)
    }
}
