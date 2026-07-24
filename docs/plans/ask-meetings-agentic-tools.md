# Ask Meetings: Tool-First Agentic Pipeline — Retrieval as a Tool, Thinking Stream, Rich Cards

## 0. Status

Plan finalized 2026-07-23 (architect draft + principal review; amendments marked **[P1]–[P3]** in place). Targets `AriKit` (Recall + Engine/Providers), `AriKitEngineMLX`, `AriViewModels`, and the `Ari` app UI. Swift-native track only — no Rust/React changes (plan principle 8: this is net-new Swift capability on the target side of the recall seam; the frozen Rust `ari-engine/src/recall/agent.rs` Claude-only agentic loop is a *reference*, not a port — see §1).

Supersedes the retrieve-always integration shape of `docs/plans/ask-meetings-tools-and-cards.md` (Slice B/§4.3, "hybrid chunk RAG is never replaced… always runs"). That plan's deliverables (`RecallTools`, `RecallIntentClassifier`, `RecallCardPayload`, indexing fixes) are all **kept and reused**; only the "excerpts injected on every ask" orchestration is replaced. WIP note: one feature (Ask Meetings pipeline), three semi-independent slices with explicit inter-slice contracts (§10).

## 1. Goal & seam

**Owner's framing:** "The RAG model is a tool the LLM can use if it's needed. We don't need excerpts inserted into every response — only when requested."

**Goal:** rebuild the global/series-scope Ask pipeline as *route → (agentic tool loop) → answer*:

1. Retrieval (`HybridSearch`) becomes a **tool** (`search_transcripts`) the model calls when it needs transcript evidence — never an unconditional 48k-char injection.
2. Deterministic entity lookups (`RecallTools`) become tools too (`find_person`, `find_meeting`, `calendar_events`, …), each attaching a typed `RecallCardPayload` when it resolves a real entity.
3. Model **thinking** is enabled for Ask (Qwen3 `<think>` blocks) and streamed to the UI as a distinct, muted "thinking" style — ephemeral, never persisted.
4. Tool activity ("Searching transcripts…", "Looked up Landon Star") streams to the UI honestly (No-Fake-State: shown only when a tool actually ran).

