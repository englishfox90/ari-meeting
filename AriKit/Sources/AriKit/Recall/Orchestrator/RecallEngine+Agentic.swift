//
//  RecallEngine+Agentic.swift — the tool-first agentic orchestration for global/series-scope Ask
//  Meetings (plan §3.6/§4.2/§4.4, `docs/plans/ask-meetings-agentic-tools.md`).
//
//  Retrieval (`search_transcripts`) and deterministic entity lookups (`find_person`, `find_meeting`,
//  `todays_events`, `get_meeting_summary`, `list_recent_meetings`) become TOOLS the model requests,
//  instead of an unconditional 48k-char excerpt injection on every ask (plan §1.1's diagnosis).
//
//  The three-rung fallback ladder (plan §4.4, refined 2026-07-23 principal review — LIVE streaming,
//  not buffer-then-replay):
//    1. Native tool loop — a `ToolCapableLLMClient` (today: `.mlx`) drives its own agentic loop.
//       `.thinking`/`.toolActivity`/`.delta` are forwarded to the caller AS THEY ARRIVE.
//    2. Prompt-JSON loop — `.claudeCLI` only: a hand-rolled ≤8-turn loop over plain `client.generate`,
//       using a fenced ```json {"tool":…,"args":{…}} protocol, the SAME `AskToolset` dispatch.
//       `.toolActivity` is forwarded live between turns; each turn's `generate` call is itself
//       blocking (inherent to the ClaudeCLI transport) and its result is forwarded once it returns.
//    3. Classifier + single-shot RAG — every other provider, AND the error fallback when rung 1/2
//       throws BEFORE any answer text was ever forwarded. This is `answerMeetingsLocallySingleShot`
//       (`RecallEngine.swift`) — the exact, byte-identical pre-agentic pipeline, unchanged.
//
//  **Commit-on-first-delta.** The instant rung 1/2 forwards its first non-empty answer `.delta`,
//  that rung is COMMITTED — there is no falling back to rung 3 after that point, even if the
//  underlying stream later throws (in that case the accumulated answer is used as-is; "no
//  Franken-answer" is an ANSWER-TEXT guarantee, not a ban on `.thinking`/`.toolActivity` staying
//  visible from an attempt that is later abandoned — those events are honest: the tool really ran,
//  the model really thought that; the VM treats them as ephemeral either way).
//
//  Never-invents-citations holds by construction: `sources`/`cards` are built ENTIRELY from what
//  `ToolTurnState` actually accumulated during real tool dispatches — the model cannot add a
//  source that wasn't returned by an actual `search_transcripts` call (plan §6).
//
import Foundation

extension RecallEngine {
    /// The prepared request for the agentic path — no excerpts, no retrieval yet; the model must
    /// call a tool to get real data (plan §4.2).
    struct AgenticPreparedRequest {
        var systemPrompt: String
        var userPrompt: String
        var config: ProviderConfig
    }

    /// Reuses `validate`'s entire gating prefix (question/model/loopback/series-ledger — byte-
    /// identical to `prepare()`'s own gates), then builds the tool-oriented prompt instead of
    /// retrieving anything up front.
    func prepareAgentic(
        question: String,
        seriesId: SeriesID?,
        history: [RecallTurn]
    ) async throws -> AgenticPreparedRequest {
        let validated = try await validate(question: question, meetingId: nil, seriesId: seriesId, history: history)

        let systemPrompt = Recall.agenticSystemPrompt(seriesLedger: validated.seriesLedgerMarkdown)
        let priorConversation = validated.historyText.isEmpty
            ? ""
            : "Earlier conversation (context only):\n\(validated.historyText)\n\n"
        let seriesSection = validated.seriesLedgerMarkdown.map {
            "### Series ledger (running context for this series)\n\($0)\n\n"
        } ?? ""
        let todaySection = "Today's date is \(Self.todayLine()).\n\n"
        let userPrompt = "\(todaySection)\(priorConversation)\(seriesSection)Question: \(validated.question)"

        let config = ProviderConfig(
            kind: validated.providerKind,
            model: validated.modelConfig.model,
            apiKey: validated.apiKey,
            ollamaEndpoint: validated.modelConfig.ollamaEndpoint
        )
        return AgenticPreparedRequest(systemPrompt: systemPrompt, userPrompt: userPrompt, config: config)
    }

    /// An `AskToolset` bound to this engine's own repositories, optionally pre-bound to a series'
    /// member meetings (series scope, mirrors `HybridSearch.globalSearchScoped`'s pre-binding).
    func askToolset(allowedMeetingIds: Set<MeetingID>?) -> AskToolset {
        AskToolset(
            tools: recallTools,
            hybridSearch: hybridSearch,
            meetings: db.meetings,
            allowedMeetingIds: allowedMeetingIds
        )
    }

    static func allowedMeetingIds(seriesId: SeriesID?, db: AppDatabase) async throws -> Set<MeetingID>? {
        guard let seriesId else { return nil }
        return try await Set(db.series.meetingIds(inSeries: seriesId))
    }

    // MARK: - Single-shot entry (routed from `answerMeetingsLocally`, plan §4.5)

    /// The tool-first agentic path for a non-streaming ask. Falls back to
    /// `answerMeetingsLocallySingleShot` (rung 3) whenever rung 1/2 is unavailable, or throws
    /// before producing any answer text (plan §4.4). Nobody is watching intermediate events here,
    /// so `runAgenticRungs` is driven with a no-op event sink (the collecting-not-streaming case).
    func answerMeetingsLocallyAgentic(
        question: String,
        seriesId: SeriesID?,
        history: [RecallTurn]
    ) async throws -> RecallResponse {
        let prepared = try await prepareAgentic(question: question, seriesId: seriesId, history: history)
        let client = try clientFactory(prepared.config)
        let allowedMeetingIds = try await Self.allowedMeetingIds(seriesId: seriesId, db: db)
        let toolset = askToolset(allowedMeetingIds: allowedMeetingIds)
        let state = ToolTurnState()

        if let (answer, committed) = await Self.runAgenticRungs(
            client: client, prepared: prepared, toolset: toolset, state: state
        ), committed {
            let sources = await state.sources
            let cards = await state.cards
            let reconciled = Self.reconcile(answer: answer, sources: sources, isMeetingScoped: false)
            return RecallResponse(answer: reconciled, sources: sources, cards: cards)
        }

        // Rung 3: the exact, byte-identical pre-agentic pipeline.
        return try await answerMeetingsLocallySingleShot(
            question: question, meetingId: nil, seriesId: seriesId, history: history
        )
    }

    // MARK: - Streaming entry (routed from `answerMeetingsLocallyStream`, plan §4.5)

    /// The tool-first agentic path for a streaming ask. `.thinking`/`.toolActivity`/`.delta` from
    /// rung 1/2 are forwarded to the caller's continuation LIVE, the moment they arrive — this is
    /// the entire UX point of the feature (a user watching a multi-second tool loop must see
    /// "Thinking…"/"Searching transcripts…" as they happen, plan review 2026-07-23). Commit-on-
    /// first-delta: once the first non-empty answer `.delta` has been forwarded, rung 1/2 is
    /// committed and rung 3 never runs, even if the underlying stream later throws (the accumulated
    /// answer is used as-is). If it throws BEFORE any answer delta, already-forwarded
    /// `.thinking`/`.toolActivity` events stay visible (honest — those tools really ran) and rung 3
    /// runs, forwarding its REAL, live-streaming events verbatim; the caller never sees a rung-1
    /// `.delta` followed by a rung-3 `.delta` (the "no Franken-answer" guarantee is answer-text-only).
    func answerMeetingsLocallyStreamAgentic(
        question: String,
        seriesId: SeriesID?,
        history: [RecallTurn]
    ) -> AsyncThrowingStream<RecallStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prepared = try await prepareAgentic(question: question, seriesId: seriesId, history: history)
                    let client = try clientFactory(prepared.config)
                    let allowedMeetingIds = try await Self.allowedMeetingIds(seriesId: seriesId, db: db)
                    let toolset = askToolset(allowedMeetingIds: allowedMeetingIds)
                    let state = ToolTurnState()

                    let ladderResult = await Self.runAgenticRungs(
                        client: client, prepared: prepared, toolset: toolset, state: state
                    ) { event in
                        Self.forwardAgenticEvent(event, to: continuation)
                    }

                    if let (answer, committed) = ladderResult, committed {
                        let sources = await state.sources
                        let cards = await state.cards
                        let reconciled = Self.reconcile(answer: answer, sources: sources, isMeetingScoped: false)
                        continuation.yield(.done(RecallResponse(answer: reconciled, sources: sources, cards: cards)))
                        continuation.finish()
                        return
                    }