**Target queries (acceptance bar, §8.6):**
- "Remind me about that meeting I had with Landon earlier" → `find_person` → person/meeting card + summary recap.
- "What are the action items of this meeting" (meeting-scoped) → action items with `[Sn]`/`@ref` citations — **unchanged single-shot path**, see §4.5.
- "Who is in the 6pm meeting later" → NEW `calendar_events` tool (event-by-time/today's-agenda — no data path exists today: `RecallTools.calendarEventsToday(matchingAttendeeName:)` requires an attendee-name query, `RecallTools.swift:155-178`) → calendar-event card + attendee answer.

**Seam:** entirely inside the already-Swift Recall stack. Integration points: `RecallEngine.prepare`/`answerMeetingsLocally`/`answerMeetingsLocallyStream` (`AriKit/Sources/AriKit/Recall/Orchestrator/RecallEngine.swift:104-306`, `RecallStream.swift:34-80`), the provider layer (`Engine/Providers/LLMClient.swift`), `MLXClient` (`AriKitEngineMLX/MLXClient.swift`), and the Ask VM/UI (`AriViewModels/Ask/`, `Ari/UI`). Not a re-implementation of a frozen Rust feature: the Rust `agent.rs` loop was Claude-API-only, never ported (`RecallEngine.swift:11-17,137-141`); this design is provider-tiered, on-device-first, and structurally different. Its **bounds** are ported as invariants (§6): `MAX_ITERATIONS=8`, `MAX_SOURCES=24`, `MAX_TRANSCRIPT_CHARS=8_000`, `MAX_TOOL_RESULT_CHARS=16_000` (`ari-engine/src/recall/agent.rs:31-35`).

### 1.1 Diagnosis this plan builds on (verified 2026-07-23; do not re-derive)

`RecallEngine.prepare` runs hybrid search on EVERY ask and appends up to 48k chars of excerpts under a header literally titled `"Authoritative local meeting sources:"` (`RecallEngine.swift:238-289`, the header at :289), while the system prompt simultaneously instructs the model to trust one-line `"Resolved:"`/`"Calendar:"` facts *over* those "authoritative" excerpts (`RecallPrompt.swift:29-31`). A 4B model loses that arbitration — two live failures post-fix-rebuild (2026-07-23): (a) answered about the wrong person from retrieved excerpts despite a correct resolved card; (b) contradicted its own resolved calendar card. The fix is structural, not prompt-tuning: **stop unconditional excerpt injection; make retrieval a tool the model requests.** When the model asks for excerpts, they arrive as a *tool result it wanted*, with no competing "authoritative" framing.

## 2. Verified runtime facts (load-bearing)

All verified this session against the pinned mlx-swift-lm **3.31.4** checkout at `~/Library/Developer/Xcode/DerivedData/Ari-aojqyoburnbnqlgnslyppasmoklq/SourcePackages/checkouts/mlx-swift-lm/Libraries/MLXLMCommon/`:

1. **`ChatSession` runs the agentic loop itself.** `init(_:instructions:…:tools:[ToolSpec]?:toolDispatch:(@Sendable (ToolCall) async throws -> String)?)` (`ChatSession.swift:160-197`). Inside `streamMap`, a `restart:` loop (`ChatSession.swift:635-784`) generates, collects `Generation.toolCall` items when `toolDispatch != nil` (`:756-767`), awaits the generation task, invokes `toolDispatch` per call, appends `.tool(result, id:)` messages (`:775-783`), and `continue restart`s — KV cache preserved across turns.
2. **`ToolSpec = [String: any Sendable]`** (OpenAI-style function schema dict) and **`ToolCall.Function { name: String, arguments: [String: JSONValue] }`** (`Tool/Tool.swift:5`, `Tool/ToolCall.swift:5-22`).
3. **Format auto-detection:** `ToolCallFormat.infer` maps `qwen3_5*` → `.xmlFunction` (`Tool/ToolCallFormat.swift:209-212`); plain `qwen3` checkpoints fall through to the **default `.json` Hermes parser** (`ToolCallFormat.swift:64-67,111-112`). **[Harness correction 2026-07-23]** the app's actual default model is `mlx-community/Qwen3.5-4B-MLX-4bit` (`MLXRegistration.swift`), i.e. the `.xmlFunction` branch — the auto-detector handles both, verified live (12/12 routing).
4. **Streaming granularity — two critical findings:**
   - `Generation` has exactly three cases: `.chunk(String)`, `.info`, `.toolCall(ToolCall)` (`Evaluate.swift:2052-2060`). **There is NO separate thinking/reasoning event.** Qwen thinking arrives as literal `<think>…</think>` text inside `.chunk` deltas. → We must split think-tags ourselves (§5.2).
   - **When `toolDispatch` is set, `.toolCall` items are NEVER yielded to the stream consumer** — they're diverted into `pendingToolCalls` before the transform runs (`ChatSession.swift:760-766`), even via `streamDetails`. → Tool-activity UI events must be emitted from *inside our own dispatch closure*, not observed from the stream (§5.1).
   - **ChatSession's internal loop has NO iteration cap.** The `restart:` loop continues as long as the model keeps emitting tool calls. → The ≤8-iteration budget must be enforced inside our dispatch (§4.3).
5. **Thinking mode:** `MLXClient.makeSession` currently pins `additionalContext: ["enable_thinking": false]` (`MLXClient.swift:247`) — correct for summaries, reversed for the new Ask path. Qwen3 model card thinking-mode sampling: **temp 0.6, topP 0.95** (vs. the summary path's 0.5/0.8, `MLXClient.swift:72-73`).
6. **ClaudeCLI** is a subprocess of the local `claude` binary with a plain string in/out surface (`ClaudeCLIClient.swift:20-49`) — no native tool API in that transport. It gets a **prompt-based JSON tool protocol** driving the same Swift dispatch (§4.4).
7. **Provider surface today:** `LLMClient { generate, stream }` (`LLMClient.swift:15-25`), 9 `ProviderKind`s, `ProviderFactory.make` (`ProviderFactory.swift:34-94`). No tool concept anywhere.

## 3. Module boundaries & public surface

### 3.1 New: engine-neutral tool types + `ToolCapableLLMClient` (AriKit `Engine/Providers/`)

`AriKit` cannot import `MLXLMCommon` (core stays Metal-toolchain-free, `ProviderFactory.swift:25-29`), so the tool abstraction is engine-neutral; `AriKitEngineMLX` adapts it to `ToolSpec`/`ToolCall`. New file `Engine/Providers/AgenticTooling.swift`:

```swift
/// One declared tool: name + description + JSON-schema parameters, engine-neutral.
public struct AgenticToolDefinition: Sendable, Equatable {
    public var name: String
    public var description: String
    /// JSON-encoded parameter schema ({"type":"object","properties":{…},"required":[…]}).
    /// A String (not [String: Any]) keeps this Sendable/Equatable; MLX decodes it into ToolSpec,
    /// the prompt-JSON path prints it verbatim.
    public var parametersJSONSchema: String
}

/// One tool invocation the model requested. Arguments arrive as a JSON object string;
/// each tool decodes its own typed Input via Codable (never a stringly free-for-all downstream).
public struct AgenticToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    public var argumentsJSON: String
}

public typealias AgenticToolDispatch = @Sendable (AgenticToolCall) async throws -> String

/// Events from a tool-capable generation. `.thinking` carries reasoning text (already
/// stripped of <think> tags); `.answerDelta` carries user-visible answer text.
/// `.toolStarted/.toolFinished` are emitted by the CLIENT around each dispatch invocation.
public enum AgenticEvent: Sendable, Equatable {
    case thinking(String)
    case answerDelta(String)
    case toolStarted(name: String)
    case toolFinished(name: String, ok: Bool)
}

/// Optional refinement — NO existing conformer changes. RecallEngine downcasts
/// (`client as? any ToolCapableLLMClient`) to pick the native loop.
public protocol ToolCapableLLMClient: LLMClient {
    func respondWithTools(
        _ request: LLMRequest,
        tools: [AgenticToolDefinition],
        dispatch: @escaping AgenticToolDispatch
    ) -> AsyncThrowingStream<AgenticEvent, Error>
}
```

Non-breaking by construction: `Anthropic`/`OpenAICompatible`/`ClaudeCLI`/`FoundationModels`/`Stub` conformers are untouched. Only `MLXClient` adopts `ToolCapableLLMClient` in this plan. (Provider-native tool APIs for Anthropic/OpenAI/Ollama HTTP are a natural later adoption of the same protocol — explicitly out of scope here, one plan per push.)

Also new (Slice 1, `Recall/Shell/ThinkTagSplitter.swift`): `Recall.splitThinkTags` — a pure, incremental `<think>`/`</think>` stream splitter (a tiny state machine over string deltas: text before/inside/after tags, tolerant of tags split across chunk boundaries), used by `MLXClient` and unit-tested exhaustively in AriKit with no MLX dependency.

### 3.2 New: `AskToolset` (AriKit `Recall/Tools/AskToolset.swift`)

A `Sendable` value type over the existing `RecallTools` + `HybridSearch` + repositories, following the established "value type over injected handles" convention (`RecallTools.swift:20-39`). It owns: the 6 tool definitions (§4.1), the typed per-tool `Input` Codable structs, the dispatch implementation, and per-call output bounding. Mutable accumulation (sources, cards, iteration count) lives in a per-ask **actor**:

```swift
/// Per-ask accumulation crossing the @Sendable dispatch boundary (§7).
actor ToolTurnState {
    private(set) var sources: [RecallSource] = []   // dedup + cap 24 (RecallBounds.maxAgenticSources)
    private(set) var cards: [RecallCardPayload] = []
    private(set) var iterations = 0
    private(set) var surfacedMeetingIds: Set<MeetingID> = []  // [P1] IDs any tool has legitimately surfaced this turn
    func registerSource(_ s: RecallSource) -> Int?   // ← agent.rs register_source: dedup by (meetingId, matchContext-prefix), returns 1-based [Sn] index or nil when capped
    func attach(_ card: RecallCardPayload)           // dedup by payload equality
    func surface(_ id: MeetingID)                    // [P1] record an ID a tool result exposed to the model
    func beginIteration() -> Bool                    // false once >= maxAgenticIterations
}

public struct AskToolset: Sendable {
    let tools: RecallTools
    let hybridSearch: HybridSearch
    let peopleContext: PeopleContext
    public var definitions: [AgenticToolDefinition]
    func dispatch(_ call: AgenticToolCall, state: ToolTurnState) async -> String  // never throws to the loop: tool errors return an honest "Tool failed: …" string so the model can recover
}
```

### 3.3 `RecallTools` extensions (same file, additive)

- `calendarEvents(today hourFilter: Int?) async throws -> [CalendarEvent]` — today's agenda (device-local `Calendar.current.isDateInToday`, same discipline as `RecallTools.swift:158-159`), optionally narrowed to events whose `startTime` hour matches (`hourFilter` 0–23; "6pm" → 18). This is the missing data path for target query 3.
- Attendee **email** matching added beside the name-only match in `calendarEventsToday(matchingAttendeeName:)` (`RecallTools.swift:164-167` matches `attendee.name` only today): a query containing `@` matches `attendee.email` case-insensitively.
- `summaryMarkdown(for meetingId: MeetingID) async throws -> String?` — bounded read: `summaries.forMeeting(meetingId)?.bodyMarkdown` truncated to `RecallBounds.maxAgenticTranscriptChars` (8 000, ← `agent.rs:33`).

### 3.4 `RecallBounds` additions (`Shell/RecallBounds.swift`)

```swift
// Agentic-loop caps (← ari-engine/src/recall/agent.rs:31-34, ported as invariants)
public static let maxAgenticIterations = 8
public static let maxAgenticSources = 24
public static let maxAgenticTranscriptChars = 8_000
public static let maxToolResultChars = 16_000
```

### 3.5 `MLXClient: ToolCapableLLMClient` (`AriKitEngineMLX`)

> **[Revised 2026-07-23 after live harness]** The original design below (ChatSession + `toolDispatch`) is **unusable on 3.31.4 with the app's real checkpoint**: ChatSession's incremental continuation re-renders only the per-turn tail messages, and Qwen3.5's chat template backward-scans for the last `user` message before rendering tool continuations — finding none, it throws `TemplateException("No user query found in messages.")` after **every** tool call (reproduced 8/8). **Adopted fix:** `respondWithTools` drives the multi-turn loop itself — `toolDispatch` stays nil (so `.toolCall` generations ARE yielded to the consumer), and each turn re-renders the **full message array** (system, user question, prior assistant tool-call turns, tool results), which always satisfies the template's user-scan. Correctness over KV reuse; ask prompts are short, tool results ≤16k. `.toolStarted`/`.toolFinished` are emitted at this loop level; the dispatch side still owns the 8-iteration budget (the conformer adds only a defensive hard-stop at 12 turns). The `AgenticEvent`/`ToolCapableLLMClient` contract is unchanged. The remainder of this section describes the original intent and the session parameters, which still apply (thinking flag, sampling, activity bracket, splitter).

Original parameter spec — `respondWithTools` builds its per-turn generation with: `instructions: request.system`, `tools:` (each `AgenticToolDefinition.parametersJSONSchema` JSON-decoded into the OpenAI-style `ToolSpec` dict `["type":"function","function":["name":…,"description":…,"parameters":…]]`), `toolDispatch:` a wrapper that yields `.toolStarted` → calls the outer dispatch → yields `.toolFinished` on the client's own `AsyncThrowingStream` continuation (per §2.4, this is the only place tool activity is observable), `additionalContext: ["enable_thinking": true]`, `GenerateParameters(maxTokens: 4096, temperature: 0.6, topP: 0.95)` (§2.5). It consumes `session.streamResponse(to: request.user)` (string chunks — tool calls already diverted) and routes each chunk through `Recall.splitThinkTags`, yielding `.thinking`/`.answerDelta`. Same `MLXActivityTracker` bracket + `mlxRuntimeConfigured` install as `generate`/`stream` (`MLXClient.swift:103-212`). Summary path (`generate`/`stream`) is untouched — thinking stays off there.

### 3.6 `RecallEngine` orchestration (`Recall/Orchestrator/RecallEngine+Agentic.swift`, new sibling file)

See §4.2–§4.4. `RecallEngine` gains an `askToolset` computed property (mirrors `recallTools`, `RecallEngine.swift:159-167`).

## 4. The tool set & orchestration

### 4.1 Six tools (terse for a 4B model; names/shapes echo the proven `agent.rs:225-285` set)

| Tool | Input schema | Backed by | Bounded output | Card |
|---|---|---|---|---|
| `search_transcripts` | `{query: string, limit?: int≤8}` | `HybridSearch.globalSearch` / `globalSearchScoped` (series scope pre-binds `allowedMeetingIds`, `HybridSearch.swift:49-53`) | Each hit registered via `ToolTurnState.registerSource` (dedup, cap 24); result text = numbered blocks `[S<n>] <title> (<date>) — <excerpt ≤ maxSourceChars>`; whole result ≤ 16k chars. Surfaces hit meeting IDs [P1] | — |
| `find_person` | `{name: string}` | `RecallTools.findPerson` + `meetings(withPerson:)` (`RecallTools.swift:45-99`) | Name, role/org, real meeting count, last-met date (± "(today)"/"(yesterday)" per `RecallEngine+Tools.swift:204-213`), **plus their ≤3 most recent meetings as `id / title / date` lines [P1]** — without this, `get_meeting_summary` is unreachable from a person lookup (the "Landon recap" flow, §8.6.1). Honest `"No unique person matched"` on nil | `.person` |
| `find_meeting` | `{title_or_topic: string}` | `RecallTools.findMeeting` + `hasSummary` | Title, date, hasSummary, id (surfaced [P1]); on miss, honest no-match | `.meeting` |
| `find_series` | `{title_or_topic?: string, series_id?: string}` | `RecallTools.seriesMatching(titleContaining:limit:)` / `series(withId:)` + `meetings(inSeries:limit:)` + `meetingCount(inSeries:)` + `seriesLedgerMarkdown(for:)` | **List-or-detail.** One match (or a `series_id`) → title, real total count, most-recent date, ≤10 member meetings (ids surfaced [P1]), and the **running ledger** (bounded at `maxAgenticTranscriptChars`); "no ledger yet" stated honestly when absent. Several matches → an enumerated listing (id / title / real count / most-recent date, ≤8) with each `SeriesID` surfaced, so the model drills in by id. A `series_id` that was never listed is refused — the same never-mint-an-id rule as `get_meeting_summary` | `.series` (detail only — a listing attaches none) |
| `get_meeting_summary` | `{meeting_id: string}` | `RecallTools.summaryMarkdown(for:)` (§3.3) | Summary markdown ≤ 8k chars; only for meeting IDs previously surfaced by another tool this turn (checked against `ToolTurnState.surfacedMeetingIds` — the model never mints IDs) | — |
| `calendar_events` | `{hour?: int 0-23, attendee?: string, days_ahead?: int, days_back?: int, upcoming_only?: bool}` | `RecallTools.calendarEvents(in:hour:upcomingOnly:now:)` + email/name attendee filter (§3.3). Window defaults to today; `days_ahead`/`days_back` are clamped to 30 days. **2026-07-23:** the tool was `todays_events` and could ONLY see today, so "when do I next have my 1:1 with Erin" could not be answered at all — tomorrow's event was read from the store and discarded. `upcoming_only` filters `endTime > now`, so an event that already ended earlier today is never offered as what's next | Per event: title, local start time, attendee names, linked-recording flag (+ linked meeting id surfaced when present [P1]); scheduled-≠-recorded wording baked in (`RecallEngine+Tools.swift:65-104` conventions) | `.calendarEvent` |
| `list_recent_meetings` | `{limit?: int≤10}` | `db.meetings.all()` prefix (already newest-first, non-deleted, `RecallTools.swift:97`) | id, title, date per row (ids surfaced [P1]) | — |

**[P1] Principal amendment — surfaced-ID plumbing:** every tool that exposes a meeting ID in its result text also records it via `ToolTurnState.surface(_:)`; `get_meeting_summary` validates against that set. This closes the gap where `find_person → get_meeting_summary` (target query 1) would otherwise be structurally impossible.

Cards attach whenever a tool resolves a real entity used in the answer — accumulated on `ToolTurnState`, shipped in the terminal response (§5.4). Ambiguous/zero resolution → no card, honest tool-result text (No-Fake-State, same discipline as `RecallTools.swift:11-14`).

### 4.2 The agentic path (global + series scope)

New `prepareAgentic` reuses `prepare`'s **entire validation prefix unchanged** — empty/too-long/unsupported gates, model-config gates, the loopback gate, history building (`RecallEngine.swift:175-212`) — then **stops before retrieval**. It builds:

- **New system prompt** `Recall.agenticSystemPrompt(seriesLedger:)` (in `RecallPrompt.swift`, alongside — not replacing — the existing `systemPrompt` which the meeting-scoped and fallback paths keep): identity + honesty rules carried over from `baseSystemPrompt` (`RecallPrompt.swift:29-31`), **minus** the "Resolved:/Calendar: vs excerpts" arbitration paragraph (no longer needed — there are no unrequested excerpts to arbitrate against), **plus**: "You have tools. Use them when the question concerns the user's meetings, people, or today's calendar; answer directly without tools for greetings/small talk. Cite `[Sn]` only using the `[Sn]` labels that appear in `search_transcripts` results; never invent a source number. A calendar event means something is scheduled, never that it was recorded or discussed." The `"Authoritative local meeting sources"` framing is **gone**.
- **User prompt** = today-line (`RecallEngine.swift:283-289`) + bounded history + series-ledger section when series-scoped (`RecallEngine.swift:217-225,277-279`) + `Question: …`. No excerpts, no people-block (people facts now arrive via `find_person` on demand).
- One `ToolTurnState` actor + the `AskToolset` dispatch bound to it.

Then the ladder (§4.4) runs the generation. Terminal assembly: `sources = await state.sources`, `cards = await state.cards`, `answer = Self.reconcile(answer:sources:isMeetingScoped:false)` — **unchanged reconcile** (`RecallEngine.swift:370-377`): `[Sn]` beyond the real accumulated source count is stripped; global/series strips all `@ref`. Because `sources` is built in Swift exclusively from what `search_transcripts` actually returned, the never-invents-citations invariant holds *by construction* even mid-agentic-loop.

### 4.3 Iteration & output bounds

- `AskToolset.dispatch` calls `state.beginIteration()` first; when the budget (8) is exhausted it returns the literal string `"Tool budget exhausted. Answer now from the information you already have."` without executing — the only way to bound `ChatSession`'s uncapped internal loop (§2.4). A model that keeps calling anyway burns its own `maxTokens` and terminates; `maxTokens: 4096` is the hard backstop (← `agent.rs:35`).
- Every tool result string is truncated to `maxToolResultChars` (16k) after per-tool bounding.
- Unknown tool name / undecodable arguments → honest `"Unknown tool …"` / `"Invalid arguments: …"` result string (never a thrown loop abort — mirrors `agent.rs`'s error-as-result behavior).

### 4.4 The fallback ladder

1. **Native tool loop** — `clientFactory(config)` result downcasts to `ToolCapableLLMClient` (today: `.mlx` only) → `respondWithTools` (§3.5).
2. **Prompt-JSON tool loop** — `.claudeCLI` only: `RecallEngine` drives its own ≤8-turn loop over plain `client.generate`. System prompt appends the tool definitions (name/description/schema, printed from `AgenticToolDefinition`) and the protocol: *reply with ONLY a fenced ```json block `{"tool": "<name>", "args": {…}}` to call a tool, or plain text to answer.* Each turn: parse-first-JSON-block (lenient: strips fences/preamble); tool call → dispatch through the same `AskToolset` + `ToolTurnState`, append `Tool result (<name>): …` to the transcript, loop; non-JSON reply → final answer. Unparseable-but-tool-shaped output twice in a row → treat as final answer. Same iteration cap, same bounds, same dispatch — only transport differs. (This is where the frozen `agent.rs` loop shape is genuinely reused.)
3. **Classifier + cards single-shot** — for every other provider, and as the **error fallback** when rung 1 or 2 throws mid-loop before any answer text streamed: the current pipeline exactly as it stands today — `resolveGlobalScopeEntity` classifier pre-step (`RecallEngine.swift:227-236`, `RecallEngine+Tools.swift` — kept as-is), hybrid retrieval, existing `Recall.systemPrompt`. Retrieve-always is acceptable *as a fallback* because it's the proven, tested current behavior; the contradiction risk (§1.1) is a quality issue, not a safety issue.

**[Refined 2026-07-23, principal review]** Rung-1/2 events stream **live** (that is the feature's UX point — no buffer-then-replay), with **commit-on-first-answer-delta** semantics: `.thinking`/`.toolActivity` forward immediately; once the first answer `.delta` has been forwarded, the rung is committed and no fallback occurs (a later throw finishes with the accumulated answer if non-empty, else surfaces the error). A throw BEFORE any answer delta → rung 3 runs. The no-Franken-answer guarantee applies to ANSWER TEXT only: a rung-1 `.delta` is never followed by rung-3 `.delta`s. Already-emitted thinking/tool-activity events may remain visible before the fallback stream — they are honest (those tools really ran) and ephemeral in the VM.

### 4.5 Meeting-scoped asks stay single-shot (decided, with justification)

Meeting scope keeps the current full-transcript path (`meetingTranscriptSearchResults`, `RecallEngine.swift:326-360` + existing `Recall.systemPrompt(isMeetingScoped: true)`). Justification: (a) it demonstrably works — full transcript + summary + in-range `@ref` badges; (b) the subject is already unambiguous, so entity tools add nothing; (c) `@ref(MM:SS)` verification needs the full single timeline in context — tool-fetched fragments would degrade it; (d) one extra decode round-trip per tool call is pure latency loss on the most common ask. Target query 2 is therefore covered by the existing path + its existing tests; §8.6 adds an integration re-assertion so this plan can't regress it.

## 5. Streaming contract end-to-end

### 5.1 Engine events (`RecallStream.swift`)

`RecallStreamEvent` gains three additive cases (existing `.delta`/`.done` unchanged — the VM's existing switch keeps compiling with a default-less exhaustive extension, so Slice 3 must land in lockstep with this enum change or the VM adds the new cases with no-op handling first; see §10 contracts):

```swift
public enum RecallStreamEvent: Sendable {
    case delta(String)                                   // answer text (unchanged)
    case thinking(String)                                // NEW: reasoning delta, ephemeral
    case toolActivity(ToolActivity)                      // NEW
    case done(RecallResponse)                            // unchanged terminal
}
public struct ToolActivity: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case started, finished(ok: Bool) }
    public var toolName: String
    public var displayLabel: String    // e.g. "Searching transcripts" — mapped in Swift from the tool name, never model text
    public var phase: Phase
}
```

The agentic path maps `AgenticEvent`: `.thinking → .thinking`, `.answerDelta → .delta`, `.toolStarted/.toolFinished → .toolActivity`. Rung-2 (prompt-JSON) emits `.toolActivity` around its own dispatch calls and streams rung turns' final answer via `client.stream` where possible. Rung-3 emits exactly today's events. `reconcile` runs on accumulated `.delta` text only (thinking never enters the answer, never gets citations checked — it's not answer text).

### 5.2 Thinking split

`Recall.splitThinkTags` (§3.1) runs in `MLXClient` (native path) so `AgenticEvent` is already clean. For defense-in-depth, `RecallEngine`'s stream mapping also routes any `<think>`-tagged spans in rung-2/3 deltas to `.thinking` (ClaudeCLI/other models occasionally leak reasoning tags).

**[Harness finding 2026-07-23 — asymmetric tags]** Qwen3.5's chat template injects the opening `<think>` into the *generation prompt* when `enable_thinking` is true, so the model's own output contains only the closing `</think>`. The splitter therefore supports `startsInsideThink: true` (begin in thinking state, flip to answer at the first `</think>`; EOS with no close-tag flushes as thinking, never reclassified as answer), and `MLXClient`'s tool path constructs each turn's splitter in that mode. Without this, reasoning + a literal `</think>` leak into the visible answer.

### 5.3 View model (`AriViewModels/Ask/`)

- `AskTranscriptItemKind.thinking` (currently a bare placeholder case, `AskTranscriptItem.swift:25`) becomes `case thinking(text: String)` — empty text = today's "searching…" placeholder behavior, non-empty = live reasoning text. New `case toolActivity(label: String, running: Bool)`.
- `AskViewModel.send()`'s event loop (`AskViewModel.swift:211-231`) adds: `.thinking(delta)` appends to the thinking item's text (creating it if the placeholder was already removed); `.toolActivity` appends/updates a tool row; first `.delta` collapses the thinking item to a folded state rather than removing it mid-loop — the thinking row is finally **removed** at `.done` (ephemeral). `dropInFlightPlaceholders` (`AskViewModel.swift:271-282`) extends to the new kinds.
- **Persistence: thinking and tool-activity rows are NOT persisted** (**decided [P2]**): `AskConversationStore.appendMessage` continues to receive only final `answer + sources + card(s)`. Rationale: thinking is model-internal scratch — persisting it invites re-reading it as fact (a No-Fake-State cousin), bloats the 7-day store, and `AskMessageRecord` needs no migration for it. Reloading a conversation shows answers + sources + cards only (`AskViewModel.load`, `AskViewModel.swift:346-356` — unchanged shape).

### 5.4 Cards: one → many (**decided [P2]: plural adopted**)

Tools can now resolve multiple entities per ask (e.g. person + calendar event for query 1/3). `RecallResponse` gains an additive `cards: [RecallCardPayload]` (custom `decodeIfPresent` defaulting `[]`, same pattern as `speakers`, `RecallWireTypes.swift:62-64`); the existing singular `card` remains as the wire/persistence back-compat field, set to `cards.first`. Persistence: additive migration `ALTER TABLE askMessage ADD COLUMN cardsJson TEXT;` (v-next on top of the frozen `v1_baseline` — additive only, per the 2026-07-22 incident rule); read path prefers `cardsJson`, falls back to legacy `cardJson`. `AskTranscriptItemKind.assistant` carries `cards: [RecallCardPayload]`; `AskConsoleView` renders them stacked above the prose via the existing card views (`RecallCardDisplay` + Ask card views from the prior plan).

### 5.5 UI styling (Slice 3, `Ari/UI`)

Thinking text renders in a visually distinct muted style: Marginalia muted-ink token, smaller text style, italic, collapsed-by-default disclosure once the answer starts ("Thinking…" header row) — tokens from `brand/tokens.json` only, no hardcoded colors (design-system rule). Tool-activity rows: small icon (SF Symbol, never emoji) + label + spinner while `running`. No fabricated progress percentages (No-Fake-State).

## 6. Invariants preserved (tested, §8)

- **Loopback-only Ollama** — validation prefix reused verbatim (`RecallEngine.swift:200-202`); Ollama is rung-3 (no tool loop), so the gate's position is unchanged.
- **Never-invents-citations** — strengthened: `sources` is accumulated in Swift from actual `search_transcripts` executions (`ToolTurnState.registerSource`, dedup + cap 24); `reconcile` strips any `[Sn]` beyond the real count (`RecallEngine.swift:370-377`, unchanged). Zero tool calls ⇒ zero sources ⇒ every `[Sn]` stripped.
- **Bounded context** — question/history caps unchanged; every tool result bounded (§4.3); ≤8 iterations; ≤24 sources; per-excerpt ≤ `maxSourceChars`; 16k per tool result. The agentic path's worst-case context is *smaller* than today's 48k always-injection.
- **`@ref` scope filtering** — unchanged `reconcile`: global/series strips all `@ref`; meeting scope (untouched path) keeps in-range refs.
- **No-Fake-State** — cards only from real resolved rows (existing `RecallTools` ambiguity discipline); tool-activity rows only for tools that actually ran; thinking shown only when the model actually emitted it; honest error strings as tool results, never fabricated data.
- **Consent-before-record** — not implicated (post-recording retrieval only).
- **One DB owner / GRDB repositories only** — all new reads go through existing repositories via `RecallTools`/`HybridSearch`; one additive `askMessage` migration; no raw SQLite.

## 7. Concurrency & isolation

- All new types follow the `Sendable`-struct-over-handles convention; the **only new actor is `ToolTurnState`** — required because the dispatch closure crosses into `ChatSession`'s generation `Task` as `@Sendable` (`ChatSession.swift:161`) and must mutate shared per-ask accumulation. Actor isolation is the textbook answer; no locks, no `@unchecked Sendable` anywhere in this plan.
- The dispatch closure captures only `AskToolset` (Sendable struct) + the `ToolTurnState` actor reference + the client's stream continuation (Sendable) — clean under Swift 6 strict concurrency.
- `ChatSession` itself is not thread-safe (`ChatSession.swift:142-144`); `MLXClient.respondWithTools` constructs one per call inside a single `Task`, exactly like the existing `stream` (`MLXClient.swift:178-212`) — the internal tool loop runs inside ChatSession's own task; our dispatch is merely awaited from it.
- Nothing touches the audio/STT hot path. Tool execution is repository reads + one embedding call inside `HybridSearch` — all off the main actor; the VM stays `@MainActor @Observable` and only receives events (unchanged shape).
- Repeated GPU passes per ask (one per tool turn) stay inside the existing `MLXActivityTracker` bracket + 512 MB cache limit (`MLXClient.swift:35-41,114-137`) — no new memory story.

## 8. Acceptance tests (Swift Testing, written first)

### 8.1 `ThinkTagSplitterTests` (AriKit, pure)
- whole-tag-in-one-chunk, tag split across chunk boundaries (`<thi` + `nk>`), text-before/after tags, multiple think blocks, unterminated `<think>` at EOS (flushes as thinking, never leaks into answer), no-tags passthrough.

### 8.2 `AskToolsetTests` (in-memory `AppDatabase`)
- Each tool: happy path, zero-match honest text, ambiguous-match honest text, bounded output (oversized summary truncated at 8k; search result ≤16k).
- `calendar_events`: hour filter (18 → only 6 pm events), attendee email match, non-today events excluded, scheduled-≠-recorded wording present.
- `get_meeting_summary` rejects a meeting ID not previously surfaced this turn; accepts one surfaced by `find_person` [P1].
- `ToolTurnStateTests`: source dedup, hard cap at 24 with stable `[Sn]` indices (port of `agent.rs` `register_source_dedups_and_caps` test, `agent.rs:571`), iteration budget returns the exhaustion string at call 9, card dedup, surfaced-ID set accumulation [P1].

### 8.3 `AgenticLoopTests` (scripted fake `ToolCapableLLMClient`)
A `ScriptedToolLLM` fake that replays a fixed `[AgenticEvent]` script and asserts the dispatch results fed back to it:
- route → one tool call → answer: events arrive in order, sources/cards accumulate, `.done` carries reconciled answer + real sources.
- no-tool small talk: zero sources, any emitted `[S1]` stripped by reconcile (citation-invariant port).
- tool throws → dispatch returns error string, loop continues, answer still lands.
- >8 scripted tool calls → exhaustion string after the 8th, no 9th execution.
- thinking deltas stream as `.thinking`, never concatenated into the reconciled answer.

### 8.4 `PromptJSONLoopTests` (scripted fake plain `LLMClient`)
- fenced/unfenced JSON tool call parsed; args dispatched; result appended to next turn's prompt.
- plain-text reply = final answer; two consecutive unparseable tool-shaped replies = final answer; iteration cap honored; same source/citation assertions as 8.3.

### 8.5 Fallback-ladder tests (`RecallEngineAgenticTests`)
- `.mlx`-kind client conforming to `ToolCapableLLMClient` → rung 1 chosen.
- `.claudeCLI` → rung 2. `.ollama`/`.openAI`/etc. → rung 3 byte-identical to today's prepared prompt (regression lock on the existing path, including classifier cards).
- rung-1 throws before first answer delta → rung 3 runs, VM-visible stream contains only rung-3 output.
- Loopback violation still throws before any tool/loop work.

### 8.6 Target-query integration tests (seeded in-memory DB, scripted model)
1. **Landon recap** — seed person "Landon Star" + calendar-linked meeting + summary; script `find_person` → `get_meeting_summary` → answer. Assert `.person` card attached, the meeting ID flowed through the surfaced-ID gate [P1], answer references the summary, no invented `[Sn]`.
2. **Meeting-scoped action items** — re-assert the untouched single-shot path: full transcript in prompt, `@ref` in-range kept, `[Sn]` verified (extends existing `RecallEngineTests` meeting-scope cases; guards this plan against regressing it).
3. **6 pm attendees** — seed a today-18:00 event with attendees, no recording; script `calendar_events(hour: 18)`. Assert `.calendarEvent` card, attendee names in answer, zero sources, and the answer never claims the meeting was recorded/discussed.

### 8.7 Regression tests for the two live failures (2026-07-23)
- **Wrong-person-from-excerpts**: seed two people with similar contexts; agentic path with only `find_person("<A>")` called → prompt contains NO unrequested excerpts about person B (assert the assembled prompt lacks the `"Authoritative local meeting sources"` block entirely and contains no B-content), answer scripted from tool result only.
- **Card/answer contradiction**: `calendar_events` resolves an event; assert the terminal `.done` card's attendee/time facts and the (scripted-model-checked) prompt contain no competing excerpt block that could contradict — structurally, the only calendar facts in context are the tool result that produced the card.

### 8.8 VM/UI tests
- `AskViewModelTests`: `.thinking` accumulates into the thinking row; first `.delta` folds it; `.done` removes it; `.toolActivity` rows appear/complete; thinking/tool rows never persisted (assert `appendMessageOp` receives only answer/sources/cards); superseding ask drops in-flight thinking/tool rows.
- `AskMessageRecord` `cardsJson` round-trip + legacy `cardJson` fallback decode.

No dual-run gate: the Rust incumbent's agentic loop never shipped in the Swift app's lineage (Claude-API-only, explicitly unported — `RecallEngine.swift:11-17`); the invariant suite above (citations/bounds/loopback) *is* the port of the load-bearing Rust `local_recall_tests` guarantees, already green against today's Swift path and required green against the agentic path. No S1–S4 spike gate applies (S1 MLX already GO); the checkpoint-specific risks get the cheap harness in §9 instead.

## 9. Risks, decisions, sequencing

### Risks & validation harnesses (each gets a cheap CLI/harness step BEFORE its slice is declared done)

0. **[RESOLVED 2026-07-23] ChatSession incremental continuation × Qwen3.5 template** — `toolDispatch`-driven continuations throw `TemplateException("No user query found in messages.")` on every tool call (template backward-scans for a `user` message; incremental tail has none). Resolution: manual full-history turn loop in `MLXClient.respondWithTools` (§3.5 revision). Harness verdict on routing itself: 12/12 GO.
1. **`enable_thinking` × tool-calling interplay on Qwen3-4B-MLX-4bit** — does the model emit `<tool_call>` correctly inside/around think blocks, and does the Hermes parser catch them? *Harness:* a ~50-line SwiftPM executable (pattern: the S1 spike / `prompt-validation-harness` memory) loading the real checkpoint with 2 dummy tools + `toolDispatch` logging, run over ~10 canned questions. Reuse the app's already-downloaded model cache where possible. Go/no-go: ≥8/10 correct tool-vs-direct-answer routing. **If it fails:** ship Ask with `enable_thinking: false` first (tools still work; thinking UI becomes a later toggle) — thinking and tools are independently valuable and independently disableable.
2. **4-bit tool-selection quality** (calls tools for greetings, or never calls them). Same harness, extended question set incl. small talk. Mitigations already in-design: terse 6-tool set, explicit "answer directly without tools" instruction, rung-3 fallback unaffected.
3. **`streamDetails` never yields tool calls when `toolDispatch` is set** — verified (`ChatSession.swift:760-766`) and designed around (dispatch-side activity events, §3.5). Residual risk: a future mlx-swift-lm bump changes this; the pinned 3.31.4 checkout + `AgenticLoopTests` catch it.
4. **Uncapped ChatSession loop** — enforced in dispatch (§4.3) + `maxTokens` backstop; tested (8.3).
5. **Latency** (N tool turns × decode) — KV cache persists across turns inside one session (`ChatSession.swift:451-456`), so each turn pays only the tool-result prefill. The thinking/tool-activity stream makes the wait honest. Measure in harness; if p50 for a one-tool ask exceeds ~2× today's, cut `search_transcripts` default limit.
6. **ClaudeCLI JSON discipline** — lenient parser + two-strikes rule (§4.4); worst case degrades to a plain answer, never an error wall.

### Decisions (closed at principal review, 2026-07-23) **[P2]**

1. **Thinking persistence** — ephemeral, not persisted. DECIDED.
2. **Cards plural** — `cards: [RecallCardPayload]` + `cardsJson` column adopted; singular `card` kept as back-compat = `cards.first`. DECIDED.
3. **Thinking default-on** for Ask, gated by harness risk 1; a Settings toggle is added only if the harness forces `enable_thinking: false` at ship. DECIDED.

### Sequencing / slices (each independently testable; contracts frozen at slice boundaries) **[P3]**

- **Slice 0 (principal, tiny):** `AgenticTooling.swift` contract types + `RecallBounds` additions land first, verbatim from §3.1/§3.4, so Slices 1 and 2 can build in parallel against a compiled contract.
- **Slice 1 — provider tool surface + MLX loop + thinking stream** (`AriKit/Engine/Providers` + `AriKitEngineMLX`): `splitThinkTags`, `MLXClient.respondWithTools`, harness for risks 1/2/5. Tests: 8.1, the `ScriptedToolLLM` fixture, MLX conformance compile + harness run. **Frozen contract out:** the §3.1 signatures, exactly as written.
- **Slice 2 — RecallEngine orchestration** (`AriKit/Recall`): `AskToolset` + `ToolTurnState`, `RecallTools` extensions, `agenticSystemPrompt`, `prepareAgentic` + ladder, prompt-JSON loop, `RecallStreamEvent` extension (+ temporary no-op handling of new cases in `AskViewModel` so main stays green), `RecallResponse.cards` + migration. Tests: 8.2–8.7. **Frozen contracts:** consumes §3.1 verbatim; emits the `RecallStreamEvent`/`ToolActivity`/`RecallResponse.cards` shapes in §5.1/§5.4, exactly as written.
- **Slice 3 — UI** (`AriViewModels` + `Ari/UI`): `AskTranscriptItemKind` changes, `AskViewModel` event handling, thinking/tool-activity rendering (Marginalia), stacked cards, persistence read-path. Tests: 8.8. Consumes §5.1/§5.4 verbatim.

Slices 1 and 2 build in parallel against the frozen Slice-0 contract (Slice 2's tests use `ScriptedToolLLM`, no MLX needed); Slice 3 starts once Slice 2's event enum lands. Final gate: the three target queries run live in the signed app (`Ari Dev Signing` build) against the real library.