                    // Rung 3: forward the REAL, live-streaming pre-agentic pipeline verbatim. Any
                    // `.thinking`/`.toolActivity` already forwarded above stays visible — only
                    // ANSWER TEXT (`.delta`) is guaranteed never to mix between rungs, and none was
                    // ever forwarded (committed == false, by construction).
                    for try await event in answerMeetingsLocallyStreamSingleShot(
                        question: question, meetingId: nil, seriesId: seriesId, history: history
                    ) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Maps one `AgenticEvent` to its `RecallStreamEvent` and yields it immediately — the single
    /// place both the streaming entry point's live path uses this mapping (kept as a `static` free
    /// function so it carries no captured state of its own).
    private static func forwardAgenticEvent(
        _ event: AgenticEvent,
        to continuation: AsyncThrowingStream<RecallStreamEvent, Error>.Continuation
    ) {
        switch event {
        case let .thinking(text):
            guard !text.isEmpty else { return }
            continuation.yield(.thinking(text))
        case let .answerDelta(text):
            guard !text.isEmpty else { return }
            continuation.yield(.delta(text))
        case let .toolStarted(name):
            continuation.yield(.toolActivity(
                ToolActivity(toolName: name, displayLabel: AskToolset.displayLabel(for: name), phase: .started)
            ))
        case let .toolFinished(name, ok):
            continuation.yield(.toolActivity(
                ToolActivity(toolName: name, displayLabel: AskToolset.displayLabel(for: name), phase: .finished(ok: ok))
            ))
        }
    }

    // MARK: - Rungs 1/2 (shared by both entry points above)

    /// Attempts rung 1 (native tool loop) then rung 2 (prompt-JSON loop), in that order, invoking
    /// `onEvent` for every `AgenticEvent` AS IT ARRIVES (the streaming entry forwards live; the
    /// non-streaming entry passes the default no-op sink — collecting only the final answer).
    /// Returns `nil` when neither rung applies to `client`. Returns `(answer, committed: false)`
    /// when a rung ran but never produced any answer text (clean finish or a throw before the first
    /// delta) — the caller then runs rung 3. Returns `(answer, committed: true)` once an answer was
    /// produced — from that point on, the caller must NOT run rung 3.
    static func runAgenticRungs(
        client: any LLMClient,
        prepared: AgenticPreparedRequest,
        toolset: AskToolset,
        state: ToolTurnState,
        onEvent: @Sendable (AgenticEvent) async -> Void = { _ in }
    ) async -> (answer: String, committed: Bool)? {
        if let toolClient = client as? any ToolCapableLLMClient {
            let stream = runNativeToolLoop(client: toolClient, prepared: prepared, toolset: toolset, state: state)
            return try? await drainAgenticEvents(stream, onEvent: onEvent)
        }
        if client.kind == .claudeCLI {
            return try? await runPromptJSONLoop(
                client: client,
                prepared: prepared,
                toolset: toolset,
                state: state,
                onEvent: onEvent
            )
        }
        return nil
    }

    /// Drains an `AgenticEvent` stream, invoking `onEvent` for each event THE MOMENT it arrives (so
    /// a live caller can forward `.thinking`/`.toolActivity`/`.delta` immediately — no buffering),
    /// while accumulating the full answer text. `committed` becomes `true` the instant the first
    /// non-empty `.answerDelta` is seen. If the stream throws BEFORE that point, the error
    /// propagates (the caller falls back to rung 3). If it throws AFTER, the error is swallowed and
    /// the accumulated answer is returned as committed — rung 1 already "answered", so there is no
    /// going back (commit-on-first-delta, 2026-07-23 principal review).
    static func drainAgenticEvents(
        _ stream: AsyncThrowingStream<AgenticEvent, Error>,
        onEvent: @Sendable (AgenticEvent) async -> Void = { _ in }
    ) async throws -> (answer: String, committed: Bool) {
        var answer = ""
        var committed = false
        do {
            for try await event in stream {
                if case let .answerDelta(text) = event, !text.isEmpty {
                    answer += text
                    committed = true
                }
                await onEvent(event)
            }
        } catch {
            guard committed else { throw error }
        }
        return (answer, committed)
    }

    /// Rung 1 — a `ToolCapableLLMClient` drives its own native agentic tool loop (plan §3.5/§4.4).
    /// Simply forwards the client's own stream (dispatch bound to `toolset`/`state`); ALL the
    /// live-forwarding / commit / fallback logic lives in `drainAgenticEvents` above, so streaming
    /// and non-streaming callers share the exact same loop with no duplication.
    static func runNativeToolLoop(
        client: any ToolCapableLLMClient,
        prepared: AgenticPreparedRequest,
        toolset: AskToolset,
        state: ToolTurnState
    ) -> AsyncThrowingStream<AgenticEvent, Error> {
        let request = LLMRequest(system: prepared.systemPrompt, user: prepared.userPrompt)
        return client.respondWithTools(request, tools: toolset.definitions) { call in
            await toolset.dispatch(call, state: state)
        }
    }

    /// Rung 2 — a hand-rolled ≤`RecallBounds.maxAgenticIterations`-turn loop over plain
    /// `client.generate`, for `.claudeCLI` (no native tool-calling transport, plan §4.4). Protocol:
    /// reply with ONLY a fenced ```json {"tool": "<name>", "args": {…}} block to call a tool, or
    /// plain text to answer. Lenient first-JSON-block parsing; two consecutive tool-shaped-but-
    /// unparseable replies are treated as the final answer (never an infinite garbage loop).
    /// `.toolActivity` is forwarded live between turns via `onEvent`; each turn's `generate` call is
    /// itself blocking (inherent to the transport) and its result is forwarded once it returns.
    /// Every return point here has already "answered" — `committed` is always `true` on a normal
    /// return; a throw (from `client.generate`) propagates before any commit, matching rung 1's
    /// contract exactly.
    static func runPromptJSONLoop(
        client: any LLMClient,
        prepared: AgenticPreparedRequest,
        toolset: AskToolset,
        state: ToolTurnState,
        onEvent: @Sendable (AgenticEvent) async -> Void = { _ in }
    ) async throws -> (answer: String, committed: Bool) {
        let system = prepared.systemPrompt + "\n\n" + promptJSONInstructions(for: toolset.definitions)
        var conversation = prepared.userPrompt
        var consecutiveUnparseableToolShaped = 0

        for _ in 0 ..< RecallBounds.maxAgenticIterations {
            let reply = try await client.generate(LLMRequest(system: system, user: conversation))

            if let (toolName, argumentsJSON) = parseToolCall(from: reply) {
                consecutiveUnparseableToolShaped = 0
                await onEvent(.toolStarted(name: toolName))
                let call = AgenticToolCall(id: UUID().uuidString, name: toolName, argumentsJSON: argumentsJSON)
                let result = await toolset.dispatch(call, state: state)
                await onEvent(.toolFinished(name: toolName, ok: true))
                conversation += "\n\nTool result (\(toolName)): \(result)\n\nContinue, or answer the question directly now."
                continue
            }

            if looksToolShaped(reply) {
                consecutiveUnparseableToolShaped += 1
                if consecutiveUnparseableToolShaped >= 2 {
                    await onEvent(.answerDelta(reply))
                    return (reply, true)
                }
                conversation += "\n\nYour last reply was not valid JSON for a tool call. Reply with ONLY a fenced ```json tool call, or plain text to answer the question."
                continue
            }

            await onEvent(.answerDelta(reply))
            return (reply, true)
        }

        let exhausted = "I wasn't able to finish gathering information from your saved meetings in time — try a narrower question."
        await onEvent(.answerDelta(exhausted))
        return (exhausted, true)
    }

    /// The tool-definitions block + protocol instructions appended to the system prompt for the
    /// prompt-JSON loop (plan §4.4).
    private static func promptJSONInstructions(for definitions: [AgenticToolDefinition]) -> String {
        let toolLines = definitions.map { definition in
            "- \(definition.name): \(definition.description) Arguments schema: \(definition.parametersJSONSchema)"
        }.joined(separator: "\n")
        return "Available tools:\n\(toolLines)\n\nTo call a tool, reply with ONLY a fenced code block "
            + "containing a single JSON object: ```json\n{\"tool\": \"<name>\", \"args\": {...}}\n```\n"
            + "To answer the question directly, reply with plain text and no JSON."
    }

    /// Lenient first-JSON-object extraction: strips a leading fence (if present), finds the first
    /// balanced `{...}` block, and parses `{"tool": string, "args": object}` from it. Returns `nil`
    /// for anything that doesn't parse as that exact shape.
    static func parseToolCall(from text: String) -> (tool: String, argumentsJSON: String)? {
        guard let jsonText = firstBalancedJSONObject(in: text),
              let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = object["tool"] as? String
        else {
            return nil
        }
        let args = object["args"] as? [String: Any] ?? [:]
        guard let argsData = try? JSONSerialization.data(withJSONObject: args) else { return nil }
        return (tool, String(decoding: argsData, as: UTF8.self))
    }

    /// Whether `text` looks like it was ATTEMPTING a tool call (mentions `"tool"` or a ```json
    /// fence) even though `parseToolCall` failed to extract a valid one — used to distinguish "the
    /// model tried to call a tool but malformed the JSON" from "the model answered in plain text".
    static func looksToolShaped(_ text: String) -> Bool {
        text.contains("\"tool\"") || text.contains("```json")
    }

    private static func firstBalancedJSONObject(in text: String) -> String? {
        guard let openIndex = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = openIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "{" {
                depth += 1
            }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[openIndex ... index])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
